import 'package:equatable/equatable.dart';

enum MessageType { text, file, voice }

enum MessageStatus { sending, sent, delivered, read, failed }

class ChatMessage extends Equatable {
  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.text,
    required this.timestamp,
    required this.isOutgoing,
    this.type = MessageType.text,
    this.status = MessageStatus.sent,
    this.filePath,
    this.fileSize,
    this.fileName,
    this.duration,
  });

  final String id;
  final String peerId;
  final String text;
  final DateTime timestamp;
  final bool isOutgoing;
  final MessageType type;
  final MessageStatus status;
  final String? filePath;
  final int? fileSize;
  final String? fileName;
  final Duration? duration;

  ChatMessage copyWith({
    String? id,
    String? peerId,
    String? text,
    DateTime? timestamp,
    bool? isOutgoing,
    MessageType? type,
    MessageStatus? status,
    String? filePath,
    int? fileSize,
    String? fileName,
    Duration? duration,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      text: text ?? this.text,
      timestamp: timestamp ?? this.timestamp,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      type: type ?? this.type,
      status: status ?? this.status,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      fileName: fileName ?? this.fileName,
      duration: duration ?? this.duration,
    );
  }

  @override
  List<Object?> get props => [
    id,
    peerId,
    text,
    timestamp,
    isOutgoing,
    type,
    status,
    filePath,
    fileSize,
    fileName,
    duration,
  ];
}
