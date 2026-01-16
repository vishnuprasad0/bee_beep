import '../repositories/peer_cache_repository.dart';

class SavePeerDisplayName {
  const SavePeerDisplayName(this._repo);

  final PeerCacheRepository _repo;

  Future<void> call({required String peerId, required String displayName}) {
    return _repo.saveDisplayName(peerId: peerId, displayName: displayName);
  }
}
