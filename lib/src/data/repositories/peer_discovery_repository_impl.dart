import 'dart:async';

import '../../domain/entities/peer.dart';
import '../../domain/repositories/peer_discovery_repository.dart';
import '../datasources/bonjour_peer_discovery_data_source.dart';

class PeerDiscoveryRepositoryImpl implements PeerDiscoveryRepository {
  PeerDiscoveryRepositoryImpl(this._dataSource);

  final BonjourPeerDiscoveryDataSource _dataSource;

  @override
  Stream<List<Peer>> watchPeers() => _dataSource.watchPeers();

  @override
  Future<void> start() => _dataSource.start();

  @override
  Future<void> stop() => _dataSource.stop();
}
