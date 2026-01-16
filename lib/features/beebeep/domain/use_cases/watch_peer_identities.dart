import '../entities/peer_identity.dart';
import '../repositories/connection_repository.dart';

class WatchPeerIdentities {
  const WatchPeerIdentities(this._repo);

  final ConnectionRepository _repo;

  Stream<PeerIdentity> call() => _repo.watchPeerIdentities();
}
