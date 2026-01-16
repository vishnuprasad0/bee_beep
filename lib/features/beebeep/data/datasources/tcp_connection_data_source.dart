import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha1.dart';

import 'package:beebeep/core/crypto/beebeep_aes_ecb.dart';
import 'package:beebeep/core/crypto/beebeep_crypto_session.dart';
import 'package:beebeep/core/crypto/beebeep_ecdh_sect163k1.dart';
import 'package:beebeep/core/crypto/beebeep_hash.dart';
import 'package:beebeep/core/crypto/hex.dart';
import 'package:beebeep/core/network/qt_frame_codec.dart';
import 'package:beebeep/core/protocol/beebeep_constants.dart';
import 'package:beebeep/core/protocol/beebeep_message.dart';
import 'package:beebeep/core/protocol/beebeep_message_codec.dart';
import 'package:beebeep/core/protocol/hello_payload.dart';
import 'package:beebeep/features/beebeep/domain/entities/chat_message.dart';
import 'package:beebeep/features/beebeep/domain/entities/peer.dart';
import 'package:beebeep/features/beebeep/domain/entities/peer_identity.dart';
import 'package:beebeep/features/beebeep/domain/entities/received_message.dart';

part 'tcp/beebeep_connection.dart';
part 'tcp/beebeep_connection_file_transfer_mixin.dart';
part 'tcp/beebeep_models.dart';

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
  ServerSocket? _fileServer;
  int? _fileServerPort;
  final List<_BeeBeepConnection> _connections = <_BeeBeepConnection>[];
  final Map<String, _BeeBeepConnection> _connectionsByPeerId =
      <String, _BeeBeepConnection>{};
  final Map<String, List<String>> _pendingChatTextsByPeerId =
      <String, List<String>>{};
  final Map<String, List<_PendingFileTransfer>> _pendingFilesByPeerId =
      <String, List<_PendingFileTransfer>>{};
  final Map<String, List<_PendingFileTransfer>> _pendingBeeBeepFilesByHost =
      <String, List<_PendingFileTransfer>>{};
  int _nextFileInfoId = DateTime.now().millisecondsSinceEpoch;
  int _nextFileTransferMessageId = 1000;

  int? get serverPort => _server?.port;
  bool get isServerRunning => _server != null;
  String get localDisplayName => _localDisplayName;

  void updateLocalDisplayName(String displayName) {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return;
    _localDisplayName = trimmed;
    _log('Local display name updated to "$trimmed"');
  }

  final BeeBeepEcdhSect163k1 _ecdh = BeeBeepEcdhSect163k1();
  late final Sect163k1KeyPair _localKeyPair = _ecdh.generateKeyPair();
  late final BeeBeepMessageCodec _fileTransferCodec = BeeBeepMessageCodec(
    protocolVersion: _protocolVersion,
  );

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
          if (ip.startsWith('169.254.')) continue;
          candidates.add(ip);
        }
      }

      for (final ip in candidates) {
        if (_isRfc1918(ip)) return ip;
      }

      if (candidates.isNotEmpty) return candidates.first;
    } catch (_) {}
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

    await _startFileServer();

    final overridePort = _helloPortOverride();
    if (_helloHostOverride.isNotEmpty || overridePort != 0) {
      _log(
        'HELLO override: host="${_helloHostOverride.isEmpty ? '(none)' : _helloHostOverride}" '
        'port=${overridePort == 0 ? '(none)' : overridePort}',
      );
    }

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

    await _stopFileServer();
  }

  Future<void> _startFileServer() async {
    if (_fileServer != null) return;

    final preferred = (_server?.port ?? 0) + 1;
    final preferredPort = (preferred > 0 && preferred < 65536) ? preferred : 0;

    try {
      _fileServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        preferredPort,
      );
    } catch (_) {
      _fileServer = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }

    _fileServerPort = _fileServer?.port;
    _log('File server listening on :${_fileServerPort ?? 0}');

    _fileServer?.listen(
      (socket) => unawaited(_handleFileServerSocket(socket)),
      onError: (e, st) => _log('File server error: $e'),
      cancelOnError: false,
    );
  }

  Future<void> _stopFileServer() async {
    final s = _fileServer;
    _fileServer = null;
    _fileServerPort = null;
    _pendingBeeBeepFilesByHost.clear();
    await s?.close();
  }

  Future<void> _handleFileServerSocket(Socket socket) async {
    final host = socket.remoteAddress.address;
    final queue = _pendingBeeBeepFilesByHost[host];
    if (queue == null || queue.isEmpty) {
      socket.destroy();
      return;
    }

    final transfer = queue.removeAt(0);
    if (queue.isEmpty) {
      _pendingBeeBeepFilesByHost.remove(host);
    }

    try {
      final iterator = StreamIterator<List<int>>(socket);
      final frameCodec = AdaptiveQtFrameCodec();
      if (_protocolVersion > 60) {
        frameCodec.setPrefix(QtFramePrefix.u32be);
      }

      final session = BeeBeepCryptoSession(
        dataStreamVersion: _dataStreamVersion,
      )..initializeDefaultCipher(_protocolVersion, passwordHex: _passwordHex);

      final helloFrame = await _readNextFrame(
        iterator,
        frameCodec,
        const Duration(seconds: 5),
      );
      if (helloFrame == null) {
        _log('File server handshake failed: missing HELLO from $host');
        await iterator.cancel();
        socket.destroy();
        return;
      }

      final helloMessage = _decodeHelloMessage(helloFrame, session: session);
      if (helloMessage == null) {
        _log('File server handshake failed: invalid HELLO from $host');
        await iterator.cancel();
        socket.destroy();
        return;
      }

      final peerHello = HelloPayload.decodeText(helloMessage.text);
      final encryptionDisabled =
          (helloMessage.flags &
              beeBeepFlagBit(BeeBeepMessageFlag.encryptionDisabled)) !=
          0;

      final keyPair = _ecdh.generateKeyPair();
      final localPublicKey = _ecdh.publicKeyToBeeBeepString(keyPair.publicKey);
      final peerPublicKey = _ecdh.publicKeyFromBeeBeepString(
        peerHello.publicKey,
      );
      final sharedBytes = _ecdh.computeSharedSecret(
        privateKey: keyPair.privateKey,
        peerPublicKey: peerPublicKey,
      );
      final sharedKey = _sharedKeyFromBytes(sharedBytes);
      final cipherKeyHex = _cipherKeyHexFromSharedKey(
        sharedKey,
        peerHello.dataStreamVersion,
      );
      final cipherKeyBytes = _buildAesKeyFromHex(
        cipherKeyHex,
        _protocolVersion,
      );

      final localHello = _buildHelloPayloadWithKey(
        peerHello.port,
        localPublicKey,
      );
      final answer = BeeBeepMessage(
        type: BeeBeepMessageType.hello,
        id: _protocolVersion,
        flags: encryptionDisabled
            ? beeBeepFlagBit(BeeBeepMessageFlag.encryptionDisabled)
            : 0,
        data: localHello.hash,
        timestamp: DateTime.now(),
        text: localHello.encodeText(),
      );
      final answerPlain = _fileTransferCodec.encodePlaintext(
        answer,
        padToBlockSize: true,
      );
      final answerEncrypted = encryptionDisabled
          ? answerPlain
          : session.encryptInitial(answerPlain);
      final answerFrame = _encodeFileTransferFrame(answerEncrypted);
      socket.add(answerFrame);
      await socket.flush();

      final requestFrame = await _readNextFrame(
        iterator,
        frameCodec,
        const Duration(seconds: 8),
      );
      if (requestFrame == null) {
        _log('File server timed out waiting for request from $host');
        await iterator.cancel();
        socket.destroy();
        return;
      }

      final requestPayload = encryptionDisabled
          ? requestFrame
          : _decryptBeeBeepBytes(requestFrame, cipherKeyBytes);
      final request = _fileTransferCodec.decodePlaintext(requestPayload);
      if (request.type == BeeBeepMessageType.file) {
        _log('File server received request for "${request.text}" from $host');
      }

      final infoData =
          transfer.beeBeepInfoData ??
          _buildBeeBeepFileInfo(
            transfer,
            _fileServerPort ?? 0,
            chatPrivateId: '',
          );
      final flags =
          beeBeepFlagBit(BeeBeepMessageFlag.private) |
          (transfer.isVoice
              ? beeBeepFlagBit(BeeBeepMessageFlag.voiceMessage)
              : 0);
      final headerMessage = BeeBeepMessage(
        type: BeeBeepMessageType.file,
        id: _nextFileTransferMessageId++,
        flags: flags,
        data: infoData,
        timestamp: DateTime.now(),
        text: transfer.fileName,
      );
      final headerPlain = _fileTransferCodec.encodePlaintext(
        headerMessage,
        padToBlockSize: true,
      );
      final headerEncrypted = encryptionDisabled
          ? headerPlain
          : _encryptBeeBeepBytes(headerPlain, cipherKeyBytes);
      final headerFrame = _encodeFileTransferFrame(headerEncrypted);
      socket.add(headerFrame);
      await socket.flush();

      const chunkSize = 48 * 1024;
      for (
        var offset = 0;
        offset < transfer.bytes.length;
        offset += chunkSize
      ) {
        final end = (offset + chunkSize).clamp(0, transfer.bytes.length);
        final chunk = transfer.bytes.sublist(offset, end);
        final payload = encryptionDisabled
            ? chunk
            : _encryptBeeBeepBytes(chunk, cipherKeyBytes);
        final frame = _encodeFileTransferFrame(payload);
        socket.add(frame);
        await socket.flush();
      }

      await iterator.cancel();
      socket.destroy();
      _log(
        'File server sent ${transfer.fileSize} bytes to $host for ${transfer.fileName}',
      );
    } catch (e) {
      _log('File server send failed: $e');
      socket.destroy();
    }
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
    Duration? duration,
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
        duration: duration,
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
      onBeeBeepFileInfo: _prepareBeeBeepFileInfo,
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

    final hash = _generateUserHash(
      _localDisplayName,
      passwordHex: _passwordHex,
      signature: _signature,
    );

    return HelloPayload(
      port: port,
      displayName: _localDisplayName,
      status: 1,
      statusDescription: '',
      accountName: _localDisplayName,
      publicKey: publicKey,
      version: '$_protocolVersion',
      hash: hash,
      color: '#0000FF',
      workgroups: '',
      qtVersion: '6.5.0',
      dataStreamVersion: _dataStreamVersion,
      statusChangedIn: null,
      domainName: '',
      localHostName: Platform.localHostname,
    );
  }

  String? _prepareBeeBeepFileInfo(
    _PendingFileTransfer transfer,
    HelloPayload? peerHello,
    String? peerHost,
  ) {
    if (!_shouldUseBeeBeepFileTransfer(peerHello)) return null;
    if (peerHost == null || peerHost.isEmpty) return null;

    final port = _fileServerPort ?? 0;
    if (port <= 0) return null;

    _pendingBeeBeepFilesByHost
        .putIfAbsent(peerHost, () => <_PendingFileTransfer>[])
        .add(transfer);

    return _buildBeeBeepFileInfo(
      transfer,
      port,
      chatPrivateId: peerHello?.hash ?? '',
    );
  }

  bool _shouldUseBeeBeepFileTransfer(HelloPayload? peerHello) {
    if (peerHello == null) return false;
    final version = peerHello.version.trim();
    if (version.isEmpty) return false;
    return int.tryParse(version) == null || version.contains('.');
  }

  String _buildBeeBeepFileInfo(
    _PendingFileTransfer transfer,
    int port, {
    required String chatPrivateId,
  }) {
    final sha1 = SHA1Digest();
    final hashBytes = sha1.process(transfer.bytes);
    final hashHex = _bytesToHex(hashBytes);
    final fileId = _nextFileInfoId++;
    final password = '';
    final now = DateTime.now().toUtc();
    final lastModified = _formatIsoDateUtc(now);
    final mimeType = _sanitizeBeeBeepField(transfer.mimeType ?? '');
    final contentType = transfer.isVoice ? 1 : 0;
    final durationMs = transfer.duration?.inMilliseconds ?? -1;

    final data = [
      port.toString(),
      transfer.fileSize.toString(),
      fileId.toString(),
      _sanitizeBeeBeepField(password),
      _sanitizeBeeBeepField(hashHex),
      _sanitizeBeeBeepField(''),
      '0',
      _sanitizeBeeBeepField(chatPrivateId),
      lastModified,
      mimeType,
      contentType.toString(),
      '0',
      durationMs.toString(),
    ].join(beeBeepDataFieldSeparator);

    transfer.beeBeepInfoData = data;
    return data;
  }

  String _sanitizeBeeBeepField(String value) {
    return value.replaceAll(beeBeepDataFieldSeparator, '_');
  }

  String _formatIsoDateUtc(DateTime dateTime) {
    String two(int v) => v.toString().padLeft(2, '0');
    final y = dateTime.year.toString().padLeft(4, '0');
    final m = two(dateTime.month);
    final d = two(dateTime.day);
    final h = two(dateTime.hour);
    final min = two(dateTime.minute);
    final s = two(dateTime.second);
    return '$y-$m-${d}T$h:$min:${s}Z';
  }

  String _sharedKeyFromBytes(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toString());
    }
    final raw = utf8.encode(sb.toString());
    return base64Url.encode(raw).replaceAll('=', '');
  }

  HelloPayload _buildHelloPayloadWithKey(int port, String publicKey) {
    final hash = _generateUserHash(
      _localDisplayName,
      passwordHex: _passwordHex,
      signature: _signature,
    );

    return HelloPayload(
      port: port,
      displayName: _localDisplayName,
      status: 1,
      statusDescription: '',
      accountName: _localDisplayName,
      publicKey: publicKey,
      version: '$_protocolVersion',
      hash: hash,
      color: '#0000FF',
      workgroups: '',
      qtVersion: '6.5.0',
      dataStreamVersion: _dataStreamVersion,
      statusChangedIn: null,
      domainName: '',
      localHostName: Platform.localHostname,
    );
  }

  Uint8List _encodeFileTransferFrame(Uint8List payload) {
    if (_protocolVersion > 60) {
      return QtFrameCodec().encodeFrame(payload);
    }
    return QtFrameCodec().encodeFrame16(payload);
  }

  Future<Uint8List?> _readNextFrame(
    StreamIterator<List<int>> iterator,
    AdaptiveQtFrameCodec codec,
    Duration timeout,
  ) async {
    while (true) {
      final moved = await Future.any([
        iterator.moveNext(),
        Future<bool>.delayed(timeout, () => false),
      ]);
      if (!moved) return null;
      codec.addChunk(Uint8List.fromList(iterator.current));
      final frames = codec.takeFrames();
      if (frames.isNotEmpty) {
        return frames.first;
      }
    }
  }

  BeeBeepMessage? _decodeHelloMessage(
    Uint8List payload, {
    required BeeBeepCryptoSession session,
  }) {
    try {
      final decrypted = session.decryptInitial(payload);
      final message = _fileTransferCodec.decodePlaintext(decrypted);
      if (message.type == BeeBeepMessageType.hello) return message;
    } catch (_) {}

    final message = _fileTransferCodec.decodePlaintext(payload);
    if (message.type == BeeBeepMessageType.hello) return message;
    return null;
  }

  String _cipherKeyHexFromSharedKey(String sharedKey, int dataStreamVersion) {
    final input = Uint8List.fromList(utf8.encode(sharedKey));
    final digest = dataStreamVersion >= 13 ? sha3_256(input) : sha1(input);
    return bytesToHex(digest);
  }

  Uint8List _buildAesKeyFromHex(String cipherKeyHex, int protocolVersion) {
    const keyLength = beeBeepEncryptionKeyBits ~/ 8;
    if (protocolVersion >= 80) {
      final hexBytes = hexToBytes(cipherKeyHex);
      final padded = Uint8List(keyLength);
      final len = hexBytes.length > keyLength ? keyLength : hexBytes.length;
      padded.setRange(0, len, hexBytes.sublist(0, len));
      return padded;
    }
    return Uint8List(keyLength);
  }

  Uint8List _encryptBeeBeepBytes(Uint8List data, Uint8List key) {
    if (key.isEmpty) return data;
    final cipher = BeeBeepAesEcb(key: key);
    final out = BytesBuilder();
    const blockSize = beeBeepEncryptedDataBlockSize;
    final fullBlocks = data.length ~/ blockSize;
    for (var i = 0; i < fullBlocks; i++) {
      final start = i * blockSize;
      final block = Uint8List.fromList(data.sublist(start, start + blockSize));
      out.add(cipher.encrypt(block));
    }
    final remainderStart = fullBlocks * blockSize;
    if (remainderStart < data.length) {
      out.add(data.sublist(remainderStart));
    }
    return out.takeBytes();
  }

  Uint8List _decryptBeeBeepBytes(Uint8List data, Uint8List key) {
    if (key.isEmpty) return data;
    final cipher = BeeBeepAesEcb(key: key);
    final out = BytesBuilder();
    const blockSize = beeBeepEncryptedDataBlockSize;
    final fullBlocks = data.length ~/ blockSize;
    for (var i = 0; i < fullBlocks; i++) {
      final start = i * blockSize;
      final block = Uint8List.fromList(data.sublist(start, start + blockSize));
      out.add(cipher.decrypt(block));
    }
    final remainderStart = fullBlocks * blockSize;
    if (remainderStart < data.length) {
      out.add(data.sublist(remainderStart));
    }
    return out.takeBytes();
  }

  String _generateUserHash(
    String username, {
    required String passwordHex,
    required String signature,
  }) {
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
