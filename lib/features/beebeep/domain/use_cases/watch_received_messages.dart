import '../repositories/connection_repository.dart';
import '../entities/received_message.dart';

class WatchReceivedMessages {
  const WatchReceivedMessages(this._connectionRepository);

  final ConnectionRepository _connectionRepository;

  Stream<ReceivedMessage> call() {
    return _connectionRepository.watchReceivedMessages();
  }
}
