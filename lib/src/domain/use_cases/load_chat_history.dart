import '../entities/chat_message.dart';
import '../repositories/chat_history_repository.dart';

/// Loads persisted chat history.
class LoadChatHistory {
  const LoadChatHistory(this._repo);

  final ChatHistoryRepository _repo;

  Future<List<ChatMessage>> call() => _repo.loadMessages();
}
