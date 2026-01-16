part of '../tcp_connection_data_source.dart';

class _PendingFileTransfer {
  _PendingFileTransfer({
    required this.fileName,
    required this.bytes,
    required this.fileSize,
    required this.isVoice,
    this.mimeType,
    this.duration,
  });

  final String fileName;
  final Uint8List bytes;
  final int fileSize;
  final bool isVoice;
  final String? mimeType;
  final Duration? duration;
  String? beeBeepInfoData;
}

class _BeeBeepFileInfo {
  const _BeeBeepFileInfo({
    required this.port,
    required this.fileSize,
    required this.fileName,
    required this.id,
    required this.password,
    required this.fileHash,
    required this.shareFolder,
    required this.isInShareBox,
    required this.chatPrivateId,
    required this.lastModified,
    required this.lastModifiedRaw,
    required this.mimeType,
    required this.contentType,
    required this.startingPosition,
    required this.duration,
  });

  final int port;
  final int fileSize;
  final String fileName;
  final int id;
  final String password;
  final String fileHash;
  final String shareFolder;
  final bool isInShareBox;
  final String chatPrivateId;
  final DateTime? lastModified;
  final String lastModifiedRaw;
  final String mimeType;
  final int contentType;
  final int startingPosition;
  final int duration;
}

class _IncomingFileBuffer {
  _IncomingFileBuffer({
    required this.fileName,
    required this.totalParts,
    required this.fileSize,
    required this.isVoice,
    required this.durationMs,
  }) : createdAt = DateTime.now();

  final String fileName;
  final int totalParts;
  final int fileSize;
  final bool isVoice;
  final int? durationMs;
  final DateTime createdAt;
  final Map<int, Uint8List> chunks = <int, Uint8List>{};

  bool get isComplete => chunks.length >= totalParts;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (var i = 0; i < totalParts; i++) {
      final part = chunks[i];
      if (part == null) continue;
      builder.add(part);
    }
    final bytes = builder.takeBytes();
    if (bytes.length > fileSize) {
      return Uint8List.fromList(bytes.sublist(0, fileSize));
    }
    return bytes;
  }
}
