import '../entities/cached_peer.dart';

/// Repository for cached peer data.
abstract interface class PeerCacheRepository {
  Future<Map<String, CachedPeer>> loadAll();

  Future<void> savePeer(CachedPeer peer);

  Future<void> savePeers(Iterable<CachedPeer> peers);

  Future<void> saveDisplayName({
    required String peerId,
    required String displayName,
  });
}
