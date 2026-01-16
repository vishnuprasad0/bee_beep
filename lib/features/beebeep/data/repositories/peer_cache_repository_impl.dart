import '../../domain/entities/cached_peer.dart';
import '../../domain/repositories/peer_cache_repository.dart';
import '../datasources/peer_cache_hive_data_source.dart';

class PeerCacheRepositoryImpl implements PeerCacheRepository {
  PeerCacheRepositoryImpl(this._dataSource);

  final PeerCacheHiveDataSource _dataSource;

  @override
  Future<Map<String, CachedPeer>> loadAll() async => _dataSource.loadAll();

  @override
  Future<void> savePeer(CachedPeer peer) => _dataSource.savePeer(peer);

  @override
  Future<void> savePeers(Iterable<CachedPeer> peers) {
    return _dataSource.savePeers(peers);
  }

  @override
  Future<void> saveDisplayName({
    required String peerId,
    required String displayName,
  }) {
    return _dataSource.saveDisplayName(
      peerId: peerId,
      displayName: displayName,
    );
  }
}
