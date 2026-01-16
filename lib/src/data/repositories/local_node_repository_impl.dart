import '../../domain/repositories/local_node_repository.dart';
import '../datasources/bonjour_peer_advertiser_data_source.dart';
import '../datasources/tcp_connection_data_source.dart';

/// Implementation that updates local node identity and broadcast.
class LocalNodeRepositoryImpl implements LocalNodeRepository {
  LocalNodeRepositoryImpl({
    required BonjourPeerAdvertiserDataSource advertiserDataSource,
    required TcpConnectionDataSource connectionDataSource,
  }) : _advertiserDataSource = advertiserDataSource,
       _connectionDataSource = connectionDataSource;

  final BonjourPeerAdvertiserDataSource _advertiserDataSource;
  final TcpConnectionDataSource _connectionDataSource;

  @override
  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    _connectionDataSource.updateLocalDisplayName(trimmed);

    final port = _connectionDataSource.serverPort;
    if (port != null && port != 0) {
      await _advertiserDataSource.start(name: trimmed, port: port);
    }
  }
}
