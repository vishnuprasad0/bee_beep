part of '../tcp_connection_data_source.dart';

mixin _BeeBeepConnectionFileTransferMixin on _BeeBeepConnectionBase {
  static const int _fileChunkSize = 48 * 1024;
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

    final totalParts = (transfer.bytes.length / _fileChunkSize)
        .ceil()
        .clamp(1, 1 << 30)
        .toInt();
    final transferId =
        '${DateTime.now().millisecondsSinceEpoch}_${_nextMessageId}';

    for (var index = 0; index < totalParts; index++) {
      final start = index * _fileChunkSize;
      final end = (start + _fileChunkSize)
          .clamp(0, transfer.bytes.length)
          .toInt();
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

        buffer.chunks[partIndex] = bytes;

        _log('RX BEE-FILE part ${partIndex + 1}/$totalParts name="$fileName"');

        if (!buffer.isComplete) return;

        _incomingFiles.remove(transferId);
        _purgeOldIncoming();

        final savedPath = await _persistIncomingFile(
          fileName: fileName,
          bytes: buffer.assemble(),
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
            duration: durationMs == null
                ? null
                : Duration(milliseconds: durationMs),
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
          duration: durationMs == null
              ? null
              : Duration(milliseconds: durationMs),
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
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}

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
}
