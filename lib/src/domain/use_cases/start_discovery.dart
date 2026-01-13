import '../repositories/peer_discovery_repository.dart';

class StartDiscovery {
  const StartDiscovery(this._repo);

  final PeerDiscoveryRepository _repo;

  Future<void> call() => _repo.start();
}
