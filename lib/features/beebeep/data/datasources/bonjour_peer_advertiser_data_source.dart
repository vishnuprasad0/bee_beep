import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import 'package:beebeep/core/protocol/beebeep_constants.dart';

class BonjourPeerAdvertiserDataSource {
  BonjourPeerAdvertiserDataSource();

  BonsoirBroadcast? _broadcast;
  RawDatagramSocket? _udpSocket;
  StreamSubscription<RawSocketEvent>? _udpSub;
  Timer? _udpAnnounceTimer;

  Set<String> _localIpv4Hosts = <String>{};

  String _displayName = '';
  int _tcpPort = 0;

  Future<void> start({required String name, required int port}) async {
    await stop();

    _displayName = name;
    _tcpPort = port;

    _localIpv4Hosts = await _getLocalIpv4Hosts();

    final service = BonsoirService(
      name: name,
      type: beeBeepServiceType,
      port: port,
    );

    final broadcast = BonsoirBroadcast(service: service);
    _broadcast = broadcast;

    await broadcast.ready;
    await broadcast.start();

    await _startUdpResponder();
  }

  Future<void> stop() async {
    final b = _broadcast;
    if (b != null) {
      await b.stop();
      _broadcast = null;
    }

    await _stopUdpResponder();
  }

  Future<void> _startUdpResponder() async {
    await _stopUdpResponder();

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
      final message = utf8.decode(datagram.data, allowMalformed: true).trim();

      if (message.startsWith(beeBeepUdpDiscoveryMessage)) {
        _sendUdpResponse(datagram.address, datagram.port);
      }
    });

    _udpAnnounceTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _broadcastUdpResponse(),
    );

    _broadcastUdpResponse();
  }

  Future<void> _stopUdpResponder() async {
    await _udpSub?.cancel();
    _udpSub = null;
    _udpAnnounceTimer?.cancel();
    _udpAnnounceTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
  }

  void _sendUdpResponse(InternetAddress address, int port) {
    final socket = _udpSocket;
    if (socket == null || _tcpPort <= 0) return;

    final payload = '${beeBeepUdpResponseMessage}|$_displayName|$_tcpPort';
    final data = utf8.encode(payload);
    socket.send(data, address, port);
  }

  void _broadcastUdpResponse() {
    final socket = _udpSocket;
    if (socket == null || _tcpPort <= 0) return;

    final payload = '${beeBeepUdpResponseMessage}|$_displayName|$_tcpPort';
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
          if (ip.startsWith('169.254.')) continue;
          hosts.add(ip);
        }
      }
      return hosts;
    } catch (_) {
      return <String>{};
    }
  }

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
}
