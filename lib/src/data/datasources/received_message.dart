import 'package:equatable/equatable.dart';

class ReceivedMessage extends Equatable {
  const ReceivedMessage({
    required this.peerId,
    required this.peerName,
    required this.text,
    required this.timestamp,
    required this.messageId,
  });

  final String peerId;
  final String peerName;
  final String text;
  final DateTime timestamp;
  final String messageId;

  @override
  List<Object?> get props => [peerId, peerName, text, timestamp, messageId];
}
