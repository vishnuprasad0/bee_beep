import 'dart:typed_data';

import 'dart:math';

class Sect163k1KeyPair {
  Sect163k1KeyPair({required this.privateKey, required this.publicKey});

  final BigInt privateKey;
  final Uint8List publicKey;
}

class BeeBeepEcdhSect163k1 {
  BeeBeepEcdhSect163k1();

  static const int _m = 163;
  static const int _byteLen = 24; // ECDH_PRIVATE_KEY_SIZE for K-163

  static final BigInt _a = BigInt.one;

  static final BigInt _gx = BigInt.parse(
    '02FE13C0537BBC11ACAA07D793DE4E6D5E5C94EEE8',
    radix: 16,
  );
  static final BigInt _gy = BigInt.parse(
    '0289070FB05D38FF58321F2E800536D538CCDAA3D9',
    radix: 16,
  );

  // Irreducible polynomial for sect163k1:
  // x^163 + x^7 + x^6 + x^3 + 1
  static final BigInt _f =
      (BigInt.one << _m) ^
      (BigInt.one << 7) ^
      (BigInt.one << 6) ^
      (BigInt.one << 3) ^
      BigInt.one;

  // Reduction constant for shift-by-1 reduction when bit 163 is set.
  static final BigInt _r =
      (BigInt.one << _m) ^
      (BigInt.one << 7) ^
      (BigInt.one << 6) ^
      (BigInt.one << 3) ^
      BigInt.one;

  Sect163k1KeyPair generateKeyPair() {
    final d = _randomScalar();
    final q = _scalarMult(d, _Point(_gx, _gy));
    return Sect163k1KeyPair(
      privateKey: d,
      publicKey: _encodeBeeBeepPublicKey(q),
    );
  }

  Uint8List computeSharedSecret({
    required BigInt privateKey,
    required Uint8List peerPublicKey,
  }) {
    final peerPoint = _decodeBeeBeepPublicKey(peerPublicKey);
    final sharedPoint = _scalarMult(privateKey, peerPoint);
    return _encodeBeeBeepPublicKey(sharedPoint);
  }

  /// BeeBEEP sends public keys as colon-separated decimal bytes.
  String publicKeyToBeeBeepString(Uint8List publicKey) {
    return publicKey.map((b) => b.toString()).join(':');
  }

  Uint8List publicKeyFromBeeBeepString(String input) {
    return _parseColonSeparatedDecimalBytes(input);
  }

  Uint8List _parseColonSeparatedDecimalBytes(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return Uint8List(0);

    final parts = trimmed.split(':');
    final out = Uint8List(parts.length);

    for (var i = 0; i < parts.length; i++) {
      final v = int.parse(parts[i]);
      if (v < 0 || v > 255) {
        throw FormatException('Byte out of range');
      }
      out[i] = v;
    }

    return out;
  }

  Uint8List _bigIntToFixedLengthLe(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = 0; i < length; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }

  BigInt _randomScalar() {
    final rnd = Random.secure();
    final bytes = Uint8List(_byteLen);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    // Clear bits above curve degree (bits 163..191)
    for (var bit = _m; bit < _byteLen * 8; bit++) {
      final byteIndex = bit >> 3;
      final bitIndex = bit & 7;
      bytes[byteIndex] &= ~(1 << bitIndex);
    }
    var d = _bytesToBigIntLe(bytes);
    if (d == BigInt.zero) {
      d = BigInt.one;
    }
    return d;
  }

  Uint8List _encodeBeeBeepPublicKey(_Point p) {
    if (p.isInfinity) {
      throw StateError('Cannot encode point at infinity');
    }
    final x = _bigIntToFixedLengthLe(p.x, _byteLen);
    final y = _bigIntToFixedLengthLe(p.y, _byteLen);
    return Uint8List.fromList([...x, ...y]);
  }

  _Point _decodeBeeBeepPublicKey(Uint8List bytes) {
    final expected = _byteLen + _byteLen;
    if (bytes.length != expected) {
      throw FormatException('Unexpected point length');
    }

    final x = _bytesToBigIntLe(bytes.sublist(0, _byteLen));
    final y = _bytesToBigIntLe(bytes.sublist(_byteLen, expected));
    final p = _Point(x, y);
    return p;
  }

  BigInt _bytesToBigIntLe(List<int> bytes) {
    var v = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      v = (v << 8) | BigInt.from(bytes[i]);
    }
    return v;
  }

  _Point _scalarMult(BigInt k, _Point p) {
    var result = _Point.infinity();
    var addend = p;
    var scalar = k;
    while (scalar > BigInt.zero) {
      if ((scalar & BigInt.one) == BigInt.one) {
        result = _pointAdd(result, addend);
      }
      addend = _pointDouble(addend);
      scalar = scalar >> 1;
    }
    return result;
  }

  _Point _pointAdd(_Point p, _Point q) {
    if (p.isInfinity) return q;
    if (q.isInfinity) return p;

    if (p.x == q.x) {
      if (_gfAdd(p.y, q.y) == BigInt.zero) {
        return _Point.infinity();
      }
      return _pointDouble(p);
    }

    final lambda = _gfDiv(_gfAdd(p.y, q.y), _gfAdd(p.x, q.x));
    final x3 = _gfAdd(
      _gfAdd(_gfAdd(_gfSquare(lambda), lambda), p.x),
      _gfAdd(q.x, _a),
    );
    final y3 = _gfAdd(_gfMul(lambda, _gfAdd(p.x, x3)), _gfAdd(x3, p.y));
    return _Point(x3, y3);
  }

  _Point _pointDouble(_Point p) {
    if (p.isInfinity) return p;
    if (p.x == BigInt.zero) return _Point.infinity();

    final lambda = _gfAdd(p.x, _gfDiv(p.y, p.x));
    final x3 = _gfAdd(_gfAdd(_gfSquare(lambda), lambda), _a);
    final y3 = _gfAdd(_gfSquare(p.x), _gfMul(_gfAdd(lambda, BigInt.one), x3));
    return _Point(x3, y3);
  }

  BigInt _gfAdd(BigInt x, BigInt y) => x ^ y;

  BigInt _gfMul(BigInt x, BigInt y) {
    var a = x;
    var b = y;
    var r = BigInt.zero;
    while (b > BigInt.zero) {
      if ((b & BigInt.one) == BigInt.one) {
        r = r ^ a;
      }
      b = b >> 1;
      a = a << 1;
      if (((a >> _m) & BigInt.one) == BigInt.one) {
        a = a ^ _r;
      }
    }
    return r;
  }

  BigInt _gfSquare(BigInt x) => _gfMul(x, x);

  BigInt _gfDiv(BigInt x, BigInt y) => _gfMul(x, _gfInv(y));

  BigInt _gfInv(BigInt x) {
    if (x == BigInt.zero) {
      throw ArgumentError('Cannot invert 0');
    }
    var u = x;
    var v = _f;
    var g1 = BigInt.one;
    var g2 = BigInt.zero;

    while (u != BigInt.one) {
      var j = _deg(u) - _deg(v);
      if (j < 0) {
        final tmpU = u;
        u = v;
        v = tmpU;
        final tmpG = g1;
        g1 = g2;
        g2 = tmpG;
        j = -j;
      }

      u = u ^ (v << j);
      g1 = g1 ^ (g2 << j);
    }

    return _gfMod(g1);
  }

  int _deg(BigInt x) => x.bitLength - 1;

  BigInt _gfMod(BigInt x) {
    var v = x;
    while (_deg(v) >= _m) {
      final shift = _deg(v) - _m;
      v = v ^ (_f << shift);
    }
    return v;
  }
}

class _Point {
  _Point(this.x, this.y, {this.isInfinity = false});

  final BigInt x;
  final BigInt y;
  final bool isInfinity;

  factory _Point.infinity() =>
      _Point(BigInt.zero, BigInt.zero, isInfinity: true);
}
