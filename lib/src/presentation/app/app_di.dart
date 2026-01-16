import '../../core/protocol/beebeep_constants.dart';
import '../../data/datasources/bonjour_peer_advertiser_data_source.dart';
import '../../data/datasources/bonjour_peer_discovery_data_source.dart';
import '../../data/datasources/tcp_connection_data_source.dart';
import '../../data/repositories/connection_repository_impl.dart';
import '../../data/repositories/local_node_repository_impl.dart';
import '../../data/repositories/peer_discovery_repository_impl.dart';
import '../../domain/repositories/chat_history_repository.dart';
import '../../domain/repositories/connection_repository.dart';
import '../../domain/repositories/local_node_repository.dart';
import '../../domain/repositories/peer_discovery_repository.dart';
import '../../domain/repositories/peer_cache_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/use_cases/connect_to_peer.dart';
import '../../domain/use_cases/load_chat_history.dart';
import '../../domain/use_cases/load_cached_peers.dart';
import '../../domain/use_cases/load_discovery_name.dart';
import '../../domain/use_cases/load_peer_display_names.dart';
import '../../domain/use_cases/send_chat_to_peer.dart';
import '../../domain/use_cases/send_file_to_peer.dart';
import '../../domain/use_cases/send_voice_message_to_peer.dart';
import '../../domain/use_cases/save_cached_peers.dart';
import '../../domain/use_cases/save_chat_history.dart';
import '../../domain/use_cases/save_peer_display_name.dart';
import '../../domain/use_cases/start_discovery.dart';
import '../../domain/use_cases/start_server.dart';
import '../../domain/use_cases/stop_discovery.dart';
import '../../domain/use_cases/stop_server.dart';
import '../../domain/use_cases/update_discovery_name.dart';
import '../../domain/use_cases/watch_logs.dart';
import '../../domain/use_cases/watch_peers.dart';
import '../../domain/use_cases/watch_peer_identities.dart';
import '../../domain/use_cases/watch_received_messages.dart';

class AppDi {
  AppDi({
    required String displayName,
    required SettingsRepository settingsRepository,
    required ChatHistoryRepository chatHistoryRepository,
    required PeerCacheRepository peerCacheRepository,
  }) : _displayName = displayName,
       _settingsRepository = settingsRepository,
       _chatHistoryRepository = chatHistoryRepository,
       _peerCacheRepository = peerCacheRepository;

  final String _displayName;
  final SettingsRepository _settingsRepository;
  final ChatHistoryRepository _chatHistoryRepository;
  final PeerCacheRepository _peerCacheRepository;

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
  late final LocalNodeRepository localNodeRepository = LocalNodeRepositoryImpl(
    advertiserDataSource: _advertiserDs,
    connectionDataSource: _connectionDs,
  );

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
  late final SendFileToPeer sendFileToPeer = SendFileToPeer(
    connectionRepository,
  );
  late final SendVoiceMessageToPeer sendVoiceMessageToPeer =
      SendVoiceMessageToPeer(connectionRepository);
  late final WatchLogs watchLogs = WatchLogs(connectionRepository);
  late final WatchPeerIdentities watchPeerIdentities = WatchPeerIdentities(
    connectionRepository,
  );
  late final WatchReceivedMessages watchReceivedMessages =
      WatchReceivedMessages(connectionRepository);

  late final LoadChatHistory loadChatHistory = LoadChatHistory(
    _chatHistoryRepository,
  );
  late final SaveChatHistory saveChatHistory = SaveChatHistory(
    _chatHistoryRepository,
  );

  late final LoadDiscoveryName loadDiscoveryName = LoadDiscoveryName(
    _settingsRepository,
  );
  late final UpdateDiscoveryName updateDiscoveryName = UpdateDiscoveryName(
    _settingsRepository,
    localNodeRepository,
  );

  late final LoadPeerDisplayNames loadPeerDisplayNames = LoadPeerDisplayNames(
    _peerCacheRepository,
  );
  late final SavePeerDisplayName savePeerDisplayName = SavePeerDisplayName(
    _peerCacheRepository,
  );
  late final LoadCachedPeers loadCachedPeers = LoadCachedPeers(
    _peerCacheRepository,
  );
  late final SaveCachedPeers saveCachedPeers = SaveCachedPeers(
    _peerCacheRepository,
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

  Future<void> ensureOnline() async {
    if (!_connectionDs.isServerRunning) {
      try {
        await _connectionDs.startServer(port: 6475);
      } catch (_) {
        await _connectionDs.startServer(port: 0);
      }
    }

    final port = _connectionDs.serverPort ?? 0;
    if (port != 0) {
      await _advertiserDs.start(
        name: _connectionDs.localDisplayName,
        port: port,
      );
    }
  }

  Future<void> dispose() async {
    await _advertiserDs.stop();
    await _discoveryDs.dispose();
    await _connectionDs.dispose();
  }
}
