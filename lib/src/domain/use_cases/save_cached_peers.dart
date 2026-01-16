import '../entities/cached_peer.dart';
import '../repositories/peer_cache_repository.dart';

class SaveCachedPeers {
  const SaveCachedPeers(this._repo);

  final PeerCacheRepository _repo;

  Future<void> call(Iterable<CachedPeer> peers) => _repo.savePeers(peers);
}
