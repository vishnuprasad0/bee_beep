import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha1.dart';

import '../../core/crypto/beebeep_crypto_session.dart';
import '../../core/crypto/beebeep_ecdh_sect163k1.dart';
import '../../core/network/qt_frame_codec.dart';
import '../../core/protocol/beebeep_constants.dart';
import '../../core/protocol/beebeep_message.dart';
import '../../core/protocol/beebeep_message_codec.dart';
import '../../core/protocol/hello_payload.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_identity.dart';
import 'received_message.dart';

class TcpConnectionDataSource {
  TcpConnectionDataSource({
    required String localDisplayName,
    required int protocolVersion,
    required int dataStreamVersion,
    String? passwordOverride,
    String? signatureOverride,
  }) : _localDisplayName = localDisplayName,
       _protocolVersion = protocolVersion,
       _dataStreamVersion = dataStreamVersion,
       _passwordOverride = passwordOverride,
       _signatureOverride = signatureOverride;

  String _localDisplayName;
  final int _protocolVersion;
  final int _dataStreamVersion;
  final String? _passwordOverride;
  final String? _signatureOverride;

  late final String _signature = _resolveSignature();
  late final String _passwordHex = _computePasswordHex();

  final _logs = StreamController<String>.broadcast();
  final _peerIdentities = StreamController<PeerIdentity>.broadcast();
  final _receivedMessages = StreamController<ReceivedMessage>.broadcast();

  Stream<String> watchLogs() => _logs.stream;

  Stream<PeerIdentity> watchPeerIdentities() => _peerIdentities.stream;

  Stream<ReceivedMessage> watchReceivedMessages() => _receivedMessages.stream;

  ServerSocket? _server;
  final List<_BeeBeepConnection> _connections = <_BeeBeepConnection>[];
  final Map<String, _BeeBeepConnection> _connectionsByPeerId =
      <String, _BeeBeepConnection>{};
  final Map<String, List<String>> _pendingChatTextsByPeerId =
      <String, List<String>>{};
  final Map<String, List<_PendingFileTransfer>> _pendingFilesByPeerId =
      <String, List<_PendingFileTransfer>>{};

  int? get serverPort => _server?.port;

  /// Updates the local display name for newly established connections.
  void updateLocalDisplayName(String displayName) {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return;
    _localDisplayName = trimmed;
    _log('Local display name updated to "$trimmed"');
  }

  final BeeBeepEcdhSect163k1 _ecdh = BeeBeepEcdhSect163k1();
  late final Sect163k1KeyPair _localKeyPair = _ecdh.generateKeyPair();

  String _localHost = '';

  bool? _isLikelyAndroidEmulator;

  static const String _helloHostOverride = String.fromEnvironment(
    'BEEBEEP_HELLO_HOST',
    defaultValue: '',
  );
  static const String _helloPortOverrideRaw = String.fromEnvironment(
    'BEEBEEP_HELLO_PORT',
    defaultValue: '',
  );
  static const String _passwordOverrideEnv = String.fromEnvironment(
    'BEEBEEP_PASSWORD',
    defaultValue: '',
  );
  static const String _signatureOverrideEnv = String.fromEnvironment(
    'BEEBEEP_SIGNATURE',
    defaultValue: '',
  );

  String _resolvePassword() {
    final override = _passwordOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    return _passwordOverrideEnv;
  }

  String _resolveSignature() {
    final override = _signatureOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    return _signatureOverrideEnv;
  }

  String _computePasswordHex() {
    final password = _resolvePassword();
    final signature = _signature;
    final basePassword = password.isEmpty || password == '*'
        ? '*6475*'
        : password;
    final fullPassword = signature.isNotEmpty
        ? '$signature$basePassword'
        : basePassword;
    final pwdBytes = utf8.encode(fullPassword);
    final sha1Pwd = SHA1Digest();
    final pwdHash = sha1Pwd.process(Uint8List.fromList(pwdBytes));
    return _bytesToHex(pwdHash);
  }

  int _helloPortOverride() {
    final p = int.tryParse(_helloPortOverrideRaw);
    if (p == null) return 0;
    if (p <= 0 || p > 65535) return 0;
    return p;
  }

  Future<bool> _detectLikelyAndroidEmulator() async {
    final cached = _isLikelyAndroidEmulator;
    if (cached != null) return cached;

    if (!Platform.isAndroid) {
      _isLikelyAndroidEmulator = false;
      return false;
    }

    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      final hasEmulatorAddress = ifaces.any(
        (i) => i.addresses.any((a) => a.address == '10.0.2.16'),
      );
      _isLikelyAndroidEmulator = hasEmulatorAddress;
      return hasEmulatorAddress;
    } catch (_) {
      _isLikelyAndroidEmulator = false;
      return false;
    }
  }

  Future<String> _bestLocalIpv4() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      final candidates = <String>[];
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.isEmpty) continue;
          if (ip.startsWith('169.254.')) continue; // link-local
          candidates.add(ip);
        }
      }

      // Prefer RFC1918 LAN addresses over VPN ranges.
      for (final ip in candidates) {
        if (_isRfc1918(ip)) return ip;
      }

      if (candidates.isNotEmpty) return candidates.first;
    } catch (_) {
      // Ignore and fall back.
    }
    return '';
  }

  bool _isRfc1918(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;

    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    return false;
  }

  Future<void> startServer({required int port}) async {
    if (_server != null) return;

    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _localHost = await _bestLocalIpv4();
    _log('TCP server listening on :${_server!.port}');

    final overridePort = _helloPortOverride();
    if (_helloHostOverride.isNotEmpty || overridePort != 0) {
      _log(
        'HELLO override: host="${_helloHostOverride.isEmpty ? '(none)' : _helloHostOverride}" '
        'port=${overridePort == 0 ? '(none)' : overridePort}',
      );
    }

    // Common pitfall: the Android emulator advertises a 10.0.2.x address that
    // BeeBEEP desktop peers cannot reach, so they never respond to HELLO.
    final isEmulator = await _detectLikelyAndroidEmulator();
    if (isEmulator &&
        _helloHostOverride.isEmpty &&
        _localHost.startsWith('10.')) {
      _log(
        'NOTE: Android emulator likely advertises unreachable host "$_localHost". '
        'Desktop BeeBEEP may wait for a reverse connection and never reply. '
        'Use a real device on LAN, or run with '
        '--dart-define=BEEBEEP_HELLO_HOST=127.0.0.1 and '
        '--dart-define=BEEBEEP_HELLO_PORT=<hostForwardPort> when BeeBEEP runs on this same computer.',
      );
    }

    _server!.listen(
      (socket) {
        _log(
          'Incoming TCP from ${socket.remoteAddress.address}:${socket.remotePort}',
        );
        _accept(socket, isIncoming: true);
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
    final peerId = '${peer.host}:${peer.port}';
    final existing = _connectionsByPeerId[peerId];
    if (existing != null && !existing.isClosed) {
      _log('Already connected to $peerId; skipping connect.');
      return;
    }
    _log('Connecting to ${peer.host}:${peer.port}');
    try {
      final socket = await Socket.connect(
        peer.host,
        peer.port,
        timeout: const Duration(seconds: 5),
      );
      _log('Connected to ${peer.host}:${peer.port}');
      _accept(
        socket,
        expectedPeerId: '${peer.host}:${peer.port}',
        peerHostHint: peer.host,
        isIncoming: false,
      );
      return;
    } catch (e) {
      _log('Connect failed to ${peer.host}:${peer.port}: $e');
    }

    final isEmulator = await _detectLikelyAndroidEmulator();
    if (!isEmulator) return;

    // Android emulator: the host machine is reachable via 10.0.2.2.
    // This helps when mDNS resolves to a LAN IP that isn't reachable from the emulator.
    if (peer.host == '10.0.2.2') return;

    _log('Retrying via emulator host alias 10.0.2.2:${peer.port}');
    try {
      final socket = await Socket.connect(
        '10.0.2.2',
        peer.port,
        timeout: const Duration(seconds: 5),
      );
      _log('Connected to 10.0.2.2:${peer.port}');
      _accept(
        socket,
        expectedPeerId: '${peer.host}:${peer.port}',
        peerHostHint: peer.host,
        isIncoming: false,
      );
    } catch (e) {
      _log('Connect failed to 10.0.2.2:${peer.port}: $e');
    }
  }

  Future<void> sendChat({required Peer peer, required String text}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final peerId = '${peer.host}:${peer.port}';
    final existing = _connectionsByPeerId[peerId];
    if (existing != null) {
      final sent = existing.sendChatText(trimmed);
      if (!sent) {
        _pendingChatTextsByPeerId
            .putIfAbsent(peerId, () => <String>[])
            .add(trimmed);
      }
      return;
    }

    _pendingChatTextsByPeerId
        .putIfAbsent(peerId, () => <String>[])
        .add(trimmed);
    await connect(peer);
  }

  Future<void> sendFile({
    required Peer peer,
    required String fileName,
    required Uint8List bytes,
    required int fileSize,
    String? mimeType,
  }) async {
    await _sendFileInternal(
      peer: peer,
      transfer: _PendingFileTransfer(
        fileName: fileName,
        bytes: bytes,
        fileSize: fileSize,
        mimeType: mimeType,
        isVoice: false,
      ),
    );
  }

  Future<void> sendVoiceMessage({
    required Peer peer,
    required String fileName,
    required Uint8List bytes,
    required int fileSize,
    String? mimeType,
  }) async {
    await _sendFileInternal(
      peer: peer,
      transfer: _PendingFileTransfer(
        fileName: fileName,
        bytes: bytes,
        fileSize: fileSize,
        mimeType: mimeType,
        isVoice: true,
      ),
    );
  }

  Future<void> _sendFileInternal({
    required Peer peer,
    required _PendingFileTransfer transfer,
  }) async {
    final peerId = '${peer.host}:${peer.port}';
    final existing = _connectionsByPeerId[peerId];
    if (existing != null) {
      final sent = existing.sendFileTransfer(transfer);
      if (!sent) {
        _pendingFilesByPeerId
            .putIfAbsent(peerId, () => <_PendingFileTransfer>[])
            .add(transfer);
      }
      return;
    }

    _pendingFilesByPeerId
        .putIfAbsent(peerId, () => <_PendingFileTransfer>[])
        .add(transfer);
    await connect(peer);
  }

  Future<void> disconnectAll() async {
    final list = List<_BeeBeepConnection>.from(_connections);
    _connections.clear();
    _connectionsByPeerId.clear();

    for (final c in list) {
      await c.close();
    }
    _log('Disconnected all');
  }

  void _accept(
    Socket socket, {
    String? expectedPeerId,
    String? peerHostHint,
    required bool isIncoming,
  }) {
    _log(
      'Connection opened (${isIncoming ? 'incoming' : 'outgoing'}) '
      '${socket.remoteAddress.address}:${socket.remotePort}',
    );
    final conn = _BeeBeepConnection(
      socket: socket,
      isIncoming: isIncoming,
      expectedPeerId: expectedPeerId,
      protocolVersion: _protocolVersion,
      dataStreamVersion: _dataStreamVersion,
      localHello: _buildLocalHello(
        peerHostHint ?? socket.remoteAddress.address,
      ),
      localPrivateKey: _localKeyPair.privateKey,
      ecdh: _ecdh,
      passwordHex: _passwordHex,
      onPeerIdentity: (identity) => _peerIdentities.add(identity),
      onPeerIdKnown: _bindPeerConnection,
      onCryptoReady: _flushPendingOutbound,
      onClosed: _unbindPeerConnection,
      onLog: _log,
      onReceivedMessage: (msg) => _receivedMessages.add(msg),
    );

    _connections.add(conn);
    conn.start();

    if (expectedPeerId != null) {
      _connectionsByPeerId[expectedPeerId] = conn;
    }
  }

  void _bindPeerConnection(String peerId, _BeeBeepConnection conn) {
    final existing = _connectionsByPeerId[peerId];
    if (existing != null && !identical(existing, conn)) {
      if (conn.isIncoming && !existing.isIncoming) {
        _log('Duplicate connection for $peerId; keeping incoming connection.');
        unawaited(existing.close());
        _connectionsByPeerId[peerId] = conn;
        return;
      }
      _log('Duplicate connection for $peerId; closing new connection.');
      unawaited(conn.close());
      return;
    }
    _connectionsByPeerId[peerId] = conn;
  }

  void _unbindPeerConnection(String? peerId, _BeeBeepConnection conn) {
    _connections.remove(conn);

    if (peerId != null) {
      final current = _connectionsByPeerId[peerId];
      if (identical(current, conn)) {
        _connectionsByPeerId.remove(peerId);
      }
    }

    _log(
      'Connection closed: ${peerId ?? "unknown"}, ${_connections.length} connections remaining',
    );
  }

  void _flushPendingOutbound(String peerId, _BeeBeepConnection conn) {
    final pending = _pendingChatTextsByPeerId.remove(peerId);
    if (pending == null || pending.isEmpty) return;

    for (final text in pending) {
      conn.sendChatText(text);
    }

    final pendingFiles = _pendingFilesByPeerId.remove(peerId);
    if (pendingFiles == null || pendingFiles.isEmpty) return;
    for (final transfer in pendingFiles) {
      conn.sendFileTransfer(transfer);
    }
  }

  HelloPayload _buildLocalHello(String peerHostHint) {
    final publicKey = _ecdh.publicKeyToBeeBeepString(_localKeyPair.publicKey);

    final overridePort = _helloPortOverride();
    final port = overridePort != 0 ? overridePort : (serverPort ?? 0);

    // Generate hash as SHA1 of displayName (matching BeeBEEP Settings::hash())
    final hash = _generateUserHash(
      _localDisplayName,
      passwordHex: _passwordHex,
      signature: _signature,
    );

    return HelloPayload(
      port: port,
      displayName: _localDisplayName,
      status: 1, // Online
      statusDescription: '',
      accountName: _localDisplayName,
      publicKey: publicKey,
      version: '$_protocolVersion',
      hash: hash,
      color: '#0000FF',
      workgroups: '',
      qtVersion: '6.5.0', // Fake Qt version
      dataStreamVersion: _dataStreamVersion,
      statusChangedIn: null,
      domainName: '',
      localHostName: Platform.localHostname,
    );
  }

  String _generateUserHash(
    String username, {
    required String passwordHex,
    required String signature,
  }) {
    // BeeBEEP Settings::hash() algorithm:
    // QByteArray hash_pre = string_to_hash.toUtf8() + m_password;
    // Where m_password = SHA1("*6475*").toHex() for default password
    // If signature is set, it is appended to hash_pre.

    final hashPre = <int>[]
      ..addAll(utf8.encode(username))
      ..addAll(utf8.encode(passwordHex));

    if (signature.isNotEmpty) {
      hashPre.addAll(utf8.encode(signature));
    }

    final sha1 = SHA1Digest();
    final hashResult = sha1.process(Uint8List.fromList(hashPre));
    return _bytesToHex(hashResult);
  }

  String _bytesToHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  void _log(String message) {
    final line = '[${DateTime.now().toIso8601String()}] $message';
    _logs.add(line);

    // Also show in console/logcat for easier debugging.
    if (!const bool.fromEnvironment('dart.vm.product')) {
      // ignore: avoid_print
      print(line);
    }
  }

  Future<void> dispose() async {
    await disconnectAll();
    await stopServer();
    await _peerIdentities.close();
    await _logs.close();
  }
}

class _PendingFileTransfer {
  _PendingFileTransfer({
    required this.fileName,
    required this.bytes,
    required this.fileSize,
    required this.isVoice,
    this.mimeType,
  });

  final String fileName;
  final Uint8List bytes;
  final int fileSize;
  final bool isVoice;
  final String? mimeType;
}

class _BeeBeepConnection {
  _BeeBeepConnection({
    required Socket socket,
    required bool isIncoming,
    required String? expectedPeerId,
    required int protocolVersion,
    required int dataStreamVersion,
    required HelloPayload localHello,
    required localPrivateKey,
    required BeeBeepEcdhSect163k1 ecdh,
    required String passwordHex,
    required void Function(PeerIdentity) onPeerIdentity,
    required void Function(String peerId, _BeeBeepConnection conn)
    onPeerIdKnown,
    required void Function(String peerId, _BeeBeepConnection conn)
    onCryptoReady,
    required void Function(String? peerId, _BeeBeepConnection conn) onClosed,
    required void Function(String) onLog,
    required void Function(ReceivedMessage) onReceivedMessage,
  }) : _socket = socket,
       _isIncoming = isIncoming,
       _peerId = expectedPeerId,
       _messageCodec = BeeBeepMessageCodec(protocolVersion: protocolVersion),
       _protocolVersion = protocolVersion,
       _cryptoSession = BeeBeepCryptoSession(
         dataStreamVersion: dataStreamVersion,
       )..initializeDefaultCipher(1, passwordHex: passwordHex),
       _localHello = localHello,
       _localPrivateKey = localPrivateKey,
       _ecdh = ecdh,
       _onPeerIdentity = onPeerIdentity,
       _onPeerIdKnown = onPeerIdKnown,
       _onCryptoReady = onCryptoReady,
       _onClosed = onClosed,
       _log = onLog,
       _onReceivedMessage = onReceivedMessage;

  final Socket _socket;
  final bool _isIncoming;
  final AdaptiveQtFrameCodec _rxFramer = AdaptiveQtFrameCodec();
  final QtFrameCodec _txFramer = QtFrameCodec();
  final BeeBeepMessageCodec _messageCodec;
  // Kept for protocol-dependent behavior in future parsing.
  // ignore: unused_field
  final int _protocolVersion;
  final BeeBeepCryptoSession _cryptoSession;
  final HelloPayload _localHello;
  final dynamic _localPrivateKey;
  final BeeBeepEcdhSect163k1 _ecdh;
  final void Function(PeerIdentity) _onPeerIdentity;
  final void Function(String peerId, _BeeBeepConnection conn) _onPeerIdKnown;
  final void Function(String peerId, _BeeBeepConnection conn) _onCryptoReady;
  final void Function(String? peerId, _BeeBeepConnection conn) _onClosed;
  final void Function(String) _log;
  final void Function(ReceivedMessage) _onReceivedMessage;

  StreamSubscription<Uint8List>? _sub;
  Timer? _helloFallbackTimer;
  bool _sentHello = false;
  bool _closed = false;
  int _nextMessageId = 1000;
  String? _peerId;
  // ignore: unused_field
  HelloPayload? _peerHello;

  QtFramePrefix? _lastDetectedPrefix;
  int _rxChunkCount = 0;
  // BeeBEEP starts with m_protocolVersion=1, so it expects 16-bit prefix
  // for the initial HELLO. Only switch to 32-bit after receiving peer's HELLO.
  QtFramePrefix _txPrefix = QtFramePrefix.u16be;

  String? get remoteHost {
    try {
      return _socket.remoteAddress.address;
    } catch (_) {
      return null;
    }
  }

  bool get isIncoming => _isIncoming;

  bool get isClosed => _closed;

  void start() {
    _sub = _socket.listen(
      (chunk) {
        _rxChunkCount++;
        _helloFallbackTimer?.cancel();
        _helloFallbackTimer = null;
        _rxFramer.addChunk(chunk);

        final detected = _rxFramer.prefix;
        if (detected != null && detected != _lastDetectedPrefix) {
          _lastDetectedPrefix = detected;
          _log('RX framing: ${detected.name}');
        }

        final frames = _rxFramer.takeFrames();
        if (frames.isEmpty && _rxChunkCount <= 3) {
          _log(
            'RX raw chunk (${chunk.length} bytes): ${_hexPreview(chunk, maxBytes: 60)}',
          );
          _log('RX buffered=${_rxFramer.bufferedBytes}');
        }

        for (final frame in frames) {
          try {
            _handleFrame(frame);
          } catch (e) {
            _log('RX frame handling failed: $e; frame=${_hexPreview(frame)}');
          }
        }
      },
      onDone: () {
        _log('Socket closed by peer');
        close();
      },
      onError: (e, st) => _log('Socket error: $e'),
      cancelOnError: false,
    );

    _sendHelloIfNeeded();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    _helloFallbackTimer?.cancel();
    _helloFallbackTimer = null;

    await _sub?.cancel();
    _sub = null;
    try {
      _socket.destroy();
    } catch (_) {
      // Socket already closed
    }

    _onClosed(_peerId, this);
  }

  void _handleFrame(Uint8List frame) {
    // Determine decryption mode:
    // - ECDH-derived session cipher (isReady) takes priority
    // - Initial cipher (default password) for HELLO before ECDH completes
    Uint8List plaintext;
    if (_cryptoSession.isReady) {
      try {
        plaintext = _cryptoSession.decrypt(frame);
      } catch (_) {
        plaintext = frame;
      }
    } else {
      // Before ECDH, incoming data is encrypted with the default password
      try {
        plaintext = _cryptoSession.decryptInitial(frame);
        _log(
          'RX decrypted with initial cipher (${frame.length} -> ${plaintext.length} bytes)',
        );
      } catch (e) {
        _log('RX initial cipher decrypt failed: $e, using raw frame');
        plaintext = frame;
      }
    }

    var msg = _messageCodec.decodePlaintext(plaintext);
    if (msg.type == BeeBeepMessageType.undefined) {
      try {
        final decompressed = _messageCodec.maybeDecompress(
          plaintext,
          compressed: true,
        );
        final alt = _messageCodec.decodePlaintext(decompressed);
        if (alt.type != BeeBeepMessageType.undefined) {
          msg = alt;
          _log(
            'RX payload decompressed (${plaintext.length} -> ${decompressed.length} bytes)',
          );
        }
      } catch (_) {
        // Ignore: payload was not compressed or decompression failed.
      }
    }
    if (msg.type == BeeBeepMessageType.hello) {
      _handleHello(msg);
      return;
    }

    if (msg.type == BeeBeepMessageType.chat) {
      final text = msg.text.trim();
      final dataPreview = msg.data.length > 200
          ? '${msg.data.substring(0, 200)}…'
          : msg.data;
      _log(
        'RX BEE-CHAT id=${msg.id} flags=${msg.flags} text="$text" data="$dataPreview"',
      );

      // Emit received message
      final peerName = _peerHello?.displayName ?? 'Unknown';
      final peerId = _peerId ?? '';
      if (text.isNotEmpty && peerId.isNotEmpty) {
        _onReceivedMessage(
          ReceivedMessage(
            peerId: peerId,
            peerName: peerName,
            text: text,
            timestamp: DateTime.now(),
            messageId: msg.id.toString(),
          ),
        );
      }
      return;
    }

    if (msg.type == BeeBeepMessageType.file) {
      unawaited(_handleFileMessage(msg));
      return;
    }

    if (msg.type == BeeBeepMessageType.undefined) {
      _log(
        'RX unknown payload (${plaintext.length} bytes): ${_hexPreview(plaintext, maxBytes: 48)} text="${_textPreview(plaintext)}"',
      );
      return;
    }

    _log(
      'RX ${beeBeepHeaderForType(msg.type)} id=${msg.id} flags=${msg.flags}',
    );
  }

  bool sendChatText(String text) {
    if (!_cryptoSession.isReady) {
      _log('Chat queued (crypto not ready yet)');
      return false;
    }

    final peerHash = _peerHello?.hash ?? '';
    final flags = peerHash.isNotEmpty
        ? beeBeepFlagBit(BeeBeepMessageFlag.private)
        : 0;

    final message = BeeBeepMessage(
      type: BeeBeepMessageType.chat,
      id: _nextMessageId++,
      flags: flags,
      data: peerHash,
      timestamp: DateTime.now(),
      text: text,
    );

    _sendMessage(message);
    _log('TX BEE-CHAT id=${message.id} text="$text"');
    return true;
  }

  bool sendFileTransfer(_PendingFileTransfer transfer) {
    if (!_cryptoSession.isReady) {
      final label = transfer.isVoice ? 'Voice' : 'File';
      _log('$label queued (crypto not ready yet)');
      return false;
    }

    final flags = transfer.isVoice
        ? beeBeepFlagBit(BeeBeepMessageFlag.voiceMessage)
        : 0;

    final meta = <String, Object?>{
      'name': transfer.fileName,
      'size': transfer.fileSize,
      'mime': transfer.mimeType,
      'voice': transfer.isVoice,
    };

    final message = BeeBeepMessage(
      type: BeeBeepMessageType.file,
      id: _nextMessageId++,
      flags: flags,
      data: base64Encode(transfer.bytes),
      timestamp: DateTime.now(),
      text: jsonEncode(meta),
    );

    _sendMessage(message);
    _log(
      'TX BEE-FILE id=${message.id} name="${transfer.fileName}" size=${transfer.fileSize} voice=${transfer.isVoice}',
    );
    return true;
  }

  Future<void> _handleFileMessage(BeeBeepMessage msg) async {
    try {
      final meta = _parseFileMeta(msg.text);
      final isVoice =
          (msg.flags & beeBeepFlagBit(BeeBeepMessageFlag.voiceMessage)) != 0 ||
          (meta['voice'] == true);
      final rawName = meta['name'];
      final fileName = rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : 'file';

      final bytes = base64Decode(msg.data);
      final rawSize = meta['size'];
      final fileSize = rawSize is int
          ? rawSize
          : (rawSize is num ? rawSize.toInt() : bytes.length);
      final durationMs = meta['durationMs'] as int?;

      final savedPath = await _persistIncomingFile(
        fileName: fileName,
        bytes: bytes,
        isVoice: isVoice,
      );

      final peerName = _peerHello?.displayName ?? 'Unknown';
      final peerId = _peerId ?? '';
      if (peerId.isEmpty) return;

      _onReceivedMessage(
        ReceivedMessage(
          peerId: peerId,
          peerName: peerName,
          text: isVoice ? 'Voice message' : fileName,
          timestamp: DateTime.now(),
          messageId: msg.id.toString(),
          type: isVoice ? MessageType.voice : MessageType.file,
          filePath: savedPath,
          fileSize: fileSize,
          fileName: fileName,
          duration: durationMs != null
              ? Duration(milliseconds: durationMs)
              : null,
        ),
      );

      _log(
        'RX BEE-FILE id=${msg.id} name="$fileName" size=$fileSize voice=$isVoice saved="$savedPath"',
      );
    } catch (e) {
      _log('RX file message failed: $e');
    }
  }

  Map<String, Object?> _parseFileMeta(String text) {
    try {
      final raw = jsonDecode(text);
      if (raw is Map<String, dynamic>) {
        return raw;
      }
    } catch (_) {
      // Ignore parsing errors.
    }
    return <String, Object?>{};
  }

  Future<String> _persistIncomingFile({
    required String fileName,
    required Uint8List bytes,
    required bool isVoice,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final targetDir = Directory('${dir.path}/beebeep_files');
    await targetDir.create(recursive: true);

    final safeName = fileName.replaceAll(RegExp(r'[^\w\d._ -]'), '_');
    final prefix = isVoice ? 'voice' : 'file';
    final path =
        '${targetDir.path}/${DateTime.now().millisecondsSinceEpoch}_${prefix}_$safeName';
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  void _sendMessage(BeeBeepMessage message, {bool useInitialCipher = false}) {
    // Determine encryption mode:
    // - ECDH-derived session cipher (isReady) takes priority
    // - Initial cipher (default password) for HELLO before ECDH completes
    final useSessionCipher = _cryptoSession.isReady;
    final shouldEncrypt = useSessionCipher || useInitialCipher;

    Uint8List payload = _messageCodec.encodePlaintext(
      message,
      padToBlockSize: shouldEncrypt,
    );

    // Log the plaintext message for debugging
    if (message.type == BeeBeepMessageType.hello) {
      _log(
        'TX HELLO payload (${payload.length} bytes): ${_hexPreview(payload, maxBytes: 80)}',
      );
      _log(
        'TX HELLO text: "${message.text.substring(0, message.text.length > 100 ? 100 : message.text.length)}..."',
      );
      _log('TX HELLO data: "${message.data}"');
    }

    if (shouldEncrypt) {
      if (useSessionCipher) {
        payload = _cryptoSession.encrypt(payload);
      } else {
        // Use initial (default password) cipher for HELLO
        payload = _cryptoSession.encryptInitial(payload);
        _log('TX encrypted with initial cipher (${payload.length} bytes)');
      }
    }

    final frame = _encodeTxFrame(payload);

    // Log the framed bytes
    if (message.type == BeeBeepMessageType.hello) {
      _log(
        'TX frame (${frame.length} bytes): ${_hexPreview(frame, maxBytes: 40)}',
      );
    }

    _socket.add(frame);
    _socket.flush();
  }

  Uint8List _encodeTxFrame(Uint8List payload) {
    if (_txPrefix == QtFramePrefix.u16be) {
      return _txFramer.encodeFrame16(payload);
    }
    return _txFramer.encodeFrame(payload);
  }

  String _hexPreview(Uint8List bytes, {int maxBytes = 24}) {
    final take = bytes.length > maxBytes ? maxBytes : bytes.length;
    final sb = StringBuffer();
    for (var i = 0; i < take; i++) {
      final v = bytes[i];
      sb.write(v.toRadixString(16).padLeft(2, '0'));
      if (i != take - 1) sb.write(' ');
    }
    if (bytes.length > take) sb.write(' …(+${bytes.length - take})');
    return sb.toString();
  }

  String _textPreview(Uint8List bytes, {int maxChars = 120}) {
    final decoded = utf8.decode(bytes, allowMalformed: true);
    if (decoded.length <= maxChars) return decoded;
    return '${decoded.substring(0, maxChars)}…';
  }

  void _handleHello(BeeBeepMessage msg) {
    try {
      // BeeBEEP HELLO: payload in TEXT field, hash in DATA field
      final peerHello = HelloPayload.decodeText(msg.text);
      _peerHello = peerHello;

      // msg.id contains the peer's protocol version
      final peerProtoVersion = msg.id;
      _log('RX HELLO from ${peerHello.displayName} (proto=$peerProtoVersion)');

      // Switch to 32-bit framing if peer supports it (proto > 60)
      if (peerProtoVersion > 60) {
        _txPrefix = QtFramePrefix.u32be;
        _rxFramer.setPrefix(QtFramePrefix.u32be);
        _log('Switching TX framing to u32be for proto $peerProtoVersion');
      }

      _helloFallbackTimer?.cancel();
      _helloFallbackTimer = null;

      final peerHost = _socket.remoteAddress.address;
      final peerPort = peerHello.port;
      if (peerHost.isNotEmpty && peerPort > 0) {
        final id = '$peerHost:$peerPort';
        _peerId = id;
        _onPeerIdKnown(id, this);
        _onPeerIdentity(
          PeerIdentity(peerId: id, displayName: peerHello.displayName),
        );
      }

      final peerPub = _ecdh.publicKeyFromBeeBeepString(peerHello.publicKey);
      final shared = _ecdh.computeSharedSecret(
        privateKey: _localPrivateKey,
        peerPublicKey: peerPub,
      );
      final sharedKey = _sharedKeyFromBytes(shared);
      _cryptoSession.setSharedKey(sharedKey);
      _log('Crypto session established');

      if (_peerId case final String id) {
        _onCryptoReady(id, this);
      }

      _sendHelloIfNeeded();
    } catch (e) {
      _log('HELLO decode failed: $e');
    }
  }

  String _sharedKeyFromBytes(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toString());
    }
    final raw = utf8.encode(sb.toString());
    return base64Url.encode(raw).replaceAll('=', '');
  }

  void _sendHelloIfNeeded() {
    if (_sentHello) return;

    // BeeBEEP HELLO message format:
    // - TEXT field: port, name, status, statusDescription, accountName, publicKey, version, hash, color, workgroups, qtVersion, dataStreamVersion, ...
    // - DATA field: hash (user authentication hash)
    // - id: protocol version (cast to VNumber)
    final helloMsg = BeeBeepMessage(
      type: BeeBeepMessageType.hello,
      id: _protocolVersion, // Protocol version as message ID
      flags: 0,
      data: _localHello.hash, // Hash goes in DATA field
      timestamp: DateTime.now(),
      text: _localHello.encodeText(), // Payload goes in TEXT field
    );

    // HELLO is encrypted with the default password cipher (before ECDH key exchange)
    _sendMessage(helloMsg, useInitialCipher: true);

    _sentHello = true;
    _log(
      'TX HELLO port=${_localHello.port} name="${_localHello.displayName}" proto=$_protocolVersion',
    );

    // If we don't get any inbound bytes shortly after HELLO, try the alternate
    // Qt framing variant. We start with u16be (for proto <= 60 compatibility),
    // fallback to u32be in case peer expects it.
    _helloFallbackTimer?.cancel();
    _helloFallbackTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed) return;
      if (_peerHello != null) return;
      if (_cryptoSession.isReady) return;
      if (_rxChunkCount > 0) return;
      if (_txPrefix == QtFramePrefix.u32be) return;

      _txPrefix = QtFramePrefix.u32be;
      _log('No RX bytes after HELLO; retrying with TX framing: u32be');
      _sendMessage(helloMsg, useInitialCipher: true);
      _log('TX HELLO (u32be)');
    });
  }
}
