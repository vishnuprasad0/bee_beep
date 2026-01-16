import '../../domain/entities/chat_message.dart';
import '../../domain/repositories/chat_history_repository.dart';
import '../datasources/chat_history_hive_data_source.dart';

/// Hive-backed implementation of [ChatHistoryRepository].
class ChatHistoryRepositoryImpl implements ChatHistoryRepository {
  ChatHistoryRepositoryImpl(this._dataSource);

  final ChatHistoryHiveDataSource _dataSource;

  @override
  Future<List<ChatMessage>> loadMessages() async => _dataSource.loadMessages();

  @override
  Future<void> saveMessages(List<ChatMessage> messages) {
    return _dataSource.saveMessages(messages);
  }
}
