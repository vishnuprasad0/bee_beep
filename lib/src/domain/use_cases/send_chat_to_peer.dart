import '../entities/peer.dart';
import '../repositories/connection_repository.dart';

class SendChatToPeer {
  const SendChatToPeer(this._repo);

  final ConnectionRepository _repo;

  Future<void> call({required Peer peer, required String text}) {
    return _repo.sendChat(peer: peer, text: text);
  }
}
