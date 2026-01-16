import 'package:hive/hive.dart';

import '../../domain/entities/chat_message.dart';

/// Local chat history storage backed by Hive.
class ChatHistoryHiveDataSource {
  ChatHistoryHiveDataSource(this._box);

  static const String boxName = 'chat_history';

  final Box<ChatMessage> _box;

  /// Loads all persisted messages.
  List<ChatMessage> loadMessages() {
    final messages = _box.values.toList(growable: false);
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  /// Persists the provided messages list.
  Future<void> saveMessages(List<ChatMessage> messages) {
    return _box.clear().then((_) => _box.addAll(messages));
  }
}
