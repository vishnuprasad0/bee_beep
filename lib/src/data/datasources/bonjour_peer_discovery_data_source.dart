import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import '../../domain/entities/peer.dart';
import '../../core/protocol/beebeep_constants.dart';

class BonjourPeerDiscoveryDataSource {
  BonjourPeerDiscoveryDataSource();

  final _peersController = StreamController<List<Peer>>.broadcast();
  final Map<String, Peer> _peersById = <String, Peer>{};
  final Map<String, String> _peerIdByServiceName = <String, String>{};
  Set<String> _localIpv4Hosts = <String>{};

  static final RegExp _beepNameHostPort = RegExp(
    r'^BeeBEEP\s+(?<host>(?:\d{1,3}\.){3}\d{1,3}):(?<port>\d{1,5})$',
  );

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;

  RawDatagramSocket? _udpSocket;
  StreamSubscription<RawSocketEvent>? _udpSub;
  Timer? _udpDiscoveryTimer;

  int _scanGeneration = 0;
  final Set<String> _scannedSubnets = <String>{};

  static const int _beeBeepDefaultTcpPort = 6475;
  static const Duration _scanConnectTimeout = Duration(milliseconds: 250);
  static const int _scanParallelism = 40;
  static const Duration _udpDiscoveryInterval = Duration(seconds: 3);

  void _debugLog(String message) {
    if (!const bool.fromEnvironment('dart.vm.product')) {
      // ignore: avoid_print
      print('[BeeBEEP][discovery] $message');
    }
  }

  Future<Set<String>> _getLocalIpv4Hosts() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      final hosts = <String>{};
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.isEmpty) continue;
          if (ip.startsWith('169.254.')) continue; // link-local
          hosts.add(ip);
        }
      }
      return hosts;
    } catch (_) {
      return <String>{};
    }
  }

  bool _isSelfHost(String host) {
    if (host.isEmpty) return false;
    if (_localIpv4Hosts.contains(host)) return true;
    // Common Android emulator guest address.
    if (host == '10.0.2.16') return true;
    return false;
  }

  Stream<List<Peer>> watchPeers() => _peersController.stream;

  String? _subnet24Prefix(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    final c = int.tryParse(parts[2]);
    final d = int.tryParse(parts[3]);
    if (a == null || b == null || c == null || d == null) return null;
    if (a < 0 || a > 255) return null;
    if (b < 0 || b > 255) return null;
    if (c < 0 || c > 255) return null;
    if (d < 0 || d > 255) return null;
    return '${a}.${b}.${c}.';
  }

  bool _isRfc1918Host(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;

    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    return false;
  }

  Future<void> _maybeStartLanScanForHost(String host) async {
    final prefix = _subnet24Prefix(host);
    if (prefix == null) return;

    // Only scan LAN ranges to avoid wasting time on VPN/CGNAT addresses.
    if (!_isRfc1918Host(host)) return;

    // Avoid scanning the emulator-internal subnet; it won't contain your LAN peers.
    if (prefix == '10.0.2.') return;

    // Only scan each /24 once per discovery session.
    if (!_scannedSubnets.add(prefix)) return;

    _debugLog('Starting LAN scan for $prefix*');

    final generation = ++_scanGeneration;

    final addresses = <String>[];
    for (var last = 1; last <= 254; last++) {
      addresses.add('$prefix$last');
    }

    for (var i = 0; i < addresses.length; i += _scanParallelism) {
      if (generation != _scanGeneration) return;

      final batch = addresses
          .skip(i)
          .take(_scanParallelism)
          .toList(growable: false);
      await Future.wait(batch.map((ip) => _probeBeeBeepTcp(ip, generation)));
    }
  }

  Future<void> _probeBeeBeepTcp(String host, int generation) async {
    if (generation != _scanGeneration) return;
    if (_isSelfHost(host)) return;

    final id = '$host:$_beeBeepDefaultTcpPort';
    if (_peersById.containsKey(id)) return;

    try {
      final socket = await Socket.connect(
        host,
        _beeBeepDefaultTcpPort,
        timeout: _scanConnectTimeout,
      );
      socket.destroy();
    } catch (_) {
      return;
    }

    if (generation != _scanGeneration) return;

    _peersById[id] = Peer(
      id: id,
      displayName: host,
      host: host,
      port: _beeBeepDefaultTcpPort,
    );
    _debugLog('Found BeeBEEP TCP peer at $id');
    _emit();
  }

  Future<void> start() async {
    if (_discovery != null) return;

    _localIpv4Hosts = await _getLocalIpv4Hosts();

    await _startUdpDiscovery();

    // Fallback: start a /24 scan immediately based on our own LAN address.
    // This makes discovery work on devices where mDNS isn't available/reliable.
    if (_localIpv4Hosts.isNotEmpty) {
      for (final ip in _localIpv4Hosts.take(3)) {
        unawaited(_maybeStartLanScanForHost(ip));
      }
    } else {
      _debugLog(
        'No local IPv4 detected; will rely on resolved hosts to start scan',
      );
    }

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
          final int? parsedPort = parsed != null
              ? int.tryParse(parsed.namedGroup('port') ?? '')
              : null;
          final int port = parsedPort ?? resolved.port;

          if (host.isEmpty || port <= 0) return;

          // Some BeeBEEP clients (often Windows) may not publish mDNS. Once we learn a LAN
          // prefix (even from our own resolved service), do a lightweight TCP scan on the
          // default BeeBEEP port to find peers.
          unawaited(_maybeStartLanScanForHost(host));

          if (_isSelfHost(host)) return;

          final displayName = resolved.name;
          final id = '$host:$port';

          final previousId = _peerIdByServiceName[resolved.name];
          if (previousId != null && previousId != id) {
            _peersById.remove(previousId);
          }

          _peerIdByServiceName[resolved.name] = id;
          _peersById[id] = Peer(
            id: id,
            displayName: displayName,
            host: host,
            port: port,
          );
          _emit();
          break;
        case BonsoirDiscoveryEventType.discoveryServiceLost:
          final id = _peerIdByServiceName.remove(service.name);
          if (id != null) {
            _peersById.remove(id);
          }
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

    await _stopUdpDiscovery();

    _scanGeneration++;
    _scannedSubnets.clear();
    _debugLog('Stopped discovery; cleared LAN scan state');

    _peersById.clear();
    _peerIdByServiceName.clear();
    _localIpv4Hosts = <String>{};
    _emit();
  }

  void _emit() {
    final peers = _peersById.values.toList(growable: false)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    _peersController.add(peers);
  }

  Future<void> dispose() async {
    await stop();
    await _peersController.close();
  }

  Future<void> _startUdpDiscovery() async {
    await _stopUdpDiscovery();

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        beeBeepUdpDiscoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      socket.broadcastEnabled = true;

      _udpSocket = socket;
      _udpSub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        _handleUdpDatagram(datagram);
      });

      _udpDiscoveryTimer = Timer.periodic(
        _udpDiscoveryInterval,
        (_) => _broadcastUdpDiscovery(),
      );

      _broadcastUdpDiscovery();
    } catch (e) {
      _debugLog('UDP discovery start failed: $e');
    }
  }

  Future<void> _stopUdpDiscovery() async {
    await _udpSub?.cancel();
    _udpSub = null;
    _udpDiscoveryTimer?.cancel();
    _udpDiscoveryTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
  }

  void _broadcastUdpDiscovery() {
    final socket = _udpSocket;
    if (socket == null) return;

    final payload = beeBeepUdpDiscoveryMessage;
    final data = utf8.encode(payload);

    socket.send(
      data,
      InternetAddress('255.255.255.255'),
      beeBeepUdpDiscoveryPort,
    );

    for (final host in _localIpv4Hosts) {
      final prefix = _subnet24Prefix(host);
      if (prefix == null) continue;
      socket.send(
        data,
        InternetAddress('${prefix}255'),
        beeBeepUdpDiscoveryPort,
      );
    }
  }

  void _handleUdpDatagram(Datagram datagram) {
    final message = utf8.decode(datagram.data, allowMalformed: true).trim();
    if (!message.startsWith(beeBeepUdpResponseMessage)) return;

    final parts = message.split('|');
    if (parts.length < 3) return;

    final displayName = parts[1].trim();
    final port = int.tryParse(parts[2].trim()) ?? 0;
    if (port <= 0) return;

    final host = datagram.address.address;
    if (_isSelfHost(host)) return;

    final id = '$host:$port';
    _peersById[id] = Peer(
      id: id,
      displayName: displayName.isEmpty ? host : displayName,
      host: host,
      port: port,
    );
    _emit();
  }
}
