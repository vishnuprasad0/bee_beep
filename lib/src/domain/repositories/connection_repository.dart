import '../../data/datasources/received_message.dart';
import '../entities/peer.dart';
import '../entities/peer_identity.dart';

abstract interface class ConnectionRepository {
  Stream<String> watchLogs();

  Stream<PeerIdentity> watchPeerIdentities();

  Stream<ReceivedMessage> watchReceivedMessages();

  Future<void> startServer({required int port});

  Future<void> stopServer();

  Future<void> connect(Peer peer);

  Future<void> sendChat({required Peer peer, required String text});

  Future<void> disconnectAll();
}
