import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../domain/entities/chat_message.dart';
import '../../domain/entities/peer.dart';
import '../../domain/use_cases/send_chat_to_peer.dart';
import '../../domain/use_cases/send_file_to_peer.dart';
import '../../domain/use_cases/send_voice_message_to_peer.dart';
import '../bloc/chat/chat_cubit.dart';
import '../bloc/chat/chat_state.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({required this.peer, super.key});

  final Peer peer;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _recorder = AudioRecorder();

  bool _isRecording = false;
  DateTime? _recordStart;
  String? _recordPath;
  Duration _recordElapsed = Duration.zero;
  Timer? _recordTimer;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _recorder.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final sendChatToPeer = context.read<SendChatToPeer>();
    sendChatToPeer(peer: widget.peer, text: text);

    // Add to local chat state
    final chatCubit = context.read<ChatCubit>();
    final message = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      peerId: widget.peer.id,
      text: text,
      timestamp: DateTime.now(),
      isOutgoing: true,
      status: MessageStatus.sent,
    );
    chatCubit.addMessage(message);

    _textController.clear();
    _scrollToBottom();
  }

  Future<void> _sendFile() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      withReadStream: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    var bytes = file.bytes;
    if (bytes == null && file.readStream != null) {
      final builder = BytesBuilder();
      await for (final chunk in file.readStream!) {
        builder.add(chunk);
      }
      bytes = builder.takeBytes();
    }
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to read file bytes')),
        );
      }
      return;
    }

    final sendFileToPeer = context.read<SendFileToPeer>();
    await sendFileToPeer(
      peer: widget.peer,
      fileName: file.name,
      bytes: bytes,
      fileSize: file.size > 0 ? file.size : bytes.length,
    );

    final chatCubit = context.read<ChatCubit>();
    final message = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      peerId: widget.peer.id,
      text: file.name,
      timestamp: DateTime.now(),
      isOutgoing: true,
      status: MessageStatus.sent,
      type: MessageType.file,
      fileName: file.name,
      fileSize: file.size,
      filePath: file.path,
    );
    chatCubit.addMessage(message);
    _scrollToBottom();
  }

  Future<void> _sendVoiceFile(File file, Duration? duration) async {
    final bytes = await file.readAsBytes();
    final sendVoiceMessage = context.read<SendVoiceMessageToPeer>();
    await sendVoiceMessage(
      peer: widget.peer,
      fileName: file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : 'voice.aac',
      bytes: bytes,
      fileSize: bytes.length,
      duration: duration,
    );

    final chatCubit = context.read<ChatCubit>();
    final message = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      peerId: widget.peer.id,
      text: 'Voice message',
      timestamp: DateTime.now(),
      isOutgoing: true,
      status: MessageStatus.sent,
      type: MessageType.voice,
      fileName: file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : 'voice.aac',
      fileSize: bytes.length,
      filePath: file.path,
      duration: duration,
    );
    chatCubit.addMessage(message);
    _scrollToBottom();
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
      }
      return;
    }

    final dir = await getTemporaryDirectory();
    final fileName =
        'voice_${DateTime.now().millisecondsSinceEpoch.toString()}.aac';
    final path = '${dir.path}/$fileName';

    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );

    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final start = _recordStart ?? DateTime.now();
      setState(() {
        _recordElapsed = DateTime.now().difference(start);
      });
    });

    setState(() {
      _isRecording = true;
      _recordStart = DateTime.now();
      _recordPath = path;
      _recordElapsed = Duration.zero;
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    if (!_isRecording) return;
    _recordTimer?.cancel();
    await _recorder.stop();

    final path = _recordPath;
    final duration = _recordElapsed;

    setState(() {
      _isRecording = false;
      _recordStart = null;
      _recordPath = null;
      _recordElapsed = Duration.zero;
    });

    if (path == null) return;
    final file = File(path);
    if (!send) {
      if (file.existsSync()) {
        await file.delete();
      }
      return;
    }

    if (!file.existsSync()) return;
    await _sendVoiceFile(file, duration);
  }

  String _recordingLabel() {
    final minutes = _recordElapsed.inMinutes;
    final seconds = _recordElapsed.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.peer.displayName),
            Text(
              '${widget.peer.host}:${widget.peer.port}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: BlocBuilder<ChatCubit, ChatState>(
              builder: (context, state) {
                final messages = context.read<ChatCubit>().getMessagesForPeer(
                  widget.peer.id,
                );

                if (messages.isEmpty) {
                  return Center(
                    child: Text(
                      'No messages yet\nSay hi to ${widget.peer.displayName}!',
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(color: Colors.grey),
                    ),
                  );
                }

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _scrollToBottom();
                });

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return _MessageBubble(
                      message: message,
                      isConsecutive:
                          index > 0 &&
                          messages[index - 1].isOutgoing ==
                              message.isOutgoing &&
                          message.timestamp
                                  .difference(messages[index - 1].timestamp)
                                  .inMinutes <
                              5,
                    );
                  },
                );
              },
            ),
          ),
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildMessageInput() {
    final hasText = _textController.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _isRecording
              ? Row(
                  key: const ValueKey('recording'),
                  children: [
                    const SizedBox(width: 6),
                    const Icon(Icons.mic, color: Colors.redAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Recording ${_recordingLabel()}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _stopRecording(send: false),
                    ),
                    FloatingActionButton(
                      mini: true,
                      onPressed: () => _stopRecording(send: true),
                      child: const Icon(Icons.send),
                    ),
                  ],
                )
              : Row(
                  key: const ValueKey('composer'),
                  children: [
                    IconButton(
                      icon: const Icon(Icons.emoji_emotions_outlined),
                      onPressed: () {
                        final selection = _textController.selection;
                        final text = _textController.text;
                        final insertAt = selection.isValid
                            ? selection.start
                            : text.length;
                        final newText = text.replaceRange(
                          insertAt,
                          insertAt,
                          '😊',
                        );
                        _textController.value = TextEditingValue(
                          text: newText,
                          selection: TextSelection.collapsed(
                            offset: insertAt + '😊'.length,
                          ),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.attach_file),
                      onPressed: _sendFile,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                        ),
                        maxLines: null,
                        textCapitalization: TextCapitalization.sentences,
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (hasText)
                      FloatingActionButton(
                        mini: true,
                        onPressed: _sendMessage,
                        child: const Icon(Icons.send),
                      )
                    else
                      GestureDetector(
                        onLongPressStart: (_) => _startRecording(),
                        onLongPressEnd: (_) => _stopRecording(send: true),
                        child: FloatingActionButton(
                          mini: true,
                          onPressed: _startRecording,
                          child: const Icon(Icons.mic),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isConsecutive});

  final ChatMessage message;
  final bool isConsecutive;

  @override
  Widget build(BuildContext context) {
    final isOutgoing = message.isOutgoing;
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: isConsecutive ? 2 : 12,
        left: isOutgoing ? 64 : 0,
        right: isOutgoing ? 0 : 64,
      ),
      child: Align(
        alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: isOutgoing
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                color: isOutgoing
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isOutgoing ? 16 : 4),
                  bottomRight: Radius.circular(isOutgoing ? 4 : 16),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.type == MessageType.file)
                    _buildFilePreview(context)
                  else if (message.type == MessageType.voice)
                    _buildVoicePreview(context)
                  else
                    Text(
                      message.text,
                      style: TextStyle(
                        color: isOutgoing
                            ? Colors.white
                            : theme.colorScheme.onSurface,
                        fontSize: 16,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(message.timestamp),
                        style: TextStyle(
                          color: isOutgoing
                              ? Colors.white70
                              : theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      if (isOutgoing) ...[
                        const SizedBox(width: 4),
                        Icon(
                          _getStatusIcon(message.status),
                          size: 16,
                          color: Colors.white70,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilePreview(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.insert_drive_file,
          color: message.isOutgoing ? Colors.white : Colors.blue,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.fileName ?? 'File',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: message.isOutgoing ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (message.fileSize != null)
                Text(
                  _formatFileSize(message.fileSize!),
                  style: TextStyle(
                    color: message.isOutgoing ? Colors.white70 : Colors.black54,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVoicePreview(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.mic, color: message.isOutgoing ? Colors.white : Colors.blue),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            message.duration != null
                ? _formatDuration(message.duration!)
                : 'Voice message',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: message.isOutgoing ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ],
    );
  }

  String _formatTime(DateTime time) {
    return DateFormat.Hm().format(time);
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  IconData _getStatusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.sending:
        return Icons.schedule;
      case MessageStatus.sent:
        return Icons.check;
      case MessageStatus.delivered:
        return Icons.done_all;
      case MessageStatus.read:
        return Icons.done_all;
      case MessageStatus.failed:
        return Icons.error_outline;
    }
  }
}
