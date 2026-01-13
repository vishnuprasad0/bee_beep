import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/peer.dart';
import '../../../domain/use_cases/watch_peer_identities.dart';
import '../../../domain/use_cases/start_discovery.dart';
import '../../../domain/use_cases/stop_discovery.dart';
import '../../../domain/use_cases/watch_peers.dart';
import 'peers_state.dart';

class PeersCubit extends Cubit<PeersState> {
  PeersCubit({
    required StartDiscovery startDiscovery,
    required StopDiscovery stopDiscovery,
    required WatchPeers watchPeers,
    required WatchPeerIdentities watchPeerIdentities,
  }) : _startDiscovery = startDiscovery,
       _stopDiscovery = stopDiscovery,
       _watchPeers = watchPeers,
       _watchPeerIdentities = watchPeerIdentities,
       super(const PeersState.initial());

  final StartDiscovery _startDiscovery;
  final StopDiscovery _stopDiscovery;
  final WatchPeers _watchPeers;
  final WatchPeerIdentities _watchPeerIdentities;

  final Map<String, String> _displayNameByPeerId = <String, String>{};

  StreamSubscription? _peersSub;
  StreamSubscription? _identitiesSub;

  Future<void> start() async {
    if (state.isDiscovering) return;

    emit(state.copyWith(isDiscovering: true, errorMessage: null));

    _peersSub ??= _watchPeers().listen(
      (peers) => emit(state.copyWith(peers: _applyDisplayNames(peers))),
      onError: (e) => emit(state.copyWith(errorMessage: e.toString())),
    );

    _identitiesSub ??= _watchPeerIdentities().listen(
      (identity) {
        final trimmed = identity.displayName.trim();
        if (trimmed.isEmpty) return;

        _displayNameByPeerId[identity.peerId] = trimmed;
        emit(state.copyWith(peers: _applyDisplayNames(state.peers)));
      },
      onError: (e) => emit(state.copyWith(errorMessage: e.toString())),
    );

    try {
      await _startDiscovery();
    } catch (e) {
      emit(state.copyWith(isDiscovering: false, errorMessage: e.toString()));
    }
  }

  Future<void> stop() async {
    if (!state.isDiscovering) return;

    emit(state.copyWith(isDiscovering: false, errorMessage: null));
    try {
      await _stopDiscovery();
    } catch (e) {
      emit(state.copyWith(errorMessage: e.toString()));
    }
  }

  @override
  Future<void> close() async {
    await _peersSub?.cancel();
    await _identitiesSub?.cancel();
    return super.close();
  }

  List<Peer> _applyDisplayNames(List<Peer> peers) {
    if (_displayNameByPeerId.isEmpty) return peers;

    return peers
        .map((p) {
          final override = _displayNameByPeerId[p.id];
          if (override == null || override == p.displayName) return p;
          return Peer(
            id: p.id,
            displayName: override,
            host: p.host,
            port: p.port,
          );
        })
        .toList(growable: false);
  }
}
