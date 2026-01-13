import 'dart:typed_data';

import 'package:pointycastle/digests/sha1.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha3.dart';

Uint8List sha1(Uint8List input) {
  final d = SHA1Digest();
  return d.process(input);
}

Uint8List sha256(Uint8List input) {
  final d = SHA256Digest();
  return d.process(input);
}

Uint8List sha3_256(Uint8List input) {
  final d = SHA3Digest(256);
  return d.process(input);
}
