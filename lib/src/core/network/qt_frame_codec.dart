import 'dart:typed_data';

import 'byte_queue.dart';

/// Implements a simple Qt/QDataStream-like framing used by BeeBEEP:
/// a big-endian 32-bit length prefix followed by that many bytes of payload.
class QtFrameCodec {
  QtFrameCodec();

  final ByteQueue _queue = ByteQueue();

  void addChunk(Uint8List chunk) {
    _queue.add(chunk);
  }

  List<Uint8List> takeFrames() {
    final frames = <Uint8List>[];

    while (true) {
      if (_queue.length < 4) break;

      final header = _queue.peek(4);
      final size = _readUint32Be(header);

      if (size < 0) break;
      if (_queue.length < 4 + size) break;

      _queue.read(4);
      frames.add(_queue.read(size));
    }

    return frames;
  }

  Uint8List encodeFrame(Uint8List payload) {
    final sizeBytes = Uint8List(4);
    final data = ByteData.sublistView(sizeBytes);
    data.setUint32(0, payload.length, Endian.big);
    return Uint8List.fromList([...sizeBytes, ...payload]);
  }

  int _readUint32Be(Uint8List bytes) {
    if (bytes.length < 4) return -1;
    final bd = ByteData.sublistView(bytes);
    return bd.getUint32(0, Endian.big);
  }
}
