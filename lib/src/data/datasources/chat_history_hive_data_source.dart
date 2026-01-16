import 'package:hive/hive.dart';

import '../../domain/entities/chat_message.dart';

/// Local chat history storage backed by Hive.
class ChatHistoryHiveDataSource {
  ChatHistoryHiveDataSource(this._box);

  static const String boxName = 'chat_history';
  static const String _messagesKey = 'messages';

  final Box<List<ChatMessage>> _box;

  /// Loads all persisted messages.
  List<ChatMessage> loadMessages() {
    return _box.get(_messagesKey, defaultValue: const <ChatMessage>[]) ??
        const <ChatMessage>[];
  }

  /// Persists the provided messages list.
  Future<void> saveMessages(List<ChatMessage> messages) {
    return _box.put(_messagesKey, messages);
  }
}
