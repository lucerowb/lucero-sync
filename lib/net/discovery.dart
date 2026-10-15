import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import '../core/identity.dart';
import '../core/models.dart';
import '../core/protocol.dart';

/// mDNS / Bonjour discovery.
///
/// Each device advertises `_lucerosync._tcp` with its device id, platform and
/// certificate fingerprint in the TXT record. Discovery data is unauthenticated
/// (anyone on the network can advertise anything), so it is only a *hint*:
/// trust comes from pinned TLS after pairing, and from the comparison code
/// during pairing.
class Discovery {
  Discovery(this._identity);

  final DeviceIdentity _identity;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;

  final _devices = StreamController<({NearbyDevice device, bool lost})>.broadcast();

  Stream<({NearbyDevice device, bool lost})> get events => _devices.stream;

  Future<void> advertise({required int port}) async {
    await stopAdvertising();
    final broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: _identity.name,
        type: Protocol.serviceType,
        port: port,
        attributes: {
          'id': _identity.deviceId,
          'v': '${Protocol.version}',
          'os': _identity.platform,
          'fp': _identity.fingerprint,
        },
      ),
    );
    await broadcast.initialize();
    await broadcast.start();
    _broadcast = broadcast;
  }

  Future<void> stopAdvertising() async {
    await _broadcast?.stop();
    _broadcast = null;
  }

  Future<void> startBrowsing() async {
    if (_discovery != null) return;
    final d = BonsoirDiscovery(type: Protocol.serviceType);
    _discovery = d;
    await d.initialize();
    _sub = d.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          if (_isOther(service)) d.serviceResolver.resolveService(service);
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          final device = _toDevice(service);
          if (device != null) _devices.add((device: device, lost: false));
        case BonsoirDiscoveryServiceLostEvent(:final service):
          final id = service.attributes['id'];
          if (id != null && id != _identity.deviceId) {
            _devices.add((
              device: NearbyDevice(deviceId: id, name: service.name, platform: '', fingerprint: '', host: '', port: 0),
              lost: true,
            ));
          }
        default:
          break;
      }
    });
    await d.start();
  }

  Future<void> stopBrowsing() async {
    await _sub?.cancel();
    _sub = null;
    await _discovery?.stop();
    _discovery = null;
  }

  /// Restart after the network changed (new Wi-Fi), so stale results clear.
  Future<void> restartBrowsing() async {
    await stopBrowsing();
    await startBrowsing();
  }

  bool _isOther(BonsoirService s) {
    final id = s.attributes['id'];
    return id != null && id != _identity.deviceId && s.attributes['v'] == '${Protocol.version}';
  }

  NearbyDevice? _toDevice(BonsoirService s) {
    if (!_isOther(s)) return null;
    // Prefer a plain IPv4 address; fall back to the .local hostname.
    final v4 = s.hostAddresses.where((a) => InternetAddress.tryParse(a)?.type == InternetAddressType.IPv4);
    final host = v4.isNotEmpty ? v4.first : (s.hostname ?? (s.hostAddresses.isNotEmpty ? s.hostAddresses.first : null));
    if (host == null) return null;
    return NearbyDevice(
      deviceId: s.attributes['id']!,
      name: s.name,
      platform: s.attributes['os'] ?? 'unknown',
      fingerprint: (s.attributes['fp'] ?? '').toLowerCase(),
      host: host.endsWith('.') ? host.substring(0, host.length - 1) : host,
      port: s.port,
    );
  }

  Future<void> dispose() async {
    await stopAdvertising();
    await stopBrowsing();
    await _devices.close();
  }

  /// Convenience for resolving a single device (e.g. after an IP change).
  Future<NearbyDevice?> find(String deviceId, {Duration timeout = const Duration(seconds: 6)}) async {
    try {
      return await events.where((e) => !e.lost && e.device.deviceId == deviceId).map((e) => e.device).first.timeout(timeout);
    } catch (_) {
      return null;
    }
  }
}

/// Fallback when mDNS is blocked: the best local address to show in the UI.
Future<String> displayAddress(int port) async => '${await localIpv4() ?? '—'}:$port';
