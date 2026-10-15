// Manual demo helper (not part of the test suite): a scripted "Studio Mac" peer
// that pairs with a running app and offers it a few files, so the receive flow
// can be exercised and screenshotted on a simulator.
//
//   LUCERO_TARGET_PORT=8765 flutter test tool/demo_peer_test.dart
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lucero_sync/core/db.dart';
import 'package:lucero_sync/core/identity.dart';
import 'package:lucero_sync/core/models.dart';
import 'package:lucero_sync/net/peer_client.dart';
import 'package:lucero_sync/net/server.dart';
import 'package:lucero_sync/security/tls_identity.dart';
import 'package:lucero_sync/share/share_sender.dart';
import 'package:lucero_sync/storage/storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Quiet implements ServerDelegate {
  @override
  Future<bool> approvePairing(PairingPrompt prompt) async => false;
  @override
  Future<bool> approveShare(ShareOfferPrompt prompt) async => false;
  @override
  bool consumeQrSecret(String secret) => false;
  @override
  void backupStored(PeerDevice from, String relPath) {}
  @override
  void incomingFinished(TransferRecord record) {}
  @override
  void incomingProgress(String offerId, int receivedBytes, int totalBytes) {}
  @override
  void log(String line) {}
  @override
  void pairingCancelled(String sessionId) {}
  @override
  void peersChanged() {}
  @override
  void textReceived(PeerDevice from, String text) {}
}

void main() {
  test('demo peer', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final port = int.parse(Platform.environment['LUCERO_TARGET_PORT'] ?? '8765');
    final dir = await Directory.systemTemp.createTemp('lucero_demo');
    const id = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    final identity = DeviceIdentity(deviceId: id, name: 'Studio Mac', tls: await TlsIdentity.loadOrCreate(dir, deviceId: id));
    final db = await AppDatabase.open(path: '${dir.path}/db.sqlite');
    final storage = Storage(backupsRoot: Directory('${dir.path}/b'), receivedRoot: Directory('${dir.path}/r'));
    await storage.ensureDirs();
    final server = LuceroServer(db: db, identity: identity, storage: storage, delegate: _Quiet());
    await server.start(port: 0);
    final client = PeerClient(identity, serverPort: () => server.port!);

    final pairing = await client.startPairing('127.0.0.1', port);
    stdout.writeln('CODE ${pairing.code}');
    await pairing.waitForApproval();
    final peer = (await pairing.confirm()).copyWith(host: '127.0.0.1');
    await db.upsertPeer(peer);
    stdout.writeln('PAIRED ${peer.name}');

    final rng = Random(7);
    Future<String> make(String name, int kb) async {
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(List.generate(kb * 1024, (_) => rng.nextInt(256)));
      return f.path;
    }

    final files = [
      await make('Trip itinerary.pdf', 1200),
      await make('Sunset timelapse.mov', 48000),
      await make('Budget 2026.xlsx', 310),
    ];
    final share = ShareSender(db, client).sendFiles(peer, files);
    while (share.isActive) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    stdout.writeln('SHARE ${share.state} ${share.error ?? ''}');
    await server.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
