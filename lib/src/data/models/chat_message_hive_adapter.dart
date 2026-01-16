import 'package:hive/hive.dart';

import '../../domain/entities/chat_message.dart';

/// Hive adapter for persisting [ChatMessage] instances.
class ChatMessageAdapter extends TypeAdapter<ChatMessage> {
  @override
  final int typeId = 1;

  @override
  ChatMessage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      final fieldId = reader.readByte();
      fields[fieldId] = reader.read();
    }

    return ChatMessage(
      id: fields[0] as String,
      peerId: fields[1] as String,
      text: fields[2] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(fields[3] as int),
      isOutgoing: fields[4] as bool,
      type: MessageType.values[fields[5] as int],
      status: MessageStatus.values[fields[6] as int],
      filePath: fields[7] as String?,
      fileSize: fields[8] as int?,
      fileName: fields[9] as String?,
      duration: fields[10] != null
          ? Duration(milliseconds: fields[10] as int)
          : null,
    );
  }

  @override
  void write(BinaryWriter writer, ChatMessage obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.peerId)
      ..writeByte(2)
      ..write(obj.text)
      ..writeByte(3)
      ..write(obj.timestamp.millisecondsSinceEpoch)
      ..writeByte(4)
      ..write(obj.isOutgoing)
      ..writeByte(5)
      ..write(obj.type.index)
      ..writeByte(6)
      ..write(obj.status.index)
      ..writeByte(7)
      ..write(obj.filePath)
      ..writeByte(8)
      ..write(obj.fileSize)
      ..writeByte(9)
      ..write(obj.fileName)
      ..writeByte(10)
      ..write(obj.duration?.inMilliseconds);
  }
}
