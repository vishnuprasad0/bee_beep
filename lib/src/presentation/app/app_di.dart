import '../../core/protocol/beebeep_constants.dart';
import '../../data/datasources/bonjour_peer_advertiser_data_source.dart';
import '../../data/datasources/bonjour_peer_discovery_data_source.dart';
import '../../data/datasources/tcp_connection_data_source.dart';
import '../../data/repositories/connection_repository_impl.dart';
import '../../data/repositories/peer_discovery_repository_impl.dart';
import '../../domain/repositories/connection_repository.dart';
import '../../domain/repositories/peer_discovery_repository.dart';
import '../../domain/use_cases/connect_to_peer.dart';
import '../../domain/use_cases/send_chat_to_peer.dart';
import '../../domain/use_cases/start_discovery.dart';
import '../../domain/use_cases/start_server.dart';
import '../../domain/use_cases/stop_discovery.dart';
import '../../domain/use_cases/stop_server.dart';
import '../../domain/use_cases/watch_logs.dart';
import '../../domain/use_cases/watch_peers.dart';
import '../../domain/use_cases/watch_peer_identities.dart';

class AppDi {
  AppDi({required String displayName}) : _displayName = displayName;

  final String _displayName;

  late final BonjourPeerDiscoveryDataSource _discoveryDs =
      BonjourPeerDiscoveryDataSource();
  late final BonjourPeerAdvertiserDataSource _advertiserDs =
      BonjourPeerAdvertiserDataSource();

  late final TcpConnectionDataSource _connectionDs = TcpConnectionDataSource(
    localDisplayName: _displayName,
    protocolVersion: beeBeepLatestProtocolVersion,
    dataStreamVersion: 18,
  );

  late final PeerDiscoveryRepository peerDiscoveryRepository =
      PeerDiscoveryRepositoryImpl(_discoveryDs);
  late final ConnectionRepository connectionRepository =
      ConnectionRepositoryImpl(_connectionDs);

  late final StartDiscovery startDiscovery = StartDiscovery(
    peerDiscoveryRepository,
  );
  late final StopDiscovery stopDiscovery = StopDiscovery(
    peerDiscoveryRepository,
  );
  late final WatchPeers watchPeers = WatchPeers(peerDiscoveryRepository);

  late final StartServer startServer = StartServer(connectionRepository);
  late final StopServer stopServer = StopServer(connectionRepository);
  late final ConnectToPeer connectToPeer = ConnectToPeer(connectionRepository);
  late final SendChatToPeer sendChatToPeer = SendChatToPeer(
    connectionRepository,
  );
  late final WatchLogs watchLogs = WatchLogs(connectionRepository);
  late final WatchPeerIdentities watchPeerIdentities = WatchPeerIdentities(
    connectionRepository,
  );

  Future<void> startNode() async {
    // BeeBEEP defaults to TCP 6475 for chat/system messages.
    // Try to bind it first for maximum interoperability.
    try {
      await _connectionDs.startServer(port: 6475);
    } catch (_) {
      await _connectionDs.startServer(port: 0);
    }
    final port = _connectionDs.serverPort ?? 0;
    if (port != 0) {
      await _advertiserDs.start(name: _displayName, port: port);
    }
  }

  Future<void> dispose() async {
    await _advertiserDs.stop();
    await _discoveryDs.dispose();
    await _connectionDs.dispose();
  }
}
