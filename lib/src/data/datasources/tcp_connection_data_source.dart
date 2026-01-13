import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/crypto/beebeep_crypto_session.dart';
import '../../core/crypto/beebeep_ecdh_sect163k1.dart';
import '../../core/network/qt_frame_codec.dart';
import '../../core/protocol/beebeep_constants.dart';
import '../../core/protocol/beebeep_message.dart';
import '../../core/protocol/beebeep_message_codec.dart';
import '../../core/protocol/hello_payload.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_identity.dart';

class TcpConnectionDataSource {
  TcpConnectionDataSource({
    required String localDisplayName,
    required int protocolVersion,
    required int dataStreamVersion,
  }) : _localDisplayName = localDisplayName,
       _protocolVersion = protocolVersion,
       _dataStreamVersion = dataStreamVersion;

  final String _localDisplayName;
  final int _protocolVersion;
  final int _dataStreamVersion;

  final _logs = StreamController<String>.broadcast();
  final _peerIdentities = StreamController<PeerIdentity>.broadcast();

  Stream<String> watchLogs() => _logs.stream;

  Stream<PeerIdentity> watchPeerIdentities() => _peerIdentities.stream;

  ServerSocket? _server;
  final List<_BeeBeepConnection> _connections = <_BeeBeepConnection>[];

  int? get serverPort => _server?.port;

  final BeeBeepEcdhSect163k1 _ecdh = BeeBeepEcdhSect163k1();
  late final Sect163k1KeyPair _localKeyPair = _ecdh.generateKeyPair();

  Future<void> startServer({required int port}) async {
    if (_server != null) return;

    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _log('TCP server listening on :${_server!.port}');

    _server!.listen(
      (socket) {
        _log(
          'Incoming TCP from ${socket.remoteAddress.address}:${socket.remotePort}',
        );
        _accept(socket);
      },
      onError: (e, st) => _log('Server error: $e'),
      cancelOnError: false,
    );
  }

  Future<void> stopServer() async {
    final s = _server;
    _server = null;
    await s?.close();
    _log('TCP server stopped');
  }

  Future<void> connect(Peer peer) async {
    try {
      _log('Connecting to ${peer.host}:${peer.port}');
      final socket = await Socket.connect(
        peer.host,
        peer.port,
        timeout: const Duration(seconds: 5),
      );
      _log('Connected to ${peer.host}:${peer.port}');
      _accept(socket);
    } catch (e) {
      _log('Connect failed to ${peer.host}:${peer.port}: $e');
    }
  }

  Future<void> disconnectAll() async {
    final list = List<_BeeBeepConnection>.from(_connections);
    _connections.clear();

    for (final c in list) {
      await c.close();
    }
    _log('Disconnected all');
  }

  void _accept(Socket socket) {
    final conn = _BeeBeepConnection(
      socket: socket,
      protocolVersion: _protocolVersion,
      dataStreamVersion: _dataStreamVersion,
      localHello: _buildLocalHello(socket),
      localPrivateKey: _localKeyPair.privateKey,
      ecdh: _ecdh,
      onPeerIdentity: (identity) => _peerIdentities.add(identity),
      onLog: _log,
    );

    _connections.add(conn);
    conn.start();
  }

  HelloPayload _buildLocalHello(Socket socket) {
    final host = '';
    final publicKey = _ecdh.publicKeyToBeeBeepString(_localKeyPair.publicKey);

    return HelloPayload(
      displayName: _localDisplayName,
      host: host,
      port: serverPort ?? 0,
      protocolVersion: _protocolVersion,
      secureLevel: 4,
      dataStreamVersion: _dataStreamVersion,
      publicKey: publicKey,
    );
  }

  void _log(String message) {
    _logs.add('[${DateTime.now().toIso8601String()}] $message');
  }

  Future<void> dispose() async {
    await disconnectAll();
    await stopServer();
    await _peerIdentities.close();
    await _logs.close();
  }
}

class _BeeBeepConnection {
  _BeeBeepConnection({
    required Socket socket,
    required int protocolVersion,
    required int dataStreamVersion,
    required HelloPayload localHello,
    required localPrivateKey,
    required BeeBeepEcdhSect163k1 ecdh,
    required void Function(PeerIdentity) onPeerIdentity,
    required void Function(String) onLog,
  }) : _socket = socket,
       _messageCodec = BeeBeepMessageCodec(protocolVersion: protocolVersion),
       _protocolVersion = protocolVersion,
       _cryptoSession = BeeBeepCryptoSession(
         dataStreamVersion: dataStreamVersion,
       ),
       _localHello = localHello,
       _localPrivateKey = localPrivateKey,
       _ecdh = ecdh,
       _onPeerIdentity = onPeerIdentity,
       _log = onLog;

  final Socket _socket;
  final QtFrameCodec _framer = QtFrameCodec();
  final BeeBeepMessageCodec _messageCodec;
  // Kept for protocol-dependent behavior in future parsing.
  // ignore: unused_field
  final int _protocolVersion;
  final BeeBeepCryptoSession _cryptoSession;
  final HelloPayload _localHello;
  final dynamic _localPrivateKey;
  final BeeBeepEcdhSect163k1 _ecdh;
  final void Function(PeerIdentity) _onPeerIdentity;
  final void Function(String) _log;

  StreamSubscription<Uint8List>? _sub;
  bool _sentHello = false;
  // ignore: unused_field
  HelloPayload? _peerHello;

  void start() {
    _sub = _socket.listen(
      (chunk) {
        _framer.addChunk(chunk);
        for (final frame in _framer.takeFrames()) {
          _handleFrame(frame);
        }
      },
      onDone: () => _log('Socket closed by peer'),
      onError: (e, st) => _log('Socket error: $e'),
      cancelOnError: false,
    );

    _sendHelloIfNeeded();
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _socket.destroy();
  }

  void _handleFrame(Uint8List frame) {
    // If crypto is ready, attempt decrypt first.
    Uint8List plaintext;
    if (_cryptoSession.isReady) {
      try {
        plaintext = _cryptoSession.decrypt(frame);
      } catch (_) {
        plaintext = frame;
      }
    } else {
      plaintext = frame;
    }

    final msg = _messageCodec.decodePlaintext(plaintext);
    if (msg.type == BeeBeepMessageType.hello) {
      _handleHello(msg);
      return;
    }

    _log(
      'RX ${beeBeepHeaderForType(msg.type)} id=${msg.id} flags=${msg.flags}',
    );
  }

  void _handleHello(BeeBeepMessage msg) {
    try {
      final peerHello = HelloPayload.decode(msg.data);
      _peerHello = peerHello;
      _log('RX HELLO from ${peerHello.displayName}');

      final peerHost = _socket.remoteAddress.address;
      final peerPort = peerHello.port;
      if (peerHost.isNotEmpty && peerPort > 0) {
        _onPeerIdentity(
          PeerIdentity(
            peerId: '$peerHost:$peerPort',
            displayName: peerHello.displayName,
          ),
        );
      }

      final peerPub = _ecdh.publicKeyFromBeeBeepString(peerHello.publicKey);
      final shared = _ecdh.computeSharedSecret(
        privateKey: _localPrivateKey,
        peerPublicKey: peerPub,
      );
      final sharedKey = base64Url.encode(shared).replaceAll('=', '');
      _cryptoSession.setSharedKey(sharedKey);
      _log('Crypto session established');

      _sendHelloIfNeeded();
    } catch (e) {
      _log('HELLO decode failed: $e');
    }
  }

  void _sendHelloIfNeeded() {
    if (_sentHello) return;

    final helloMsg = BeeBeepMessage(
      type: BeeBeepMessageType.hello,
      id: beeBeepIdHelloMessage,
      flags: 0,
      data: _localHello.encode(),
      timestamp: DateTime.now(),
      text: '',
    );

    final plaintext = _messageCodec.encodePlaintext(helloMsg);
    final frame = _framer.encodeFrame(plaintext);
    _socket.add(frame);
    _socket.flush();

    _sentHello = true;
    _log('TX HELLO');
  }
}
