part of '../tcp_connection_data_source.dart';

abstract class _BeeBeepConnectionBase {
  BeeBeepCryptoSession get _cryptoSession;
  void Function(String) get _log;
  String? get remoteHost;
  HelloPayload? get _peerHello;
  String? get _peerId;
  String? Function(
    _PendingFileTransfer transfer,
    HelloPayload? peerHello,
    String? peerHost,
  )
  get _onBeeBeepFileInfo;
  void Function(ReceivedMessage) get _onReceivedMessage;
  int get _nextMessageId;
  set _nextMessageId(int value);
  Map<String, _IncomingFileBuffer> get _incomingFiles;
  int get _protocolVersion;
  int get _dataStreamVersion;
  String get _passwordHex;
  BeeBeepEcdhSect163k1 get _ecdh;
  BeeBeepMessageCodec get _fileTransferCodec;
  HelloPayload get _localHello;
  String _sharedKeyFromBytes(Uint8List bytes);
  void _sendMessage(BeeBeepMessage message);
}

class _BeeBeepConnection extends _BeeBeepConnectionBase
    with _BeeBeepConnectionFileTransferMixin {
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
  HelloPayload? _peerHello;

  QtFramePrefix? _lastDetectedPrefix;
  int _rxChunkCount = 0;
  QtFramePrefix _txPrefix = QtFramePrefix.u16be;

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
    } catch (_) {}

    _onClosed(_peerId, this);
  }

  void _handleFrame(Uint8List frame) {
    Uint8List plaintext;
    if (_cryptoSession.isReady) {
      try {
        plaintext = _cryptoSession.decrypt(frame);
      } catch (_) {
        plaintext = frame;
      }
    } else {
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
      } catch (_) {}
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

  void _sendMessage(BeeBeepMessage message, {bool useInitialCipher = false}) {
    final useSessionCipher = _cryptoSession.isReady;
    final shouldEncrypt = useSessionCipher || useInitialCipher;

    Uint8List payload = _messageCodec.encodePlaintext(
      message,
      padToBlockSize: shouldEncrypt,
    );

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
        payload = _cryptoSession.encryptInitial(payload);
        _log('TX encrypted with initial cipher (${payload.length} bytes)');
      }
    }

    final frame = _encodeTxFrame(payload);

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
      final peerHello = HelloPayload.decodeText(msg.text);
      _peerHello = peerHello;

      final peerProtoVersion = msg.id;
      _log('RX HELLO from ${peerHello.displayName} (proto=$peerProtoVersion)');

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

    final helloMsg = BeeBeepMessage(
      type: BeeBeepMessageType.hello,
      id: _protocolVersion,
      flags: 0,
      data: _localHello.hash,
      timestamp: DateTime.now(),
      text: _localHello.encodeText(),
    );

    _sendMessage(helloMsg, useInitialCipher: true);

    _sentHello = true;
    _log(
      'TX HELLO port=${_localHello.port} name="${_localHello.displayName}" proto=$_protocolVersion',
    );

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
