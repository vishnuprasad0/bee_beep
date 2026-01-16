import '../entities/cached_peer.dart';
import '../repositories/peer_cache_repository.dart';

class LoadCachedPeers {
  const LoadCachedPeers(this._repo);

  final PeerCacheRepository _repo;

  Future<Map<String, CachedPeer>> call() => _repo.loadAll();
}
