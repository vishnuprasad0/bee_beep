import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/use_cases/watch_logs.dart';
import 'logs_state.dart';

class LogsCubit extends Cubit<LogsState> {
  LogsCubit({required WatchLogs watchLogs})
    : _watchLogs = watchLogs,
      super(const LogsState.initial());

  final WatchLogs _watchLogs;
  StreamSubscription<String>? _sub;

  void start() {
    _sub ??= _watchLogs().listen((line) => emit(state.append(line)));
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    return super.close();
  }
}
