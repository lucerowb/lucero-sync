import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import '../core/identity.dart';
import '../core/protocol.dart';

class DiscoveredPeer {
  const DiscoveredPeer({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
    this.lost = false,
  });

  final String deviceId;
  final String name;
  final String host;
  final int port;
  final bool lost;
}

/// mDNS/Bonjour discovery. The receiver advertises `_lucerosync._tcp` with its
/// device id in the TXT record; the sender browses and resolves it. The PIN is
/// never broadcast — it comes from the QR code or is typed in once.
class DiscoveryService {
  DiscoveryService(this._identity);

  final DeviceIdentity _identity;
  BonsoirBroadcast? _broadcast;

  Future<void> startAdvertising({required int port}) async {
    await stopAdvertising();
    final service = BonsoirService(
      name: _identity.name,
      type: Protocol.serviceType,
      port: port,
      attributes: {'id': _identity.deviceId, 'v': '${Protocol.version}'},
    );
    final broadcast = BonsoirBroadcast(service: service);
    await broadcast.ready;
    await broadcast.start();
    _broadcast = broadcast;
  }

  Future<void> stopAdvertising() async {
    await _broadcast?.stop();
    _broadcast = null;
  }

  /// Emits peers as they are resolved (and again with `lost: true` when they
  /// disappear). Cancelling the subscription stops the browse.
  Stream<DiscoveredPeer> browse() {
    BonsoirDiscovery? discovery;
    StreamSubscription<BonsoirDiscoveryEvent>? sub;
    late final StreamController<DiscoveredPeer> controller;

    controller = StreamController<DiscoveredPeer>(
      onListen: () async {
        final d = BonsoirDiscovery(type: Protocol.serviceType);
        discovery = d;
        await d.ready;
        sub = d.eventStream!.listen((event) {
          final service = event.service;
          if (service == null) return;
          final id = service.attributes['id'];
          if (id == null || id == _identity.deviceId) return;

          switch (event.type) {
            case BonsoirDiscoveryEventType.discoveryServiceFound:
              service.resolve(d.serviceResolver);
            case BonsoirDiscoveryEventType.discoveryServiceResolved:
              if (service is ResolvedBonsoirService && service.host != null) {
                controller.add(DiscoveredPeer(
                  deviceId: id,
                  name: service.name,
                  host: service.host!,
                  port: service.port,
                ));
              }
            case BonsoirDiscoveryEventType.discoveryServiceLost:
              controller.add(DiscoveredPeer(
                deviceId: id,
                name: service.name,
                host: '',
                port: 0,
                lost: true,
              ));
            default:
              break;
          }
        });
        await d.start();
      },
      onCancel: () async {
        await sub?.cancel();
        await discovery?.stop();
      },
    );
    return controller.stream;
  }

  /// Used by the sync engine to re-find a receiver whose DHCP address changed.
  Future<DiscoveredPeer?> find(String deviceId, {Duration timeout = const Duration(seconds: 6)}) async {
    try {
      return await browse().firstWhere((p) => p.deviceId == deviceId && !p.lost).timeout(timeout);
    } catch (_) {
      return null;
    }
  }
}
