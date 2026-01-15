import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/logs/logs_cubit.dart';
import '../bloc/logs/logs_state.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings & Logs')),
      body: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('BeeBEEP Dart Client'),
            subtitle: Text('Version 1.0.0'),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                const Icon(Icons.description),
                const SizedBox(width: 8),
                Text(
                  'Connection Logs',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
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
