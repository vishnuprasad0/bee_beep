import 'package:equatable/equatable.dart';

import '../../../domain/entities/peer.dart';

class PeerPresence extends Equatable {
  const PeerPresence({
    required this.peer,
    required this.isOnline,
    required this.lastSeen,
  });

  final Peer peer;
  final bool isOnline;
  final DateTime? lastSeen;

  @override
  List<Object?> get props => [peer, isOnline, lastSeen];
}
