import 'package:hive/hive.dart';

import '../../domain/entities/cached_peer.dart';

/// Stores cached peer data by peerId.
class PeerCacheHiveDataSource {
  PeerCacheHiveDataSource(this._box);

  static const String boxName = 'peer_cache';

  final Box<dynamic> _box;

  Map<String, CachedPeer> loadAll() {
    final entries = <String, CachedPeer>{};
    for (final entry in _box.toMap().entries) {
      final key = entry.key?.toString() ?? '';
      if (key.isEmpty) continue;
      final cached = _decode(entry.value, key);
      if (cached != null) {
        entries[key] = cached;
      }
    }
    return entries;
  }

  Future<void> savePeer(CachedPeer peer) {
    return _box.put(peer.peerId, _encode(peer));
  }

  Future<void> savePeers(Iterable<CachedPeer> peers) {
    final map = <String, Map<String, dynamic>>{};
    for (final peer in peers) {
      map[peer.peerId] = _encode(peer);
    }
    if (map.isEmpty) return Future.value();
    return _box.putAll(map);
  }

  Future<void> saveDisplayName({
    required String peerId,
    required String displayName,
  }) async {
    final existing = _decode(_box.get(peerId), peerId);
    final now = DateTime.now();

    final updated = (existing ?? _fallback(peerId))?.copyWith(
      displayName: displayName,
      lastSeen: now,
    );
    if (updated != null) {
      await savePeer(updated);
    }
  }

  CachedPeer? _decode(dynamic value, String peerId) {
    if (value == null) return _fallback(peerId);

    if (value is String) {
      return _fallback(peerId)?.copyWith(displayName: value);
    }

    if (value is Map) {
      final displayName = value['displayName']?.toString() ?? '';
      final host = value['host']?.toString() ?? '';
      final portValue = value['port'];
      final port = portValue is int
          ? portValue
          : int.tryParse(portValue?.toString() ?? '') ?? 0;
      final lastSeenValue = value['lastSeen'];
      final lastSeenMs = lastSeenValue is int
          ? lastSeenValue
          : int.tryParse(lastSeenValue?.toString() ?? '') ?? 0;

      final fallback = _fallback(peerId);
      return CachedPeer(
        peerId: peerId,
        displayName: displayName.isNotEmpty
            ? displayName
            : (fallback?.displayName ?? ''),
        host: host.isNotEmpty ? host : (fallback?.host ?? ''),
        port: port != 0 ? port : (fallback?.port ?? 0),
        lastSeen: lastSeenMs != 0
            ? DateTime.fromMillisecondsSinceEpoch(lastSeenMs)
            : (fallback?.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0)),
      );
    }

    return _fallback(peerId);
  }

  Map<String, dynamic> _encode(CachedPeer peer) {
    return {
      'displayName': peer.displayName,
      'host': peer.host,
      'port': peer.port,
      'lastSeen': peer.lastSeen.millisecondsSinceEpoch,
    };
  }

  CachedPeer? _fallback(String peerId) {
    final parts = peerId.split(':');
    if (parts.length != 2) return null;
    final host = parts[0];
    final port = int.tryParse(parts[1]) ?? 0;
    return CachedPeer(
      peerId: peerId,
      displayName: host,
      host: host,
      port: port,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
