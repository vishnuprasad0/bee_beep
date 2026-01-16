import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../audio_encoder_type.dart';

class VoiceMessageRecorder extends StatefulWidget {
  const VoiceMessageRecorder({
    super.key,
    required this.functionStartRecording,
    required this.functionStopRecording,
    required this.functionSendVoice,
    required this.functionRecorderStatus,
    required this.functionSendTextMessage,
    required this.functionDataCameraReceived,
    required this.encode,
  });

  final VoidCallback functionStartRecording;
  final void Function(String time) functionStopRecording;
  final Future<void> Function(File soundFile, String time) functionSendVoice;
  final void Function(bool isRecording) functionRecorderStatus;
  final void Function(String text) functionSendTextMessage;
  final void Function(String value) functionDataCameraReceived;
  final AudioEncoderType encode;

  @override
  State<VoiceMessageRecorder> createState() => _VoiceMessageRecorderState();
}

class _VoiceMessageRecorderState extends State<VoiceMessageRecorder> {
  final _recorder = AudioRecorder();
  final _textController = TextEditingController();
  bool _isRecording = false;
  DateTime? _startTime;
  File? _recordedFile;

  @override
  void dispose() {
    _recorder.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return;

    final dir = await getTemporaryDirectory();
    final fileName =
        'voice_${DateTime.now().millisecondsSinceEpoch}.${_fileExtension()}';
    final path = '${dir.path}/$fileName';

    await _recorder.start(_config(), path: path);

    setState(() {
      _isRecording = true;
      _startTime = DateTime.now();
      _recordedFile = File(path);
    });

    widget.functionStartRecording();
    widget.functionRecorderStatus(true);
  }

  Future<void> _stop() async {
    await _recorder.stop();
    final duration = _elapsedLabel();

    setState(() {
      _isRecording = false;
    });

    widget.functionStopRecording(duration);
    widget.functionRecorderStatus(false);
  }

  Future<void> _sendVoice() async {
    final file = _recordedFile;
    if (file == null || !file.existsSync()) return;

    final duration = _elapsedLabel();
    await widget.functionSendVoice(file, duration);
  }

  String _elapsedLabel() {
    final started = _startTime;
    if (started == null) return '0:00';
    final elapsed = DateTime.now().difference(started);
    final minutes = elapsed.inMinutes;
    final seconds = elapsed.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  RecordConfig _config() {
    final encoder = widget.encode == AudioEncoderType.WAV
        ? AudioEncoder.wav
        : AudioEncoder.aacLc;
    return RecordConfig(encoder: encoder);
  }

  String _fileExtension() {
    return widget.encode == AudioEncoderType.WAV ? 'wav' : 'aac';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                onPressed: _isRecording ? _stop : _start,
              ),
              Expanded(
                child: Text(
                  _isRecording
                      ? 'Recording... ${_elapsedLabel()}'
                      : 'Tap to record',
                ),
              ),
              if (!_isRecording)
                IconButton(icon: const Icon(Icons.send), onPressed: _sendVoice),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  decoration: const InputDecoration(
                    hintText: 'Type a message',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () {
                  final text = _textController.text.trim();
                  if (text.isEmpty) return;
                  widget.functionSendTextMessage(text);
                  _textController.clear();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
