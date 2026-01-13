import '../entities/peer.dart';
import '../entities/peer_identity.dart';

abstract interface class ConnectionRepository {
  Stream<String> watchLogs();

  Stream<PeerIdentity> watchPeerIdentities();

  Future<void> startServer({required int port});

  Future<void> stopServer();

  Future<void> connect(Peer peer);

  Future<void> disconnectAll();
}
