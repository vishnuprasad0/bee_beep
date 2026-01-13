import 'package:equatable/equatable.dart';

import 'beebeep_constants.dart';

class HelloPayload extends Equatable {
  const HelloPayload({
    required this.displayName,
    required this.host,
    required this.port,
    required this.protocolVersion,
    required this.secureLevel,
    required this.dataStreamVersion,
    required this.publicKey,
  });

  final String displayName;
  final String host;
  final int port;
  final int protocolVersion;
  final int secureLevel;
  final int dataStreamVersion;
  final String publicKey;

  String encode() {
    return [
      displayName,
      host,
      port.toString(),
      protocolVersion.toString(),
      secureLevel.toString(),
      dataStreamVersion.toString(),
      publicKey,
    ].join(beeBeepDataFieldSeparator);
  }

  static HelloPayload decode(String data) {
    final parts = data.split(beeBeepDataFieldSeparator);
    if (parts.length < 7) {
      throw FormatException('Invalid HELLO payload');
    }

    return HelloPayload(
      displayName: parts[0],
      host: parts[1],
      port: int.tryParse(parts[2]) ?? 0,
      protocolVersion: int.tryParse(parts[3]) ?? beeBeepLatestProtocolVersion,
      secureLevel: int.tryParse(parts[4]) ?? 4,
      dataStreamVersion: int.tryParse(parts[5]) ?? 13,
      publicKey: parts.sublist(6).join(beeBeepDataFieldSeparator),
    );
  }

  @override
  List<Object?> get props => [
    displayName,
    host,
    port,
    protocolVersion,
    secureLevel,
    dataStreamVersion,
    publicKey,
  ];
}
