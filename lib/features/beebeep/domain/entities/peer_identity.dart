import 'package:equatable/equatable.dart';

class PeerIdentity extends Equatable {
  const PeerIdentity({required this.peerId, required this.displayName});

  final String peerId;
  final String displayName;

  @override
  List<Object?> get props => [peerId, displayName];
}
