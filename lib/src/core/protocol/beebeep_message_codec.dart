import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'beebeep_constants.dart';
import 'beebeep_message.dart';

class BeeBeepMessageCodec {
  BeeBeepMessageCodec({required this.protocolVersion});

  final int protocolVersion;

  Uint8List encodePlaintext(
    BeeBeepMessage message, {
    bool padToBlockSize = false,
  }) {
    final header = beeBeepHeaderForType(message.type);

    final timestamp = _timestampToString(message.timestamp);

    // BeeBEEP uses QString::size() which is character count, not byte count
    final payload = [
      header,
      message.id.toString(),
      message.text.length.toString(), // Character count, not byte count!
      message.flags.toString(),
      message.data,
      timestamp,
      message.text,
    ].join(beeBeepProtocolFieldSeparator);

    final bytes = utf8.encode(payload);
    if (!padToBlockSize) {
      return Uint8List.fromList(bytes);
    }

    final padded = _padToBlockSize(bytes);
    return Uint8List.fromList(padded);
  }

  BeeBeepMessage decodePlaintext(Uint8List bytes) {
    final decoded = utf8.decode(bytes, allowMalformed: true);
    final parts = decoded.split(beeBeepProtocolFieldSeparator);
    if (parts.length < 6) {
      return BeeBeepMessage(
        type: BeeBeepMessageType.undefined,
        id: 0,
        flags: 0,
        data: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        text: decoded,
      );
    }

    final header = parts[0];
    final id = int.tryParse(parts[1]) ?? 0;
    final flags = int.tryParse(parts[3]) ?? 0;
    final data = parts[4];
    final timestamp = _timestampFromString(parts[5]);

    final text = parts.length >= 7
        ? parts.sublist(6).join(beeBeepProtocolFieldSeparator)
        : '';

    return BeeBeepMessage(
      type: beeBeepTypeFromHeader(header),
      id: id,
      flags: flags,
      data: data,
      timestamp: timestamp,
      text: text,
    );
  }

  Uint8List maybeCompress(Uint8List plaintext, {required bool compress}) {
    if (!compress) return plaintext;
    final encoded = ZLibCodec().encode(plaintext);
    return Uint8List.fromList(encoded);
  }

  Uint8List maybeDecompress(Uint8List payload, {required bool compressed}) {
    if (!compressed) return payload;
    final decoded = ZLibCodec().decode(payload);
    return Uint8List.fromList(decoded);
  }

  String _timestampToString(DateTime timestamp) {
    if (protocolVersion >= beeBeepUtcTimestampProtocolVersion) {
      final utc = timestamp.toUtc();
      return '${_toIsoDate(utc)}Z';
    }
    final local = timestamp.toLocal();
    return _toIsoDate(local);
  }

  /// Formats DateTime in Qt::ISODate format: yyyy-MM-ddThh:mm:ss
  /// Note: Qt::ISODate does NOT include milliseconds!
  String _toIsoDate(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');

    final y = dt.year.toString().padLeft(4, '0');
    final m = two(dt.month);
    final d = two(dt.day);
    final h = two(dt.hour);
    final min = two(dt.minute);
    final s = two(dt.second);

    return '$y-$m-${d}T$h:$min:$s';
  }

  DateTime _timestampFromString(String input) {
    final parsed = DateTime.tryParse(input);
    if (parsed == null) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    if (protocolVersion >= beeBeepUtcTimestampProtocolVersion) {
      return parsed.isUtc ? parsed : parsed.toUtc();
    }
    return parsed.toLocal();
  }

  List<int> _padToBlockSize(List<int> bytes) {
    final remainder = bytes.length % beeBeepEncryptedDataBlockSize;
    if (remainder == 0) return bytes;

    final pad = beeBeepEncryptedDataBlockSize - remainder;
    return [...bytes, ...List<int>.filled(pad, 0x20)];
  }
}
