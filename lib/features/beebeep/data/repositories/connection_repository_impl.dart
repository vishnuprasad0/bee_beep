import 'dart:typed_data';

import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_identity.dart';
import '../../domain/entities/received_message.dart';
import '../../domain/repositories/connection_repository.dart';
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
  Future<void> sendFile({
    required Peer peer,
    required String fileName,
    required Uint8List bytes,
    required int fileSize,
    String? mimeType,
  }) {
    return _dataSource.sendFile(
      peer: peer,
      fileName: fileName,
      bytes: bytes,
      fileSize: fileSize,
      mimeType: mimeType,
    );
  }

  @override
  Future<void> sendVoiceMessage({
    required Peer peer,
    required String fileName,
    required Uint8List bytes,
    required int fileSize,
    String? mimeType,
    Duration? duration,
  }) {
    return _dataSource.sendVoiceMessage(
      peer: peer,
      fileName: fileName,
      bytes: bytes,
      fileSize: fileSize,
      mimeType: mimeType,
      duration: duration,
    );
  }

  @override
  Future<void> disconnectAll() => _dataSource.disconnectAll();
}
