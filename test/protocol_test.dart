// End-to-end tests of protocol v2 over real HTTPS on localhost: two "devices"
// (receiver A, sender B), each with its own certificate, database and folders.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lucero_sync/core/db.dart';
import 'package:lucero_sync/core/hashing.dart';
import 'package:lucero_sync/core/identity.dart';
import 'package:lucero_sync/core/models.dart';
import 'package:lucero_sync/core/protocol.dart';
import 'package:lucero_sync/net/peer_client.dart';
import 'package:lucero_sync/net/server.dart';
import 'package:lucero_sync/security/pairing_crypto.dart';
import 'package:lucero_sync/security/tls_identity.dart';
import 'package:lucero_sync/share/share_sender.dart';
import 'package:lucero_sync/storage/storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeDelegate implements ServerDelegate {
  bool approve = true;
  bool acceptShares = true;
  String? qrSecret;
  final codes = <String>[];
  final texts = <String>[];
  final records = <TransferRecord>[];
  final runStatuses = <BackupRunStatus>[];
  final fileProgress = <(String, int, int)>[];
  final started = <String>[];

  @override
  Future<bool> approvePairing(PairingPrompt prompt) async {
    codes.add(prompt.code);
    return approve;
  }

  @override
  bool consumeQrSecret(String secret) {
    final ok = qrSecret != null && secret == qrSecret;
    if (ok) qrSecret = null; // one-time
    return ok;
  }

  @override
  Future<bool> approveShare(ShareOfferPrompt prompt) async => acceptShares;
  @override
  void textReceived(PeerDevice from, String text) => texts.add(text);
  @override
  void incomingFinished(TransferRecord record) => records.add(record);
  @override
  void pairingCancelled(String sessionId) {}
  @override
  void peersChanged() {}
  @override
  void incomingProgress(String offerId, int receivedBytes, int totalBytes) {}
  @override
  void incomingStarted(String offerId, PeerDevice from, int totalBytes, String title) => started.add(offerId);
  @override
  void backupStatus(PeerDevice from, BackupRunStatus status) => runStatuses.add(status);
  @override
  void backupFileProgress(PeerDevice from, String filename, int received, int size) =>
      fileProgress.add((filename, received, size));
  @override
  void backupStored(PeerDevice from, String relPath) {}
  @override
  void log(String line) {}
}

class Node {
  Node(this.identity, this.db, this.storage, this.delegate, this.server, this.client);

  final DeviceIdentity identity;
  final AppDatabase db;
  final Storage storage;
  final FakeDelegate delegate;
  final LuceroServer server;
  final PeerClient client;

  static Future<Node> create(Directory root, String name) async {
    final dir = Directory('${root.path}/$name')..createSync(recursive: true);
    final id = List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final identity =
        DeviceIdentity(deviceId: id, name: name, tls: await TlsIdentity.loadOrCreate(dir, deviceId: id));
    final db = await AppDatabase.open(path: '${dir.path}/db.sqlite');
    final storage = Storage(
      backupsRoot: Directory('${dir.path}/backups'),
      receivedRoot: Directory('${dir.path}/received'),
    );
    await storage.ensureDirs();
    final delegate = FakeDelegate();
    final server = LuceroServer(db: db, identity: identity, storage: storage, delegate: delegate);
    await server.start(port: 0);
    late Node node;
    final client = PeerClient(identity, serverPort: () => node.server.port!);
    node = Node(identity, db, storage, delegate, server, client);
    return node;
  }

  Future<void> dispose() async {
    await server.stop();
    await db.close();
  }
}

Future<File> randomFile(Directory dir, String name, int size) async {
  final rng = Random(size);
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(List.generate(size, (_) => rng.nextInt(256)));
  return f;
}

void main() {
  late Directory root;
  late Node a; // receiver
  late Node b; // sender

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lucero_proto');
    a = await Node.create(root, 'A');
    b = await Node.create(root, 'B');
  });

  tearDown(() async {
    await a.dispose();
    await b.dispose();
    await root.delete(recursive: true);
  });

  /// Pairs B → A by comparison code; both users approve.
  Future<(PeerDevice bSeesA, PeerDevice aSeesB)> pair() async {
    final pairing = await b.client.startPairing('127.0.0.1', a.server.port!);
    await pairing.waitForApproval();
    expect(a.delegate.codes.single, pairing.code, reason: 'both screens show the same code');
    final peer = await pairing.confirm();
    await b.db.upsertPeer(peer);
    return (peer, (await a.db.getPeer(b.identity.deviceId))!);
  }

  group('pairing', () {
    test('comparison-code pairing is mutual and pins both certificates', () async {
      final (bSeesA, aSeesB) = await pair();
      expect(bSeesA.deviceId, a.identity.deviceId);
      expect(bSeesA.fingerprint, a.identity.fingerprint);
      expect(aSeesB.fingerprint, b.identity.fingerprint);
      expect(aSeesB.port, b.server.port);
      expect(await b.client.ping(bSeesA), isTrue);
    });

    test('QR pairing auto-approves with the one-time secret, and the secret cannot be reused', () async {
      a.delegate.qrSecret = 'secret-123';
      final pairing = await b.client.startPairing('127.0.0.1', a.server.port!,
          expectFp: a.identity.fingerprint, qrSecret: 'secret-123');
      await pairing.waitForApproval();
      await pairing.confirm();
      expect(a.delegate.codes, isEmpty, reason: 'no prompt needed');
      expect(await a.db.getPeer(b.identity.deviceId), isNotNull);

      await expectLater(
        b.client.startPairing('127.0.0.1', a.server.port!, expectFp: a.identity.fingerprint, qrSecret: 'secret-123'),
        throwsA(isA<PairingDeclinedException>()),
      );
    });

    test('declined pairing stores nothing on either side', () async {
      a.delegate.approve = false;
      final pairing = await b.client.startPairing('127.0.0.1', a.server.port!);
      await expectLater(pairing.waitForApproval(), throwsA(isA<PairingDeclinedException>()));
      expect(await a.db.listPeers(), isEmpty);
    });

    test('approved by receiver but never confirmed by sender: receiver stores nothing', () async {
      final pairing = await b.client.startPairing('127.0.0.1', a.server.port!);
      await pairing.waitForApproval();
      await pairing.cancel();
      expect(await a.db.listPeers(), isEmpty);
    });

    test('a client expecting a different certificate refuses to connect (impostor)', () async {
      await expectLater(
        b.client.startPairing('127.0.0.1', a.server.port!, expectFp: b.identity.fingerprint),
        throwsA(isA<IdentityMismatchException>()),
      );
    });

    test('a commitment made to another certificate is rejected (interception)', () async {
      // Simulate a client whose TLS session terminated at an attacker: its
      // commitment covers the attacker's fingerprint, not A's.
      final nonce = PairingCrypto.randomHex(32);
      final http = PinnedHttp(null);
      final base = Uri(scheme: 'https', host: '127.0.0.1', port: a.server.port!);
      Future<HttpClientResponse> post(String path, String body) async {
        final req = await http.open('POST', base.replace(path: path));
        req.headers.contentType = ContentType.json;
        req.write(body);
        return req.close();
      }

      final start = await post('/v2/pair/start',
          '{"deviceId":"${b.identity.deviceId}","name":"B","platform":"linux","fingerprint":"${b.identity.fingerprint}",'
          '"port":1,"commit":"${PairingCrypto.commit(nonceHex: nonce, clientFp: b.identity.fingerprint, serverFp: b.identity.fingerprint)}"}');
      final session = RegExp(r'"session":"([0-9a-f]+)"').firstMatch(await start.transform(const SystemEncoding().decoder).join())!.group(1);
      final finish = await post('/v2/pair/finish', '{"session":"$session","nonce":"$nonce"}');
      expect(finish.statusCode, 403);
      expect(a.delegate.codes, isEmpty, reason: 'user is never asked to approve');
      http.close();
    });

    test('the comparison code changes completely with any input', () {
      String code(String s) => PairingCrypto.sas(serverFp: s, clientFp: 'c', clientNonce: 'n', serverNonce: 'm');
      expect(code('a'), matches(RegExp(r'^\d{3} \d{3}$')));
      expect(code('a'), isNot(code('b')));
    });
  });

  group('backup', () {
    test('uploads, verifies, dedups and resumes', () async {
      final (bSeesA, _) = await pair();
      final f = await randomFile(root, 'IMG_0001.HEIC', 300 * 1024);
      final desc = FileDescriptor(
          sha256: await sha256OfFile(f.path), filename: 'IMG_0001.HEIC', size: await f.length(), createdAtMs: 1700000000000);

      expect((await b.client.backupCheck(bSeesA, desc)).state, RemoteFileState.missing);

      // Simulate an interrupted earlier upload: the first 100 KB are already on A.
      final part = a.storage.backupPart(desc.sha256);
      await part.writeAsBytes((await f.readAsBytes()).sublist(0, 100 * 1024));
      final check = await b.client.backupCheck(bSeesA, desc);
      expect(check.state, RemoteFileState.partial);
      expect(check.offset, 100 * 1024);

      final res = await b.client.backupUpload(bSeesA, desc, f, check.offset, onProgress: (_) {});
      expect(res.status, Protocol.stored);
      final saved = File(a.storage.absoluteBackup(res.path!));
      expect(await sha256OfFile(saved.path), desc.sha256);
      expect(res.path, startsWith('2023/11/'));

      expect((await b.client.backupCheck(bSeesA, desc)).state, RemoteFileState.exists);
      final again = await b.client.backupUpload(bSeesA, desc, f, 0, onProgress: (_) {});
      expect(again.status, Protocol.skipped);
    });

    test('the receiver sees backup progress: run status and file bytes', () async {
      final (bSeesA, _) = await pair();
      await b.client.backupStatus(
          bSeesA, const BackupRunStatus(runId: 'abcdef12', state: BackupRunState.running, done: 3, total: 10, file: 'IMG_1.HEIC').toJson());
      expect(a.delegate.runStatuses.single.done, 3);
      expect(a.delegate.runStatuses.single.total, 10);
      expect(a.delegate.runStatuses.single.file, 'IMG_1.HEIC');

      final f = await randomFile(root, 'p.jpg', 64 * 1024);
      final desc = FileDescriptor(sha256: await sha256OfFile(f.path), filename: 'p.jpg', size: 64 * 1024, createdAtMs: 0);
      await b.client.backupUpload(bSeesA, desc, f, 0, onProgress: (_) {});
      expect(a.delegate.fileProgress.last, ('p.jpg', 64 * 1024, 64 * 1024));

      // Malformed reports are rejected, not passed on.
      expect(BackupRunStatus.tryParse({'run': '../x', 'state': 'running', 'done': 1, 'total': 2}), isNull);
      expect(BackupRunStatus.tryParse({'run': 'abcdef12', 'state': 'bogus', 'done': 1, 'total': 2}), isNull);
    });

    test('a corrupted upload is discarded, never saved', () async {
      final (bSeesA, _) = await pair();
      final f = await randomFile(root, 'x.jpg', 2048);
      final wrong = FileDescriptor(sha256: 'a' * 64, filename: 'x.jpg', size: 2048, createdAtMs: 0);
      final res = await b.client.backupUpload(bSeesA, wrong, f, 0, onProgress: (_) {});
      expect(res.status, Protocol.hashMismatch);
      expect(await a.db.receivedCount(), 0);
    });

    test('requests with a wrong token are refused', () async {
      final (bSeesA, _) = await pair();
      final forged = PeerDevice(
        deviceId: bSeesA.deviceId,
        name: bSeesA.name,
        platform: bSeesA.platform,
        fingerprint: bSeesA.fingerprint,
        host: bSeesA.host,
        port: bSeesA.port,
        tokenOut: PairingCrypto.newToken(),
        tokenInHash: '',
      );
      final desc = FileDescriptor(sha256: 'b' * 64, filename: 'a', size: 1, createdAtMs: 0);
      await expectLater(b.client.backupCheck(forged, desc), throwsA(isA<UnauthorizedException>()));
    });
  });

  group('sharing', () {
    test('sends several files, sanitising names', () async {
      final (bSeesA, _) = await pair();
      final f1 = await randomFile(root, 'report.pdf', 150 * 1024);
      final f2 = await randomFile(root, '..hidden name.txt', 999);
      final sender = ShareSender(b.db, b.client);
      final share = sender.sendFiles(bSeesA, [f1.path, f2.path]);
      await _until(() => !share.isActive);

      expect(share.state, ShareState.done, reason: share.error);
      final names = a.storage.receivedRoot.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toSet();
      expect(names, containsAll(['report.pdf', 'hidden name.txt']));
      expect(await sha256OfFile('${a.storage.receivedRoot.path}/report.pdf'), await sha256OfFile(f1.path));
      expect(a.delegate.records.single.paths, hasLength(2));
      expect((await b.db.listTransfers()).single.status, TransferStatus.done);
    });

    test('declined offers send nothing', () async {
      final (bSeesA, _) = await pair();
      a.delegate.acceptShares = false;
      final f = await randomFile(root, 'secret.zip', 5000);
      final share = ShareSender(b.db, b.client).sendFiles(bSeesA, [f.path]);
      await _until(() => !share.isActive);
      expect(share.state, ShareState.declined);
      expect(a.storage.receivedRoot.listSync().whereType<File>(), isEmpty);
    });

    test('the receiver is told when an accepted transfer starts', () async {
      final (bSeesA, _) = await pair();
      final f = await randomFile(root, 's.bin', 4096);
      final share = ShareSender(b.db, b.client).sendFiles(bSeesA, [f.path]);
      await _until(() => !share.isActive);
      expect(share.state, ShareState.done, reason: share.error);
      expect(a.delegate.started, [share.id]);
    });

    test('auto-accept skips the prompt for trusted devices', () async {
      final (bSeesA, aSeesB) = await pair();
      await a.db.upsertPeer(aSeesB.copyWith(autoAccept: true));
      a.delegate.acceptShares = false; // would decline if asked
      final f = await randomFile(root, 'photo.jpg', 4096);
      final share = ShareSender(b.db, b.client).sendFiles(bSeesA, [f.path]);
      await _until(() => !share.isActive);
      expect(share.state, ShareState.done);
    });

    test('sends text', () async {
      final (bSeesA, _) = await pair();
      final share = ShareSender(b.db, b.client).sendText(bSeesA, 'https://example.com/hello');
      await _until(() => !share.isActive);
      expect(share.state, ShareState.done);
      expect(a.delegate.texts.single, 'https://example.com/hello');
    });

    test('pairing is mutual: A can send to B too', () async {
      await pair();
      final aSeesB = (await a.db.getPeer(b.identity.deviceId))!.copyWith(host: '127.0.0.1');
      final share = ShareSender(a.db, a.client).sendText(aSeesB, 'back at you');
      await _until(() => !share.isActive);
      expect(share.state, ShareState.done, reason: share.error);
      expect(b.delegate.texts.single, 'back at you');
    });
  });

  test('sanitizeFilename blocks traversal and hidden files', () {
    expect(sanitizeFilename('../../etc/passwd'), 'passwd');
    expect(sanitizeFilename(r'..\..\evil.jpg'), 'evil.jpg');
    expect(sanitizeFilename('.bashrc'), 'bashrc');
    expect(sanitizeFilename('..'), 'file');
    expect(sanitizeFilename(''), 'file');
    expect(sanitizeFilename('IMG_0001.HEIC'), 'IMG_0001.HEIC');
  });
}

Future<void> _until(bool Function() done, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
