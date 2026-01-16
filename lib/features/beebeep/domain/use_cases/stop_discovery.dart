import '../repositories/peer_discovery_repository.dart';

class StopDiscovery {
  const StopDiscovery(this._repo);

  final PeerDiscoveryRepository _repo;

  Future<void> call() => _repo.stop();
}
