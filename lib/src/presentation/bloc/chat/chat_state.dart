import 'package:equatable/equatable.dart';

import '../../../domain/entities/chat_message.dart';

class ChatState extends Equatable {
  const ChatState({this.messages = const []});

  final List<ChatMessage> messages;

  ChatState copyWith({List<ChatMessage>? messages}) {
    return ChatState(messages: messages ?? this.messages);
  }

  @override
  List<Object?> get props => [messages];
}
