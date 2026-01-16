import '../entities/chat_message.dart';

/// Repository for chat history persistence.
abstract interface class ChatHistoryRepository {
  /// Loads all stored messages.
  Future<List<ChatMessage>> loadMessages();

  /// Persists the provided messages list.
  Future<void> saveMessages(List<ChatMessage> messages);
}
