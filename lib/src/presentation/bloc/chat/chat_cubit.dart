import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/chat_message.dart';
import 'chat_state.dart';

class ChatCubit extends Cubit<ChatState> {
  ChatCubit() : super(const ChatState());

  void addMessage(ChatMessage message) {
    final updated = [...state.messages, message];
    emit(state.copyWith(messages: updated));
  }

  void updateMessage(String messageId, ChatMessage updatedMessage) {
    final updated = state.messages.map((msg) {
      return msg.id == messageId ? updatedMessage : msg;
    }).toList();
    emit(state.copyWith(messages: updated));
  }

  void clearMessages() {
    emit(const ChatState());
  }

  List<ChatMessage> getMessagesForPeer(String peerId) {
    return state.messages.where((msg) => msg.peerId == peerId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  ChatMessage? getLastMessageForPeer(String peerId) {
    final messages = getMessagesForPeer(peerId);
    return messages.isEmpty ? null : messages.last;
  }

  Map<String, ChatMessage> getLastMessages() {
    final lastMessages = <String, ChatMessage>{};
    for (final message in state.messages) {
      final existing = lastMessages[message.peerId];
      if (existing == null || message.timestamp.isAfter(existing.timestamp)) {
        lastMessages[message.peerId] = message;
      }
    }
    return lastMessages;
  }
}
