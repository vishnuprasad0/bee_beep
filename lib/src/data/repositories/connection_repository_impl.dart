import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_identity.dart';
import '../../domain/repositories/connection_repository.dart';
import '../datasources/received_message.dart';
import '../datasources/tcp_connection_data_source.dart';

class ConnectionRepositoryImpl implements ConnectionRepository {
  ConnectionRepositoryImpl(this._dataSource);

  final TcpConnectionDataSource _dataSource;

  @override
  Stream<String> watchLogs() => _dataSource.watchLogs();

  @override
  Stream<PeerIdentity> watchPeerIdentities() =>
      _dataSource.watchPeerIdentities();

  @override
  Stream<ReceivedMessage> watchReceivedMessages() =>
      _dataSource.watchReceivedMessages();

  @override
  Future<void> startServer({required int port}) =>
      _dataSource.startServer(port: port);

  @override
  Future<void> stopServer() => _dataSource.stopServer();

  @override
  Future<void> connect(Peer peer) => _dataSource.connect(peer);

  @override
  Future<void> sendChat({required Peer peer, required String text}) =>
      _dataSource.sendChat(peer: peer, text: text);

  @override
  Future<void> disconnectAll() => _dataSource.disconnectAll();
}
