import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha1.dart';

import '../../core/crypto/beebeep_aes_ecb.dart';
import '../../core/crypto/beebeep_crypto_session.dart';
import '../../core/crypto/beebeep_hash.dart';
import '../../core/crypto/hex.dart';
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

  /// Updates the local display name for newly established connections.
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

    await _startFileServer();

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
    this.duration,
  });

  final String fileName;
  final Uint8List bytes;
  final int fileSize;
  final bool isVoice;
  final String? mimeType;
  final Duration? duration;
  String? beeBeepInfoData;
}

class _BeeBeepFileInfo {
  const _BeeBeepFileInfo({
    required this.port,
    required this.fileSize,
    required this.fileName,
    required this.id,
    required this.password,
    required this.fileHash,
    required this.shareFolder,
    required this.isInShareBox,
    required this.chatPrivateId,
    required this.lastModified,
    required this.lastModifiedRaw,
    required this.mimeType,
    required this.contentType,
    required this.startingPosition,
    required this.duration,
  });

  final int port;
  final int fileSize;
  final String fileName;
  final int id;
  final String password;
  final String fileHash;
  final String shareFolder;
  final bool isInShareBox;
  final String chatPrivateId;
  final DateTime? lastModified;
  final String lastModifiedRaw;
  final String mimeType;
  final int contentType;
  final int startingPosition;
  final int duration;
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
    required String? Function(
      _PendingFileTransfer transfer,
      HelloPayload? peerHello,
      String? peerHost,
    )
    onBeeBeepFileInfo,
    required void Function(ReceivedMessage) onReceivedMessage,
  }) : _socket = socket,
       _isIncoming = isIncoming,
       _peerId = expectedPeerId,
       _messageCodec = BeeBeepMessageCodec(protocolVersion: protocolVersion),
       _protocolVersion = protocolVersion,
       _dataStreamVersion = dataStreamVersion,
       _passwordHex = passwordHex,
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
       _onBeeBeepFileInfo = onBeeBeepFileInfo,
       _onReceivedMessage = onReceivedMessage;

  final Socket _socket;
  final bool _isIncoming;
  final AdaptiveQtFrameCodec _rxFramer = AdaptiveQtFrameCodec();
  final QtFrameCodec _txFramer = QtFrameCodec();
  final BeeBeepMessageCodec _messageCodec;
  late final BeeBeepMessageCodec _fileTransferCodec = BeeBeepMessageCodec(
    protocolVersion: _protocolVersion,
  );
  // Kept for protocol-dependent behavior in future parsing.
  // ignore: unused_field
  final int _protocolVersion;
  final int _dataStreamVersion;
  final String _passwordHex;
  final BeeBeepCryptoSession _cryptoSession;
  final HelloPayload _localHello;
  final dynamic _localPrivateKey;
  final BeeBeepEcdhSect163k1 _ecdh;
  final void Function(PeerIdentity) _onPeerIdentity;
  final void Function(String peerId, _BeeBeepConnection conn) _onPeerIdKnown;
  final void Function(String peerId, _BeeBeepConnection conn) _onCryptoReady;
  final void Function(String? peerId, _BeeBeepConnection conn) _onClosed;
  final void Function(String) _log;
  final String? Function(
    _PendingFileTransfer transfer,
    HelloPayload? peerHello,
    String? peerHost,
  )
  _onBeeBeepFileInfo;
  final void Function(ReceivedMessage) _onReceivedMessage;

  StreamSubscription<Uint8List>? _sub;
  Timer? _helloFallbackTimer;
  bool _sentHello = false;
  bool _closed = false;
  int _nextMessageId = 1000;
  String? _peerId;
  Future<void> _txChain = Future.value();
  // ignore: unused_field
  HelloPayload? _peerHello;

  QtFramePrefix? _lastDetectedPrefix;
  int _rxChunkCount = 0;
  // BeeBEEP starts with m_protocolVersion=1, so it expects 16-bit prefix
  // for the initial HELLO. Only switch to 32-bit after receiving peer's HELLO.
  QtFramePrefix _txPrefix = QtFramePrefix.u16be;

  static const int _fileChunkSize = 48 * 1024;
  final Map<String, _IncomingFileBuffer> _incomingFiles = {};

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

    if (msg.type == BeeBeepMessageType.ping) {
      _log('RX BEE-PING id=${msg.id} flags=${msg.flags}');
      _sendPong(msg);
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

  void _sendPong(BeeBeepMessage ping) {
    final message = BeeBeepMessage(
      type: BeeBeepMessageType.pong,
      id: ping.id,
      flags: ping.flags,
      data: ping.data,
      timestamp: DateTime.now(),
      text: ping.text,
    );
    _sendMessage(message);
    _log('TX BEE-PONG id=${message.id}');
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

    final peerHost = remoteHost;
    final beeBeepFileInfo = _onBeeBeepFileInfo(transfer, _peerHello, peerHost);
    if (beeBeepFileInfo != null) {
      final flags =
          beeBeepFlagBit(BeeBeepMessageFlag.private) |
          (transfer.isVoice
              ? beeBeepFlagBit(BeeBeepMessageFlag.voiceMessage)
              : 0);

      final message = BeeBeepMessage(
        type: BeeBeepMessageType.file,
        id: _nextMessageId++,
        flags: flags,
        data: beeBeepFileInfo,
        timestamp: DateTime.now(),
        text: transfer.fileName,
      );

      _sendMessage(message);
      _log(
        'TX BEE-FILE (BeeBEEP) name="${transfer.fileName}" size=${transfer.fileSize} portInfo sent',
      );
      return true;
    }

    final flags = transfer.isVoice
        ? beeBeepFlagBit(BeeBeepMessageFlag.voiceMessage)
        : 0;

    final totalParts = (transfer.bytes.length / _fileChunkSize).ceil().clamp(
      1,
      1 << 30,
    );
    final transferId =
        '${DateTime.now().millisecondsSinceEpoch}_${_nextMessageId}';

    for (var index = 0; index < totalParts; index++) {
      final start = index * _fileChunkSize;
      final end = (start + _fileChunkSize).clamp(0, transfer.bytes.length);
      final chunk = transfer.bytes.sublist(start, end);

      final meta = <String, Object?>{
        'name': transfer.fileName,
        'size': transfer.fileSize,
        'mime': transfer.mimeType,
        'voice': transfer.isVoice,
        'durationMs': transfer.duration?.inMilliseconds,
        'transferId': transferId,
        'partIndex': index,
        'totalParts': totalParts,
      };

      final message = BeeBeepMessage(
        type: BeeBeepMessageType.file,
        id: _nextMessageId++,
        flags: flags,
        data: base64Encode(chunk),
        timestamp: DateTime.now(),
        text: jsonEncode(meta),
      );

      _sendMessage(message);
    }

    _log(
      'TX BEE-FILE name="${transfer.fileName}" size=${transfer.fileSize} voice=${transfer.isVoice} parts=$totalParts',
    );
    return true;
  }

  Future<void> _handleFileMessage(BeeBeepMessage msg) async {
    try {
      final info = _tryParseBeeBeepFileInfo(msg);
      if (info != null) {
        final host = remoteHost ?? '';
        if (host.isEmpty) {
          _log('RX BEE-FILE missing peer host for transfer');
          return;
        }

        final isVoice =
            (msg.flags & beeBeepFlagBit(BeeBeepMessageFlag.voiceMessage)) !=
                0 ||
            info.contentType == 1;
        final bytes = await _downloadBeeBeepFile(host: host, info: info);
        if (bytes == null || bytes.isEmpty) {
          _log('RX BEE-FILE download failed from $host:${info.port}');
          return;
        }

        final savedPath = await _persistIncomingFile(
          fileName: info.fileName,
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
            text: isVoice ? 'Voice message' : info.fileName,
            timestamp: DateTime.now(),
            messageId: msg.id.toString(),
            type: isVoice ? MessageType.voice : MessageType.file,
            filePath: savedPath,
            fileSize: info.fileSize,
            fileName: info.fileName,
          ),
        );

        _log(
          'RX BEE-FILE download complete name="${info.fileName}" size=${info.fileSize} saved="$savedPath"',
        );
        return;
      }

      final metaFromText = _parseFileMeta(msg.text);
      final metaFromData = _parseFileMeta(msg.data);
      final meta = metaFromText.isNotEmpty ? metaFromText : metaFromData;

      final payload = _tryBase64Decode(msg.data) ?? _tryBase64Decode(msg.text);
      if (payload == null || payload.isEmpty) {
        _log('RX BEE-FILE missing base64 payload id=${msg.id}');
        return;
      }
      final isVoice =
          (msg.flags & beeBeepFlagBit(BeeBeepMessageFlag.voiceMessage)) != 0 ||
          (meta['voice'] == true);
      final rawName = meta['name'];
      final fileName = rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : 'file';

      final transferId = meta['transferId'] as String?;
      final partIndex = _asInt(meta['partIndex']);
      final totalParts = _asInt(meta['totalParts']);

      final bytes = payload;
      final rawSize = meta['size'];
      final fileSize = rawSize is int
          ? rawSize
          : (rawSize is num ? rawSize.toInt() : bytes.length);
      final durationMs = meta['durationMs'] as int?;

      if (transferId != null && partIndex != null && totalParts != null) {
        final buffer = _incomingFiles.putIfAbsent(
          transferId,
          () => _IncomingFileBuffer(
            fileName: fileName,
            totalParts: totalParts,
            fileSize: fileSize,
            isVoice: isVoice,
            durationMs: durationMs,
          ),
        );

        buffer.addPart(partIndex, bytes);
        _purgeOldIncoming();

        if (!buffer.isComplete) {
          _log(
            'RX BEE-FILE part ${partIndex + 1}/$totalParts name="$fileName"',
          );
          return;
        }

        final assembled = buffer.assemble();
        _incomingFiles.remove(transferId);

        final savedPath = await _persistIncomingFile(
          fileName: fileName,
          bytes: assembled,
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
          'RX BEE-FILE complete name="$fileName" size=$fileSize voice=$isVoice saved="$savedPath"',
        );
        return;
      }

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
    if (text.trim().isEmpty) return <String, Object?>{};

    try {
      final raw = jsonDecode(text);
      if (raw is Map<String, dynamic>) {
        return raw;
      }
    } catch (_) {
      // Ignore parsing errors.
    }

    final parts = text
        .split(RegExp('[\u2028\n\r]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return <String, Object?>{};

    String? fileName;
    int? fileSize;

    for (final part in parts) {
      final numeric = int.tryParse(part);
      if (numeric != null) {
        if (fileSize == null || numeric > fileSize) {
          fileSize = numeric;
        }
        continue;
      }

      final trimmed = part.replaceAll('\\', '/');
      if (trimmed.contains('/')) {
        final basename = trimmed.split('/').last;
        if (basename.isNotEmpty && !_looksLikeHex(basename)) {
          fileName = basename;
          continue;
        }
      }

      if (part.contains('.') && !_looksLikeHex(part)) {
        fileName = part;
      }
    }

    return <String, Object?>{
      if (fileName != null) 'name': fileName,
      if (fileSize != null) 'size': fileSize,
    };
  }

  _BeeBeepFileInfo? _tryParseBeeBeepFileInfo(BeeBeepMessage msg) {
    final raw = msg.data.trim();
    if (raw.isEmpty) return null;

    final parts = raw
        .split(RegExp('[\u2028\n\r]+'))
        .map((e) => e.trim())
        .toList(growable: false);

    if (parts.length < 4) return null;

    final port = int.tryParse(parts[0]) ?? 0;
    final size = int.tryParse(parts[1]) ?? 0;
    final id = int.tryParse(parts[2]) ?? 0;
    final password = parts[3];
    if (port <= 0 || size <= 0) return null;

    final fileHash = parts.length > 4 ? parts[4] : '';
    final shareFolder = parts.length > 5 ? parts[5] : '';
    final isInShareBox = parts.length > 6 ? parts[6] == '1' : false;
    final chatPrivateId = parts.length > 7 ? parts[7] : '';
    final lastModifiedRaw = parts.length > 8 ? parts[8] : '';
    final lastModified = lastModifiedRaw.isEmpty
        ? null
        : DateTime.tryParse(lastModifiedRaw);
    final mimeType = parts.length > 9 ? parts[9] : '';
    final contentType = parts.length > 10 ? int.tryParse(parts[10]) ?? 0 : 0;
    final startingPosition = parts.length > 11
        ? int.tryParse(parts[11]) ?? 0
        : 0;
    final duration = parts.length > 12 ? int.tryParse(parts[12]) ?? -1 : -1;

    final fileName = msg.text.trim().isNotEmpty
        ? msg.text.trim()
        : (parts.length > 13 ? parts[13] : 'file');

    return _BeeBeepFileInfo(
      port: port,
      fileSize: size,
      fileName: fileName,
      id: id,
      password: password,
      fileHash: fileHash,
      shareFolder: shareFolder,
      isInShareBox: isInShareBox,
      chatPrivateId: chatPrivateId,
      lastModified: lastModified,
      lastModifiedRaw: lastModifiedRaw,
      mimeType: mimeType,
      contentType: contentType,
      startingPosition: startingPosition,
      duration: duration,
    );
  }

  Uint8List? _tryBase64Decode(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    try {
      return base64Decode(trimmed);
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeHex(String value) {
    final trimmed = value.trim();
    if (trimmed.length < 8) return false;
    final hex = RegExp(r'^[0-9a-fA-F]+$');
    return hex.hasMatch(trimmed);
  }

  Future<Uint8List?> _downloadBeeBeepFile({
    required String host,
    required _BeeBeepFileInfo info,
  }) async {
    try {
      final socket = await Socket.connect(
        host,
        info.port,
        timeout: const Duration(seconds: 5),
      );

      final iterator = StreamIterator<List<int>>(socket);
      final frameCodec = AdaptiveQtFrameCodec();
      if (_protocolVersion > 60) {
        frameCodec.setPrefix(QtFramePrefix.u32be);
      }

      final session = BeeBeepCryptoSession(
        dataStreamVersion: _dataStreamVersion,
      )..initializeDefaultCipher(_protocolVersion, passwordHex: _passwordHex);

      final keyPair = _ecdh.generateKeyPair();
      final localPublicKey = _ecdh.publicKeyToBeeBeepString(keyPair.publicKey);
      final localHello = _buildHelloPayloadWithKey(localPublicKey);
      final helloMessage = BeeBeepMessage(
        type: BeeBeepMessageType.hello,
        id: _protocolVersion,
        flags: 0,
        data: localHello.hash,
        timestamp: DateTime.now(),
        text: localHello.encodeText(),
      );
      final helloPlain = _fileTransferCodec.encodePlaintext(
        helloMessage,
        padToBlockSize: true,
      );
      final helloEncrypted = session.encryptInitial(helloPlain);
      final helloFrame = _encodeFileTransferFrame(helloEncrypted);
      socket.add(helloFrame);
      await socket.flush();

      final answerFrame = await _readNextFrame(
        iterator,
        frameCodec,
        const Duration(seconds: 5),
      );
      if (answerFrame == null) {
        _log('RX BEE-FILE handshake failed: missing HELLO from $host');
        await iterator.cancel();
        socket.destroy();
        return null;
      }

      final answerMessage = _decodeHelloMessage(answerFrame, session: session);
      if (answerMessage == null) {
        _log('RX BEE-FILE handshake failed: invalid HELLO from $host');
        await iterator.cancel();
        socket.destroy();
        return null;
      }

      final peerHello = HelloPayload.decodeText(answerMessage.text);
      final encryptionDisabled =
          (answerMessage.flags &
              beeBeepFlagBit(BeeBeepMessageFlag.encryptionDisabled)) !=
          0;
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

      final request = BeeBeepMessage(
        type: BeeBeepMessageType.file,
        id: _nextMessageId++,
        flags: beeBeepFlagBit(BeeBeepMessageFlag.private),
        data: _serializeBeeBeepFileInfoData(info),
        timestamp: DateTime.now(),
        text: info.fileName,
      );
      final requestPlain = _fileTransferCodec.encodePlaintext(
        request,
        padToBlockSize: true,
      );
      final requestPayload = encryptionDisabled
          ? requestPlain
          : _encryptBeeBeepBytes(requestPlain, cipherKeyBytes);
      final requestFrame = _encodeFileTransferFrame(requestPayload);
      socket.add(requestFrame);
      await socket.flush();

      final headerFrame = await _readNextFrame(
        iterator,
        frameCodec,
        const Duration(seconds: 8),
      );
      if (headerFrame == null) {
        _log('RX BEE-FILE missing header from $host');
        await iterator.cancel();
        socket.destroy();
        return null;
      }

      final headerPayload = encryptionDisabled
          ? headerFrame
          : _decryptBeeBeepBytes(headerFrame, cipherKeyBytes);
      final headerMessage = _fileTransferCodec.decodePlaintext(headerPayload);
      if (headerMessage.type != BeeBeepMessageType.file) {
        _log('RX BEE-FILE invalid header from $host');
      }

      final data = BytesBuilder();
      var received = 0;
      while (received < info.fileSize) {
        final frame = await _readNextFrame(
          iterator,
          frameCodec,
          const Duration(seconds: 12),
        );
        if (frame == null) break;
        final payload = encryptionDisabled
            ? frame
            : _decryptBeeBeepBytes(frame, cipherKeyBytes);
        data.add(payload);
        received += payload.length;
      }

      await iterator.cancel();
      socket.destroy();

      final bytes = data.takeBytes();
      if (bytes.length < info.fileSize) {
        _log(
          'RX BEE-FILE expected ${info.fileSize} bytes, got ${bytes.length}',
        );
        return null;
      }
      return Uint8List.fromList(bytes.take(info.fileSize).toList());
    } catch (e) {
      _log('RX BEE-FILE download error: $e');
      return null;
    }
  }

  String _serializeBeeBeepFileInfoData(_BeeBeepFileInfo info) {
    final lastModified = info.lastModifiedRaw.isNotEmpty
        ? info.lastModifiedRaw
        : (info.lastModified == null
              ? ''
              : _formatIsoDateUtc(info.lastModified!.toUtc()));
    return [
      info.port.toString(),
      info.fileSize.toString(),
      info.id.toString(),
      _sanitizeBeeBeepField(info.password),
      _sanitizeBeeBeepField(info.fileHash),
      _sanitizeBeeBeepField(info.shareFolder),
      info.isInShareBox ? '1' : '0',
      _sanitizeBeeBeepField(info.chatPrivateId),
      lastModified,
      _sanitizeBeeBeepField(info.mimeType),
      info.contentType.toString(),
      info.startingPosition.toString(),
      info.duration.toString(),
    ].join(beeBeepDataFieldSeparator);
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

  HelloPayload _buildHelloPayloadWithKey(String publicKey) {
    return HelloPayload(
      port: _localHello.port,
      displayName: _localHello.displayName,
      status: _localHello.status,
      statusDescription: _localHello.statusDescription,
      accountName: _localHello.accountName,
      publicKey: publicKey,
      version: _localHello.version,
      hash: _localHello.hash,
      color: _localHello.color,
      workgroups: _localHello.workgroups,
      qtVersion: _localHello.qtVersion,
      dataStreamVersion: _localHello.dataStreamVersion,
      statusChangedIn: _localHello.statusChangedIn,
      domainName: _localHello.domainName,
      localHostName: _localHello.localHostName,
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

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  void _purgeOldIncoming() {
    final now = DateTime.now();
    _incomingFiles.removeWhere(
      (_, buffer) => now.difference(buffer.createdAt).inMinutes > 10,
    );
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

    _enqueueSend(frame);
  }

  void _enqueueSend(Uint8List frame) {
    _txChain = _txChain.then((_) async {
      if (_closed) return;
      try {
        _socket.add(frame);
        await _socket.flush();
      } catch (e) {
        _log('TX failed: $e');
        await close();
      }
    });
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

class _IncomingFileBuffer {
  _IncomingFileBuffer({
    required this.fileName,
    required this.totalParts,
    required this.fileSize,
    required this.isVoice,
    required this.durationMs,
  });

  final String fileName;
  final int totalParts;
  final int fileSize;
  final bool isVoice;
  final int? durationMs;
  final DateTime createdAt = DateTime.now();
  final Map<int, Uint8List> _parts = {};

  void addPart(int index, Uint8List bytes) {
    _parts[index] = bytes;
  }

  bool get isComplete => _parts.length == totalParts;

  Uint8List assemble() {
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < totalParts; i++) {
      final part = _parts[i];
      if (part == null) continue;
      builder.add(part);
    }
    return builder.takeBytes();
  }
}
