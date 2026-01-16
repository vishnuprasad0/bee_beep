import 'dart:typed_data';

/// Finite field GF(2^163) for sect163k1 (NIST K-163).
///
/// Reduction polynomial: x^163 + x^7 + x^6 + x^3 + 1
class Gf2m163 {
  static const int m = 163;

  static final BigInt _rp =
      (BigInt.one << 163) |
      (BigInt.one << 7) |
      (BigInt.one << 6) |
      (BigInt.one << 3) |
      BigInt.one;

  BigInt add(BigInt a, BigInt b) => a ^ b;

  BigInt reduce(BigInt x) {
    var r = x;
    while (r.bitLength > m) {
      final shift = r.bitLength - m - 1;
      r ^= _rp << shift;
    }
    return r;
  }

  BigInt multiply(BigInt a, BigInt b) {
    var aa = reduce(a);
    var bb = reduce(b);

    var res = BigInt.zero;

    while (bb != BigInt.zero) {
      if ((bb & BigInt.one) == BigInt.one) {
        res ^= aa;
      }
      bb = bb >> 1;

      final carry = (aa >> (m - 1)) & BigInt.one;
      aa = (aa << 1) & ((BigInt.one << m) - BigInt.one);
      if (carry == BigInt.one) {
        aa ^= _rp & ((BigInt.one << m) - BigInt.one);
      }
    }

    return reduce(res);
  }

  BigInt square(BigInt a) => multiply(a, a);

  BigInt inverse(BigInt a) {
    var u = reduce(a);
    if (u == BigInt.zero) {
      throw ArgumentError('Cannot invert 0 in GF(2^m)');
    }

    var v = _rp;
    var g1 = BigInt.one;
    var g2 = BigInt.zero;

    while (u != BigInt.one) {
      var j = u.bitLength - v.bitLength;
      if (j < 0) {
        final tmpU = u;
        u = v;
        v = tmpU;

        final tmpG = g1;
        g1 = g2;
        g2 = tmpG;

        j = -j;
      }

      u ^= v << j;
      g1 ^= g2 << j;

      u = reduce(u);
      g1 = reduce(g1);
    }

    return reduce(g1);
  }

  Uint8List toFixedBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }

  BigInt fromBytes(Uint8List bytes) {
    var v = BigInt.zero;
    for (final b in bytes) {
      v = (v << 8) | BigInt.from(b);
    }
    return reduce(v);
  }
}
