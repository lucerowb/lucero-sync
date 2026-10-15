import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';

import '../security/tls_identity.dart';
import 'db.dart';
import 'platform.dart';

/// Stable per-install identity: random device id, editable display name, and
/// the TLS certificate whose fingerprint other devices pin.
class DeviceIdentity {
  DeviceIdentity({required this.deviceId, required this.name, required this.tls});

  final String deviceId;
  String name;
  final TlsIdentity tls;

  String get fingerprint => tls.fingerprint;
  String get platform => Caps.platformId;

  static Future<DeviceIdentity> load(AppDatabase db, Directory dataDir) async {
    var id = await db.getValue('device_id');
    if (id == null) {
      final rng = Random.secure();
      id = List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await db.setValue('device_id', id);
    }

    var name = await db.getValue('name');
    if (name == null) {
      name = await _defaultName(id);
      await db.setValue('name', name);
    }

    final tls = await TlsIdentity.loadOrCreate(Directory('${dataDir.path}/identity'), deviceId: id);
    return DeviceIdentity(deviceId: id, name: name, tls: tls);
  }
}

/// A recognisable default name; users can rename in Settings.
Future<String> _defaultName(String id) async {
  final suffix = id.substring(0, 4);
  String? name;
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isMacOS) name = (await info.macOsInfo).computerName;
    if (Platform.isWindows) name = (await info.windowsInfo).computerName;
    if (Platform.isLinux) name = Platform.localHostname;
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      final brand = a.brand.isEmpty ? '' : '${a.brand[0].toUpperCase()}${a.brand.substring(1)} ';
      name = '$brand${a.model}';
    }
    // iOS no longer exposes the user-chosen device name; use the model.
    if (Platform.isIOS) name = '${(await info.iosInfo).model}-$suffix';
  } catch (_) {}
  name = name?.trim();
  if (name == null || name.isEmpty || name.toLowerCase() == 'localhost') name = '${Caps.defaultNamePrefix}-$suffix';
  return name.length > 40 ? name.substring(0, 40) : name;
}

/// Private LAN IPv4 addresses, best candidate (Wi-Fi/Ethernet) first.
Future<List<String>> localIpv4s() async {
  final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  const preferred = ['wlan0', 'en0', 'en1', 'eth0', 'wlan1', 'Wi-Fi', 'Ethernet', 'swlan0', 'ap0'];
  bool isPrivate(String a) =>
      a.startsWith('192.168.') ||
      a.startsWith('10.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a);

  final scored = <(int, String)>[];
  for (final iface in ifaces) {
    for (final addr in iface.addresses) {
      if (!isPrivate(addr.address)) continue;
      final rank = preferred.indexWhere((n) => iface.name.toLowerCase().startsWith(n.toLowerCase()));
      scored.add((rank < 0 ? 99 : rank, addr.address));
    }
  }
  scored.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final s in scored) s.$2];
}

Future<String?> localIpv4() async {
  final all = await localIpv4s();
  return all.isEmpty ? null : all.first;
}
