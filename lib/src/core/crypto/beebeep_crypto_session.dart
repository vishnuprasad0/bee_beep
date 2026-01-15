import 'dart:convert';
import 'dart:typed_data';

import '../protocol/beebeep_constants.dart';
import 'beebeep_aes_ecb.dart';
import 'beebeep_hash.dart';
import 'hex.dart';

/// Default password used for initial HELLO encryption before ECDH key exchange.
/// BeeBEEP uses "*6475*" as the default password string.
const String _beeBeepDefaultPasswordString = '*6475*';

/// Computes the default password hash: SHA1("*6475*").toHex()
/// This is used as the cipher key for encrypting HELLO before ECDH completes.
String beeBeepDefaultPasswordHex() {
  final input = Uint8List.fromList(utf8.encode(_beeBeepDefaultPasswordString));
  return bytesToHex(sha1(input));
}

class BeeBeepCryptoSession {
  BeeBeepCryptoSession({required this.dataStreamVersion});

  final int dataStreamVersion;
  BeeBeepAesEcb? _cipher;
  BeeBeepAesEcb? _initialCipher;

  bool get isReady => _cipher != null;

  /// Initialize the "initial" cipher used for HELLO encryption before ECDH.
  /// BeeBEEP encrypts HELLO using Settings::instance().password() which is
  /// SHA1("*6475*").toHex() by default.
  void initializeDefaultCipher(int protocolVersion, {String? passwordHex}) {
    final resolvedPasswordHex = passwordHex ?? beeBeepDefaultPasswordHex();
    final keyBytes = _buildAesKeyFromHex(resolvedPasswordHex, protocolVersion);
    _initialCipher = BeeBeepAesEcb(key: keyBytes);
    // Debug: Print the password hex and derived key
    // ignore: avoid_print
    print('[CryptoSession] Password hex: $resolvedPasswordHex');
    // ignore: avoid_print
    print(
      '[CryptoSession] AES key (${keyBytes.length} bytes): ${bytesToHex(keyBytes)}',
    );
  }

  void setSharedKey(String sharedKey) {
    final cipherKeyHex = _generateCipherKeyHex(sharedKey);
    final keyBytes = _normalizeAes256Key(hexToBytes(cipherKeyHex));
    _cipher = BeeBeepAesEcb(key: keyBytes);
  }

  /// Encrypt using the initial (pre-ECDH) password-based cipher.
  Uint8List encryptInitial(Uint8List paddedPlaintext) {
    final cipher = _initialCipher;
    if (cipher == null) {
      throw StateError('Initial cipher not initialized');
    }
    if (paddedPlaintext.length % beeBeepEncryptedDataBlockSize != 0) {
      throw ArgumentError('Plaintext must be padded to 16-byte boundary');
    }
    return cipher.encrypt(paddedPlaintext);
  }

  /// Decrypt using the initial (pre-ECDH) password-based cipher.
  Uint8List decryptInitial(Uint8List ciphertext) {
    final cipher = _initialCipher;
    if (cipher == null) {
      throw StateError('Initial cipher not initialized');
    }
    if (ciphertext.length % beeBeepEncryptedDataBlockSize != 0) {
      throw ArgumentError('Ciphertext must be 16-byte aligned');
    }
    return cipher.decrypt(ciphertext);
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

  /// Build AES-256 key from hex string following BeeBEEP's algorithm.
  /// For proto >= SECURE_LEVEL_3_PROTO_VERSION (80): use hexToUnsignedChar
  /// For older proto: broken key initialization (basically zeros)
  Uint8List _buildAesKeyFromHex(String cipherKeyHex, int protocolVersion) {
    const keyLength = beeBeepEncryptionKeyBits ~/ 8; // 32 bytes

    if (protocolVersion >= 80) {
      // SECURE_LEVEL_3_PROTO_VERSION
      // hexToUnsignedChar: convert hex string to bytes, pad/truncate to keyLength
      final hexBytes = hexToBytes(cipherKeyHex);
      if (hexBytes.length >= keyLength) {
        return Uint8List.fromList(hexBytes.sublist(0, keyLength));
      }
      // Pad with zeros if shorter
      final padded = Uint8List(keyLength);
      padded.setRange(0, hexBytes.length, hexBytes);
      return padded;
    } else {
      // Legacy broken key initialization - key is mostly zeros
      // This matches BeeBEEP's buggy code for old protocols
      return Uint8List(keyLength);
    }
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
