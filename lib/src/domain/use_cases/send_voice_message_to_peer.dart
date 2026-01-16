import 'dart:typed_data';

import '../entities/peer.dart';
import '../repositories/connection_repository.dart';

/// Sends a voice message to a peer.
class SendVoiceMessageToPeer {
  const SendVoiceMessageToPeer(this._repo);

  final ConnectionRepository _repo;

  Future<void> call({
    required Peer peer,
    required String fileName,
    required Uint8List bytes,
    required int fileSize,
    String? mimeType,
  }) {
    return _repo.sendVoiceMessage(
      peer: peer,
      fileName: fileName,
      bytes: bytes,
      fileSize: fileSize,
      mimeType: mimeType,
    );
  }
}
