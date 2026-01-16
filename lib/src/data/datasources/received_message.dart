import 'package:equatable/equatable.dart';

import '../../domain/entities/chat_message.dart';

class ReceivedMessage extends Equatable {
  const ReceivedMessage({
    required this.peerId,
    required this.peerName,
    required this.text,
    required this.timestamp,
    required this.messageId,
    this.type = MessageType.text,
    this.filePath,
    this.fileSize,
    this.fileName,
    this.duration,
  });

  final String peerId;
  final String peerName;
  final String text;
  final DateTime timestamp;
  final String messageId;
  final MessageType type;
  final String? filePath;
  final int? fileSize;
  final String? fileName;
  final Duration? duration;

  @override
  List<Object?> get props => [
    peerId,
    peerName,
    text,
    timestamp,
    messageId,
    type,
    filePath,
    fileSize,
    fileName,
    duration,
  ];
}
