import '../repositories/peer_cache_repository.dart';

class LoadPeerDisplayNames {
  const LoadPeerDisplayNames(this._repo);

  final PeerCacheRepository _repo;

  Future<Map<String, String>> call() async {
    final cached = await _repo.loadAll();
    return cached.map((key, value) => MapEntry(key, value.displayName));
  }
}
