import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/peer.dart';
import '../../domain/use_cases/connect_to_peer.dart';
import '../bloc/logs/logs_cubit.dart';
import '../bloc/logs/logs_state.dart';
import '../bloc/peers/peers_cubit.dart';
import '../bloc/peers/peers_state.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();

    context.read<PeersCubit>().start();
    context.read<LogsCubit>().start();
  }

  @override
  Widget build(BuildContext context) {
    final connectToPeer = context.read<ConnectToPeer>();

    return Scaffold(
      appBar: AppBar(title: const Text('BeeBEEP')),
      body: Column(
        children: [
          BlocBuilder<PeersCubit, PeersState>(
            builder: (context, state) {
              return _PeersSection(
                isDiscovering: state.isDiscovering,
                peers: state.peers,
                errorMessage: state.errorMessage,
                onToggleDiscovery: () {
                  if (state.isDiscovering) {
                    context.read<PeersCubit>().stop();
                  } else {
                    context.read<PeersCubit>().start();
                  }
                },
                onConnect: (peer) => connectToPeer(peer),
              );
            },
          ),
          const Divider(height: 1),
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
                        vertical: 6,
                      ),
                      child: Text(
                        line,
                        style: Theme.of(context).textTheme.bodySmall,
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

class _PeersSection extends StatelessWidget {
  const _PeersSection({
    required this.isDiscovering,
    required this.peers,
    required this.errorMessage,
    required this.onToggleDiscovery,
    required this.onConnect,
  });

  final bool isDiscovering;
  final List<Peer> peers;
  final String? errorMessage;
  final VoidCallback onToggleDiscovery;
  final void Function(Peer peer) onConnect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 220,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text('Peers', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: onToggleDiscovery,
                  child: Text(isDiscovering ? 'Stop' : 'Discover'),
                ),
              ],
            ),
          ),
          if (errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          Expanded(
            child: peers.isEmpty
                ? const Center(child: Text('No peers found'))
                : ListView.builder(
                    itemCount: peers.length,
                    itemBuilder: (context, index) {
                      final peer = peers[index];
                      return ListTile(
                        dense: true,
                        title: Text(peer.displayName),
                        subtitle: Text('${peer.host}:${peer.port}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => onConnect(peer),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
