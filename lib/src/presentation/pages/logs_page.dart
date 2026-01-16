import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/logs/logs_cubit.dart';
import '../bloc/logs/logs_state.dart';

/// Displays connection and transfer logs.
class LogsPage extends StatelessWidget {
  const LogsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connection Logs')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              'Includes discovery, connections, encryption, and transfers.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: BlocBuilder<LogsCubit, LogsState>(
              builder: (context, state) {
                if (state.lines.isEmpty) {
                  return const Center(child: Text('No logs yet'));
                }
                return ListView.builder(
                  reverse: true,
                  itemCount: state.lines.length,
                  itemBuilder: (context, index) {
                    final line = state.lines[state.lines.length - 1 - index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Text(
                        line,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
