import 'package:equatable/equatable.dart';

import 'beebeep_constants.dart';

/// Represents the HELLO message payload as decoded from the message's TEXT field.
///
/// BeeBEEP HELLO message text field order (from Protocol.cpp helloMessage):
/// 0: listenerPort
/// 1: userName
/// 2: userStatus
/// 3: statusDescription
/// 4: accountName
/// 5: publicKey (ECDH)
/// 6: version
/// 7: hash (user hash)
/// 8: color
/// 9: workgroups
/// 10: qtVersion
/// 11: datastreamMaxVersion
/// 12: statusChangedIn (ISO date or empty)
/// 13: domainName
/// 14: localHostName
class HelloPayload extends Equatable {
  const HelloPayload({
    required this.port,
    required this.displayName,
    required this.status,
    required this.statusDescription,
    required this.accountName,
    required this.publicKey,
    required this.version,
    required this.hash,
    required this.color,
    required this.workgroups,
    required this.qtVersion,
    required this.dataStreamVersion,
    this.statusChangedIn,
    this.domainName = '',
    this.localHostName = '',
  });

  final int port;
  final String displayName;
  final int status; // User::Status enum (0=Offline, 1=Online, 2=Away, etc.)
  final String statusDescription;
  final String accountName;
  final String publicKey;
  final String version;
  final String hash;
  final String color;
  final String workgroups;
  final String qtVersion;
  final int dataStreamVersion;
  final String? statusChangedIn;
  final String domainName;
  final String localHostName;

  /// Encodes the payload to go into the HELLO message's TEXT field.
  String encodeText() {
    return [
      port.toString(),
      displayName,
      status.toString(),
      statusDescription,
      accountName,
      publicKey,
      version,
      hash,
      color,
      workgroups,
      qtVersion,
      dataStreamVersion.toString(),
      statusChangedIn ?? '',
      domainName,
      localHostName,
    ].join(beeBeepDataFieldSeparator);
  }

  /// Decodes the HELLO message TEXT field into a HelloPayload.
  static HelloPayload decodeText(String text) {
    final parts = text.split(beeBeepDataFieldSeparator);
    if (parts.length < 6) {
      throw FormatException(
        'Invalid HELLO payload: only ${parts.length} fields',
      );
    }

    return HelloPayload(
      port: int.tryParse(parts[0]) ?? 0,
      displayName: parts.length > 1 ? parts[1] : '',
      status: parts.length > 2 ? (int.tryParse(parts[2]) ?? 1) : 1,
      statusDescription: parts.length > 3 ? parts[3] : '',
      accountName: parts.length > 4 ? parts[4] : '',
      publicKey: parts.length > 5 ? parts[5] : '',
      version: parts.length > 6 ? parts[6] : '',
      hash: parts.length > 7 ? parts[7] : '',
      color: parts.length > 8 ? parts[8] : '#000000',
      workgroups: parts.length > 9 ? parts[9] : '',
      qtVersion: parts.length > 10 ? parts[10] : '',
      dataStreamVersion: parts.length > 11 ? (int.tryParse(parts[11]) ?? 0) : 0,
      statusChangedIn: parts.length > 12 && parts[12].isNotEmpty
          ? parts[12]
          : null,
      domainName: parts.length > 13 ? parts[13] : '',
      localHostName: parts.length > 14 ? parts[14] : '',
    );
  }

  @override
  List<Object?> get props => [
    port,
    displayName,
    status,
    statusDescription,
    accountName,
    publicKey,
    version,
    hash,
    color,
    workgroups,
    qtVersion,
    dataStreamVersion,
    statusChangedIn,
    domainName,
    localHostName,
  ];
}
