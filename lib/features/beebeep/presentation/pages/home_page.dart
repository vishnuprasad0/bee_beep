import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../domain/entities/chat_message.dart';
import '../../domain/use_cases/connect_to_peer.dart';
import '../bloc/chat/chat_cubit.dart';
import '../bloc/chat/chat_state.dart';
import '../bloc/logs/logs_cubit.dart';
import '../bloc/peers/peers_cubit.dart';
import '../bloc/peers/peer_presence.dart';
import '../bloc/peers/peers_state.dart';
import 'chat_page.dart';
import 'settings_page.dart';

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
      appBar: AppBar(
        title: const Text('BeeBEEP'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: BlocBuilder<PeersCubit, PeersState>(
        builder: (context, peersState) {
          return BlocBuilder<ChatCubit, ChatState>(
            builder: (context, chatState) {
              final lastMessages = context.read<ChatCubit>().getLastMessages();

              if (peersState.peers.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.people_outline,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No peers found',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        peersState.isDiscovering
                            ? 'Searching for peers...'
                            : 'Tap the button below to discover',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                itemCount: peersState.peers.length,
                itemBuilder: (context, index) {
                  final presence = peersState.peers[index];
                  final peer = presence.peer;
                  final lastMessage = lastMessages[peer.id];

                  return ListTile(
                    leading: Stack(
                      children: [
                        CircleAvatar(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer,
                          child: Text(
                            peer.displayName.isNotEmpty
                                ? peer.displayName[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: presence.isOnline
                                  ? Colors.green
                                  : Colors.grey,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Theme.of(context).colorScheme.surface,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    title: Text(
                      peer.displayName.isEmpty ? 'Unknown' : peer.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: lastMessage != null
                        ? Text(
                            _previewText(lastMessage),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: lastMessage.isOutgoing
                                  ? Colors.grey[600]
                                  : Colors.black87,
                              fontWeight: lastMessage.isOutgoing
                                  ? FontWeight.normal
                                  : FontWeight.w600,
                            ),
                          )
                        : Text(
                            _presenceText(presence),
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _infoButton(context, presence),
                        const SizedBox(width: 4),
                        lastMessage != null
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    _formatTime(lastMessage.timestamp),
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (!lastMessage.isOutgoing) ...[
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const SizedBox(
                                        width: 8,
                                        height: 8,
                                      ),
                                    ),
                                  ],
                                ],
                              )
                            : const Icon(
                                Icons.chevron_right,
                                color: Colors.grey,
                              ),
                      ],
                    ),
                    onTap: () async {
                      // Auto-connect before opening chat
                      await connectToPeer(peer);
                      if (context.mounted) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ChatPage(peer: peer),
                          ),
                        );
                      }
                    },
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: BlocBuilder<PeersCubit, PeersState>(
        builder: (context, state) {
          return FloatingActionButton.extended(
            onPressed: () {
              if (state.isDiscovering) {
                context.read<PeersCubit>().stop();
              } else {
                context.read<PeersCubit>().start();
              }
            },
            icon: Icon(state.isDiscovering ? Icons.stop : Icons.search),
            label: Text(state.isDiscovering ? 'Stop' : 'Discover'),
          );
        },
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);

    if (difference.inDays == 0) {
      return DateFormat.Hm().format(time);
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return DateFormat.E().format(time);
    } else {
      return DateFormat.MMMd().format(time);
    }
  }

  String _previewText(ChatMessage message) {
    switch (message.type) {
      case MessageType.file:
        return '📎 ${message.fileName ?? 'File'}';
      case MessageType.voice:
        return '🎤 Voice message';
      case MessageType.text:
        return message.text;
    }
  }

  String _presenceText(PeerPresence presence) {
    final status = presence.isOnline ? 'Online' : 'Offline';
    if (presence.lastSeen == null || presence.isOnline) {
      return '$status • ${presence.peer.host}:${presence.peer.port}';
    }
    return '$status • last seen ${_formatLastSeen(presence.lastSeen!)}';
  }

  String _formatLastSeen(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat.MMMd().format(time);
  }

  Widget _infoButton(BuildContext context, PeerPresence presence) {
    return IconButton(
      icon: const Icon(Icons.info_outline),
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      tooltip: 'Peer info',
      onPressed: () {
        showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(presence.peer.displayName),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    presence.isOnline ? 'Status: Online' : 'Status: Offline',
                  ),
                  const SizedBox(height: 8),
                  Text('IP: ${presence.peer.host}'),
                  Text('Port: ${presence.peer.port}'),
                  if (presence.lastSeen != null && !presence.isOnline) ...[
                    const SizedBox(height: 8),
                    Text('Last seen: ${_formatLastSeen(presence.lastSeen!)}'),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
