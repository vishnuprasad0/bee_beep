import 'dart:typed_data';

class ByteQueue {
  ByteQueue();

  final List<int> _buffer = <int>[];

  int get length => _buffer.length;

  void add(Uint8List bytes) {
    _buffer.addAll(bytes);
  }

  Uint8List peek(int count) {
    if (count <= 0) return Uint8List(0);
    final end = count > _buffer.length ? _buffer.length : count;
    return Uint8List.fromList(_buffer.sublist(0, end));
  }

  Uint8List read(int count) {
    if (count <= 0) return Uint8List(0);
    final end = count > _buffer.length ? _buffer.length : count;
    final out = Uint8List.fromList(_buffer.sublist(0, end));
    _buffer.removeRange(0, end);
    return out;
  }

  void clear() => _buffer.clear();
}
