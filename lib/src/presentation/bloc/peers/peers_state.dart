import 'package:equatable/equatable.dart';

import '../../../domain/entities/peer.dart';

class PeersState extends Equatable {
  const PeersState({
    required this.isDiscovering,
    required this.peers,
    required this.errorMessage,
  });

  const PeersState.initial()
    : isDiscovering = false,
      peers = const <Peer>[],
      errorMessage = null;

  final bool isDiscovering;
  final List<Peer> peers;
  final String? errorMessage;

  PeersState copyWith({
    bool? isDiscovering,
    List<Peer>? peers,
    String? errorMessage,
  }) {
    return PeersState(
      isDiscovering: isDiscovering ?? this.isDiscovering,
      peers: peers ?? this.peers,
      errorMessage: errorMessage,
    );
  }

  @override
  List<Object?> get props => [isDiscovering, peers, errorMessage];
}
