import 'dart:math';
import 'dart:typed_data';

import 'gf2m_163.dart';

class Sect163k1Point {
  const Sect163k1Point._(this.x, this.y, this.isInfinity);

  factory Sect163k1Point.infinity() =>
      Sect163k1Point._(BigInt.zero, BigInt.zero, true);

  factory Sect163k1Point(BigInt x, BigInt y) => Sect163k1Point._(x, y, false);

  final BigInt x;
  final BigInt y;
  final bool isInfinity;
}

class Sect163k1KeyPair {
  Sect163k1KeyPair({required this.privateKey, required this.publicKey});

  final BigInt privateKey;
  final Sect163k1Point publicKey;
}

class Sect163k1 {
  Sect163k1() : _f = Gf2m163();

  final Gf2m163 _f;

  static final BigInt a = BigInt.one;
  static final BigInt b = BigInt.one;

  static final BigInt n = BigInt.parse(
    '04000000000000000000020108A2E0CC0D99F8A5EF',
    radix: 16,
  );

  static const int cofactor = 2;

  static final Sect163k1Point g = Sect163k1Point(
    BigInt.parse('02FE13C0537BBC11ACAA07D793DE4E6D5E5C94EEE8', radix: 16),
    BigInt.parse('0289070FB05D38FF58321F2E800536D538CCDAA3D9', radix: 16),
  );

  Sect163k1KeyPair generateKeyPair() {
    final d = _randomScalar(n);
    final q = multiply(g, d);
    return Sect163k1KeyPair(privateKey: d, publicKey: q);
  }

  Uint8List computeSharedSecret({
    required BigInt privateKey,
    required Sect163k1Point peerPublicKey,
  }) {
    final p = multiply(peerPublicKey, privateKey);
    if (p.isInfinity) {
      throw StateError('Invalid ECDH agreement: infinity');
    }

    // BeeBEEP uses the x-coordinate as the shared secret material.
    return _f.toFixedBytes(p.x, 21);
  }

  Sect163k1Point decodeUncompressedPoint(Uint8List bytes) {
    if (bytes.isEmpty || bytes[0] != 0x04) {
      throw FormatException('Expected uncompressed point');
    }
    final expectedLen = 1 + 21 + 21;
    if (bytes.length != expectedLen) {
      throw FormatException('Unexpected point length: ${bytes.length}');
    }

    final x = _f.fromBytes(Uint8List.fromList(bytes.sublist(1, 1 + 21)));
    final y = _f.fromBytes(Uint8List.fromList(bytes.sublist(1 + 21)));

    return Sect163k1Point(x, y);
  }

  Uint8List encodeUncompressedPoint(Sect163k1Point point) {
    if (point.isInfinity) {
      throw ArgumentError('Cannot encode infinity');
    }

    final xb = _f.toFixedBytes(point.x, 21);
    final yb = _f.toFixedBytes(point.y, 21);
    return Uint8List.fromList([0x04, ...xb, ...yb]);
  }

  Sect163k1Point add(Sect163k1Point p, Sect163k1Point q) {
    if (p.isInfinity) return q;
    if (q.isInfinity) return p;

    if (p.x == q.x) {
      if (_f.add(p.y, q.y) == BigInt.zero) {
        return Sect163k1Point.infinity();
      }
      return doublePoint(p);
    }

    final lambda = _f.multiply(_f.add(p.y, q.y), _f.inverse(_f.add(p.x, q.x)));

    final x3 = _f.add(
      _f.add(_f.add(_f.square(lambda), lambda), _f.add(p.x, q.x)),
      a,
    );

    final y3 = _f.add(_f.add(_f.multiply(lambda, _f.add(p.x, x3)), x3), p.y);

    return Sect163k1Point(x3, y3);
  }

  Sect163k1Point doublePoint(Sect163k1Point p) {
    if (p.isInfinity) return p;
    if (p.x == BigInt.zero) return Sect163k1Point.infinity();

    final invX = _f.inverse(p.x);
    final lambda = _f.add(p.x, _f.multiply(p.y, invX));

    final x3 = _f.add(_f.add(_f.square(lambda), lambda), a);

    final y3 = _f.add(
      _f.square(p.x),
      _f.multiply(_f.add(lambda, BigInt.one), x3),
    );

    return Sect163k1Point(x3, y3);
  }

  Sect163k1Point multiply(Sect163k1Point p, BigInt k) {
    var result = Sect163k1Point.infinity();
    var addend = p;

    var kk = k;
    while (kk > BigInt.zero) {
      if ((kk & BigInt.one) == BigInt.one) {
        result = add(result, addend);
      }
      kk = kk >> 1;
      if (kk == BigInt.zero) break;
      addend = doublePoint(addend);
    }

    return result;
  }

  BigInt _randomScalar(BigInt upperExclusive) {
    final r = Random.secure();
    final bytesLen = (upperExclusive.bitLength + 7) ~/ 8;

    while (true) {
      final bytes = Uint8List(bytesLen);
      for (var i = 0; i < bytesLen; i++) {
        bytes[i] = r.nextInt(256);
      }

      var v = BigInt.zero;
      for (final b in bytes) {
        v = (v << 8) | BigInt.from(b);
      }

      v = v % upperExclusive;
      if (v != BigInt.zero) return v;
    }
  }
}
