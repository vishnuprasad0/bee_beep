// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:beebeep/src/data/datasources/received_message.dart';
import 'package:beebeep/src/domain/entities/peer.dart';
import 'package:beebeep/src/domain/entities/peer_identity.dart';
import 'package:beebeep/src/domain/repositories/connection_repository.dart';
import 'package:beebeep/src/domain/repositories/peer_discovery_repository.dart';
import 'package:beebeep/src/domain/use_cases/connect_to_peer.dart';
import 'package:beebeep/src/domain/use_cases/send_chat_to_peer.dart';
import 'package:beebeep/src/domain/use_cases/start_discovery.dart';
import 'package:beebeep/src/domain/use_cases/stop_discovery.dart';
import 'package:beebeep/src/domain/use_cases/watch_logs.dart';
import 'package:beebeep/src/domain/use_cases/watch_peers.dart';
import 'package:beebeep/src/domain/use_cases/watch_peer_identities.dart';
import 'package:beebeep/src/presentation/bloc/logs/logs_cubit.dart';
import 'package:beebeep/src/presentation/bloc/peers/peers_cubit.dart';
import 'package:beebeep/src/presentation/pages/home_page.dart';

class _FakePeerDiscoveryRepository implements PeerDiscoveryRepository {
  final _controller = StreamController<List<Peer>>.broadcast();

  @override
  Stream<List<Peer>> watchPeers() => _controller.stream;

  @override
  Future<void> start() async {
    _controller.add(const <Peer>[]);
  }

  @override
  Future<void> stop() async {}
}

class _FakeConnectionRepository implements ConnectionRepository {
  final _controller = StreamController<String>.broadcast();
  final _identities = StreamController<PeerIdentity>.broadcast();

  @override
  Stream<String> watchLogs() => _controller.stream;

  @override
  Stream<PeerIdentity> watchPeerIdentities() => _identities.stream;

  @override
  Stream<ReceivedMessage> watchReceivedMessages() => const Stream.empty();

  @override
  Future<void> startServer({required int port}) async {}

  @override
  Future<void> stopServer() async {}

  @override
  Future<void> connect(Peer peer) async {
    _controller.add('connect ${peer.displayName}');
  }

  @override
  Future<void> sendChat({required Peer peer, required String text}) async {
    _controller.add('chat ${peer.displayName}: $text');
  }

  @override
  Future<void> sendFile({
    required Peer peer,
    required String fileName,
    required Uint8List bytes,
    required int fileSize,
    String? mimeType,
  }) async {
    _controller.add('file ${peer.displayName}: $fileName');
  }

  @override
  Future<void> sendVoiceMessage({
    required Peer peer,
    required String fileName,
    required Uint8List bytes,
    required int fileSize,
    String? mimeType,
  }) async {
    _controller.add('voice ${peer.displayName}: $fileName');
  }

  @override
  Future<void> disconnectAll() async {}
}

void main() {
  testWidgets('HomePage renders', (WidgetTester tester) async {
    final peerRepo = _FakePeerDiscoveryRepository();
    final connRepo = _FakeConnectionRepository();

    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider.value(value: ConnectToPeer(connRepo)),
          RepositoryProvider.value(value: SendChatToPeer(connRepo)),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider(
              create: (_) => PeersCubit(
                startDiscovery: StartDiscovery(peerRepo),
                stopDiscovery: StopDiscovery(peerRepo),
                watchPeers: WatchPeers(peerRepo),
                watchPeerIdentities: WatchPeerIdentities(connRepo),
              ),
            ),
            BlocProvider(
              create: (_) => LogsCubit(watchLogs: WatchLogs(connRepo)),
            ),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('Peers'), findsOneWidget);
  });
}
