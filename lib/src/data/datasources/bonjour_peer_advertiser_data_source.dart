import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import '../../core/protocol/beebeep_constants.dart';

class BonjourPeerAdvertiserDataSource {
  BonjourPeerAdvertiserDataSource();

  BonsoirBroadcast? _broadcast;

  Future<void> start({required String name, required int port}) async {
    await stop();

    final service = BonsoirService(
      name: name,
      type: beeBeepServiceType,
      port: port,
    );

    final broadcast = BonsoirBroadcast(service: service);
    _broadcast = broadcast;

    await broadcast.ready;
    await broadcast.start();
  }

  Future<void> stop() async {
    final b = _broadcast;
    if (b == null) return;

    await b.stop();
    _broadcast = null;
  }
}
