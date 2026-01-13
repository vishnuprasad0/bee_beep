import 'dart:typed_data';

Uint8List hexToBytes(String hex) {
  final normalized = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (normalized.isEmpty) return Uint8List(0);

  final even = normalized.length.isEven ? normalized : '0$normalized';
  final out = Uint8List(even.length ~/ 2);

  for (var i = 0; i < even.length; i += 2) {
    out[i ~/ 2] = int.parse(even.substring(i, i + 2), radix: 16);
  }

  return out;
}

String bytesToHex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
