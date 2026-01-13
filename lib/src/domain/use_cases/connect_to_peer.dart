import '../entities/peer.dart';
import '../repositories/connection_repository.dart';

class ConnectToPeer {
  const ConnectToPeer(this._repo);

  final ConnectionRepository _repo;

  Future<void> call(Peer peer) => _repo.connect(peer);
}
