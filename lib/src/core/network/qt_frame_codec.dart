import 'dart:typed_data';

import 'byte_queue.dart';

/// Implements QDataStream framing used by BeeBEEP.
///
/// For protocol version > 60 (SECURE_LEVEL_2_PROTO_VERSION):
/// - 4 bytes BE: block size (= 4 + payload.length)
/// - 4 bytes BE: QByteArray length (= payload.length)
/// - N bytes: payload
///
/// For older protocols:
/// - 2 bytes BE: block size (= 4 + payload.length)
/// - 4 bytes BE: QByteArray length (= payload.length)
/// - N bytes: payload
class QtFrameCodec {
  QtFrameCodec();

  final ByteQueue _queue = ByteQueue();

  int get bufferedBytes => _queue.length;

  Uint8List peek(int count) => _queue.peek(count);

  void addChunk(Uint8List chunk) {
    _queue.add(chunk);
  }

  List<Uint8List> takeFrames() {
    final frames = <Uint8List>[];

    while (true) {
      // We need at least 8 bytes: 4 for block size + 4 for QByteArray size
      if (_queue.length < 8) break;

      final header = _queue.peek(8);
      final blockSize = _readUint32Be(header.sublist(0, 4));
      final arraySize = _readUint32Be(header.sublist(4, 8));

      // Block size should be 4 + arraySize
      if (blockSize != 4 + arraySize) break;
      if (arraySize < 0 || arraySize > 10 * 1024 * 1024) break;

      // Check if we have the full frame
      if (_queue.length < 8 + arraySize) break;

      _queue.read(8); // consume header
      frames.add(_queue.read(arraySize));
    }

    return frames;
  }

  /// Encodes a frame using QDataStream protocol (version > 60).
  /// Block structure:
  /// - 4 bytes BE: block size (including the next 4 bytes of QByteArray length)
  /// - 4 bytes BE: QByteArray length
  /// - N bytes: payload
  Uint8List encodeFrame(Uint8List payload) {
    final totalLen = 4 + payload.length; // QByteArray size bytes + payload
    final result = Uint8List(4 + 4 + payload.length);
    final bd = ByteData.sublistView(result);
    bd.setUint32(0, totalLen, Endian.big); // block size
    bd.setUint32(4, payload.length, Endian.big); // QByteArray size
    result.setRange(8, 8 + payload.length, payload);
    return result;
  }

  /// Encodes a frame using legacy 16-bit block size (protocol <= 60).
  Uint8List encodeFrame16(Uint8List payload) {
    final totalLen = 4 + payload.length; // QByteArray size bytes + payload
    if (totalLen > 0xFFFF) {
      // Falls back to 32-bit if too large
      return encodeFrame(payload);
    }
    final result = Uint8List(2 + 4 + payload.length);
    final bd = ByteData.sublistView(result);
    bd.setUint16(0, totalLen, Endian.big); // block size (16-bit)
    bd.setUint32(2, payload.length, Endian.big); // QByteArray size
    result.setRange(6, 6 + payload.length, payload);
    return result;
  }

  int _readUint32Be(Uint8List bytes) {
    if (bytes.length < 4) return -1;
    final bd = ByteData.sublistView(bytes);
    return bd.getUint32(0, Endian.big);
  }
}

enum QtFramePrefix { u16be, u32be }

/// Adaptive decoder for QDataStream framing.
///
/// For protocol > 60: 4-byte block size + 4-byte QByteArray size + payload
/// For protocol <= 60: 2-byte block size + 4-byte QByteArray size + payload
///
/// The block size = QByteArray size bytes (4) + payload length.
class AdaptiveQtFrameCodec {
  AdaptiveQtFrameCodec({this.maxFrameSize = 5 * 1024 * 1024});

  final int maxFrameSize;

  final ByteQueue _queue = ByteQueue();
  QtFramePrefix? _prefix;

  QtFramePrefix? get prefix => _prefix;
  int get bufferedBytes => _queue.length;

  void addChunk(Uint8List chunk) {
    _queue.add(chunk);
  }

  List<Uint8List> takeFrames() {
    final frames = <Uint8List>[];

    while (true) {
      final selected = _prefix ?? _detectPrefix();
      if (selected == null) break;
      _prefix = selected;

      final blockSizeBytes = selected == QtFramePrefix.u32be ? 4 : 2;
      final headerSize = blockSizeBytes + 4; // block size + QByteArray size

      if (_queue.length < headerSize) break;

      final blockSize = selected == QtFramePrefix.u32be
          ? _readUint32Be(_queue.peekRange(0, 4))
          : _readUint16Be(_queue.peekRange(0, 2));

      // Block size should be >= 4 (the QByteArray size itself)
      if (blockSize < 4 || blockSize > maxFrameSize + 4) break;

      // Payload size = blockSize - 4
      final payloadSize = blockSize - 4;

      // Total frame = blockSizeBytes + blockSize (which includes 4 + payload)
      if (_queue.length < blockSizeBytes + blockSize) break;

      // Verify the QByteArray size matches
      final arraySize = _readUint32Be(_queue.peekRange(blockSizeBytes, 4));
      if (arraySize != payloadSize) {
        // Mismatch - possibly wrong framing, try to recover
        _prefix = null;
        break;
      }

      _queue.read(headerSize);
      frames.add(_queue.read(payloadSize));
    }

    return frames;
  }

  QtFramePrefix? _detectPrefix() {
    // Try u32be first (modern protocol > 60)
    if (_queue.length >= 8) {
      final blockSize32 = _readUint32Be(_queue.peekRange(0, 4));
      if (blockSize32 >= 4 && blockSize32 <= maxFrameSize + 4) {
        final arraySize32 = _readUint32Be(_queue.peekRange(4, 4));
        if (arraySize32 == blockSize32 - 4) {
          // Check if payload starts with BEE-
          if (_queue.length >= 8 + 4) {
            final prefix = _queue.peekRange(8, 4);
            if (_isBeePrefix(prefix)) {
              return QtFramePrefix.u32be;
            }
          }
          // Even without BEE- prefix, u32 looks valid
          return QtFramePrefix.u32be;
        }
      }
    }

    // Try u16be (legacy protocol <= 60)
    if (_queue.length >= 6) {
      final blockSize16 = _readUint16Be(_queue.peekRange(0, 2));
      if (blockSize16 >= 4 && blockSize16 <= maxFrameSize + 4) {
        final arraySize16 = _readUint32Be(_queue.peekRange(2, 4));
        if (arraySize16 == blockSize16 - 4) {
          if (_queue.length >= 6 + 4) {
            final prefix = _queue.peekRange(6, 4);
            if (_isBeePrefix(prefix)) {
              return QtFramePrefix.u16be;
            }
          }
          return QtFramePrefix.u16be;
        }
      }
    }

    return null;
  }

  bool _isBeePrefix(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return bytes[0] == 0x42 && // B
        bytes[1] == 0x45 && // E
        bytes[2] == 0x45 && // E
        bytes[3] == 0x2D; // -
  }

  int _readUint32Be(Uint8List bytes) {
    if (bytes.length < 4) return -1;
    final bd = ByteData.sublistView(bytes);
    return bd.getUint32(0, Endian.big);
  }

  int _readUint16Be(Uint8List bytes) {
    if (bytes.length < 2) return -1;
    final bd = ByteData.sublistView(bytes);
    return bd.getUint16(0, Endian.big);
  }
}
