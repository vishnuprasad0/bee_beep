import 'package:equatable/equatable.dart';

class CachedPeer extends Equatable {
  const CachedPeer({
    required this.peerId,
    required this.displayName,
    required this.host,
    required this.port,
    required this.lastSeen,
  });

  final String peerId;
  final String displayName;
  final String host;
  final int port;
  final DateTime lastSeen;

  CachedPeer copyWith({
    String? displayName,
    String? host,
    int? port,
    DateTime? lastSeen,
  }) {
    return CachedPeer(
      peerId: peerId,
      displayName: displayName ?? this.displayName,
      host: host ?? this.host,
      port: port ?? this.port,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  List<Object?> get props => [peerId, displayName, host, port, lastSeen];
}
