import 'dart:typed_data';

import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes_fast.dart';

class BeeBeepAesEcb {
  BeeBeepAesEcb({required Uint8List key}) : _key = key;

  final Uint8List _key;

  Uint8List encrypt(Uint8List paddedPlaintext) {
    if (paddedPlaintext.isEmpty) return Uint8List(0);
    final engine = AESFastEngine()..init(true, KeyParameter(_key));

    final out = Uint8List(paddedPlaintext.length);
    for (
      var offset = 0;
      offset < paddedPlaintext.length;
      offset += engine.blockSize
    ) {
      engine.processBlock(paddedPlaintext, offset, out, offset);
    }
    return out;
  }

  Uint8List decrypt(Uint8List ciphertext) {
    if (ciphertext.isEmpty) return Uint8List(0);
    final engine = AESFastEngine()..init(false, KeyParameter(_key));

    final out = Uint8List(ciphertext.length);
    for (
      var offset = 0;
      offset < ciphertext.length;
      offset += engine.blockSize
    ) {
      engine.processBlock(ciphertext, offset, out, offset);
    }
    return out;
  }
}
