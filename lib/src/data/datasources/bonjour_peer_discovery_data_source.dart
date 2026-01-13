import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import '../../domain/entities/peer.dart';
import '../../core/protocol/beebeep_constants.dart';

class BonjourPeerDiscoveryDataSource {
  BonjourPeerDiscoveryDataSource();

  final _peersController = StreamController<List<Peer>>.broadcast();
  final Map<String, Peer> _peersByService = <String, Peer>{};

  static final RegExp _beepNameHostPort = RegExp(
    r'^BeeBEEP\s+(?<host>(?:\d{1,3}\.){3}\d{1,3}):(?<port>\d{1,5})$',
  );

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;

  Stream<List<Peer>> watchPeers() => _peersController.stream;

  Future<void> start() async {
    if (_discovery != null) return;

    final discovery = BonsoirDiscovery(type: beeBeepServiceType);
    _discovery = discovery;

    await discovery.ready;

    _sub = discovery.eventStream?.listen((event) async {
      final service = event.service;
      if (service == null) return;

      switch (event.type) {
        case BonsoirDiscoveryEventType.discoveryServiceFound:
          service.resolve(discovery.serviceResolver);
          break;
        case BonsoirDiscoveryEventType.discoveryServiceResolved:
          final resolved = service as ResolvedBonsoirService;
          final parsed = _beepNameHostPort.firstMatch(resolved.name);

          final host = parsed?.namedGroup('host') ?? (resolved.host ?? '');
          final port = parsed != null
              ? int.tryParse(parsed.namedGroup('port') ?? '')
              : resolved.port;

          if (host.isEmpty || port == null || port <= 0) return;

          final displayName = resolved.name;
          final id = '$host:$port';
          _peersByService[id] = Peer(
            id: id,
            displayName: displayName,
            host: host,
            port: port,
          );
          _emit();
          break;
        case BonsoirDiscoveryEventType.discoveryServiceLost:
          // Best-effort remove by name-based key and also by host:port if we have it.
          _peersByService.remove(service.name);
          _emit();
          break;
        case BonsoirDiscoveryEventType.discoveryServiceResolveFailed:
          break;
        case BonsoirDiscoveryEventType.discoveryStarted:
        case BonsoirDiscoveryEventType.discoveryStopped:
        case BonsoirDiscoveryEventType.unknown:
          break;
      }
    });

    await discovery.start();
  }

  Future<void> stop() async {
    final discovery = _discovery;
    if (discovery == null) return;

    await _sub?.cancel();
    _sub = null;

    await discovery.stop();
    _discovery = null;

    _peersByService.clear();
    _emit();
  }

  void _emit() {
    _peersController.add(_peersByService.values.toList(growable: false));
  }

  Future<void> dispose() async {
    await stop();
    await _peersController.close();
  }
}
