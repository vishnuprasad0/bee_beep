import '../entities/peer.dart';
import '../repositories/peer_discovery_repository.dart';

class WatchPeers {
  const WatchPeers(this._repo);

  final PeerDiscoveryRepository _repo;

  Stream<List<Peer>> call() => _repo.watchPeers();
}
