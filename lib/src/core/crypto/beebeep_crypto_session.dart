import 'dart:convert';
import 'dart:typed_data';

import '../protocol/beebeep_constants.dart';
import 'beebeep_aes_ecb.dart';
import 'beebeep_hash.dart';
import 'hex.dart';

class BeeBeepCryptoSession {
  BeeBeepCryptoSession({required this.dataStreamVersion});

  final int dataStreamVersion;
  BeeBeepAesEcb? _cipher;

  bool get isReady => _cipher != null;

  void setSharedKey(String sharedKey) {
    final cipherKeyHex = _generateCipherKeyHex(sharedKey);
    final keyBytes = _normalizeAes256Key(hexToBytes(cipherKeyHex));
    _cipher = BeeBeepAesEcb(key: keyBytes);
  }

  Uint8List encrypt(Uint8List paddedPlaintext) {
    final cipher = _cipher;
    if (cipher == null) {
      throw StateError('Crypto session not initialized');
    }
    if (paddedPlaintext.length % beeBeepEncryptedDataBlockSize != 0) {
      throw ArgumentError('Plaintext must be padded to 16-byte boundary');
    }
    return cipher.encrypt(paddedPlaintext);
  }

  Uint8List decrypt(Uint8List ciphertext) {
    final cipher = _cipher;
    if (cipher == null) {
      throw StateError('Crypto session not initialized');
    }
    if (ciphertext.length % beeBeepEncryptedDataBlockSize != 0) {
      throw ArgumentError('Ciphertext must be 16-byte aligned');
    }
    return cipher.decrypt(ciphertext);
  }

  String _generateCipherKeyHex(String sharedKey) {
    final input = Uint8List.fromList(utf8.encode(sharedKey));

    // BeeBEEP behavior depends on QDataStream version; for recent versions it uses SHA3-256.
    if (dataStreamVersion >= 13) {
      return bytesToHex(sha3_256(input));
    }

    // Legacy path.
    return bytesToHex(sha1(input));
  }

  Uint8List _normalizeAes256Key(Uint8List keyBytes) {
    if (keyBytes.length == beeBeepEncryptionKeyBits ~/ 8) {
      return keyBytes;
    }

    // Some legacy BeeBEEP configurations historically derived a shorter key.
    // To keep the AES-256 key size stable, hash whatever we have to 32 bytes.
    return sha256(keyBytes);
  }
}
