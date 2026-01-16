import '../entities/chat_message.dart';
import '../repositories/chat_history_repository.dart';

/// Persists chat history.
class SaveChatHistory {
  const SaveChatHistory(this._repo);

  final ChatHistoryRepository _repo;

  Future<void> call(List<ChatMessage> messages) => _repo.saveMessages(messages);
}
