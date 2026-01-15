import '../../data/datasources/received_message.dart';
import '../repositories/connection_repository.dart';

class WatchReceivedMessages {
  const WatchReceivedMessages(this._connectionRepository);

  final ConnectionRepository _connectionRepository;

  Stream<ReceivedMessage> call() {
    return _connectionRepository.watchReceivedMessages();
  }
}
