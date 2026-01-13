import 'package:equatable/equatable.dart';

class LogsState extends Equatable {
  const LogsState({required this.lines});

  const LogsState.initial() : lines = const <String>[];

  final List<String> lines;

  LogsState append(String line, {int maxLines = 400}) {
    final next = <String>[...lines, line];
    if (next.length > maxLines) {
      next.removeRange(0, next.length - maxLines);
    }
    return LogsState(lines: next);
  }

  @override
  List<Object?> get props => [lines];
}
