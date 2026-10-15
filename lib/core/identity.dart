import 'dart:io';
import 'dart:math';

import 'db.dart';

/// Stable per-install identity: device id (dedup ledger key), display name,
/// and the receiver PIN that senders must present.
class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.name, required this.pin});

  final String deviceId;
  final String name;
  final String pin;

  static Future<DeviceIdentity> load(AppDatabase db) async {
    final rng = Random.secure();

    var id = await db.getValue('device_id');
    if (id == null) {
      id = List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await db.setValue('device_id', id);
    }

    var pin = await db.getValue('pin');
    if (pin == null) {
      pin = rng.nextInt(1000000).toString().padLeft(6, '0');
      await db.setValue('pin', pin);
    }

    var name = await db.getValue('name');
    if (name == null) {
      name = '${Platform.isIOS ? 'iPhone' : 'Android'}-${id.substring(0, 4)}';
      await db.setValue('name', name);
    }

    return DeviceIdentity(deviceId: id, name: name, pin: pin);
  }
}

/// Best-guess Wi-Fi IPv4 address for display in the QR code.
Future<String?> localIpv4() async {
  final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  const preferred = ['wlan0', 'en0', 'wlan1', 'swlan0', 'ap0'];
  for (final name in preferred) {
    for (final iface in ifaces) {
      if (iface.name == name && iface.addresses.isNotEmpty) return iface.addresses.first.address;
    }
  }
  for (final iface in ifaces) {
    for (final addr in iface.addresses) {
      final a = addr.address;
      if (a.startsWith('192.168.') || a.startsWith('10.') || a.startsWith('172.')) return a;
    }
  }
  return null;
}
