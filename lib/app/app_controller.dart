import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../backup/backup_engine.dart';
import '../core/db.dart';
import '../core/identity.dart';
import '../core/models.dart';
import '../core/platform.dart';
import '../core/protocol.dart';
import '../net/discovery.dart';
import '../net/peer_client.dart';
import '../net/server.dart';
import '../security/pairing_crypto.dart';
import '../share/share_sender.dart';
import '../storage/storage.dart';

/// Something the user must answer, shown by the UI as a dialog.
sealed class AppPrompt {
  final Completer<bool> _done = Completer<bool>();
  Future<bool> get result => _done.future;
  bool get isOpen => !_done.isCompleted;

  void answer(bool value) {
    if (!_done.isCompleted) _done.complete(value);
  }
}

class PairingRequest extends AppPrompt {
  PairingRequest(this.prompt);
  final PairingPrompt prompt;
}

class ShareRequest extends AppPrompt {
  ShareRequest(this.prompt);
  final ShareOfferPrompt prompt;
  bool alwaysAccept = false;
}

class TextReceived extends AppPrompt {
  TextReceived(this.from, this.text);
  final PeerDevice from;
  final String text;
}

/// Live progress of a file transfer coming in.
class IncomingProgress {
  IncomingProgress(this.offerId, this.fromName, this.total);
  final String offerId;
  final String fromName;
  int received = 0;
  int total;
}

enum PeerStatus { online, offline, identityChanged }

/// Central app state. Owns every service and is the server's delegate.
class AppController extends ChangeNotifier implements ServerDelegate {
  AppController._(this.db, this.identity, this.storage);

  final AppDatabase db;
  final DeviceIdentity identity;
  Storage storage;

  late final LuceroServer server;
  late final PeerClient client;
  late final Discovery discovery;
  late final BackupEngine backup;
  late final ShareSender shares;

  List<PeerDevice> peers = [];
  final Map<String, NearbyDevice> nearby = {};
  List<TransferRecord> history = [];
  final prompts = <AppPrompt>[];
  final incoming = <String, IncomingProgress>{};
  final logLines = <String>[];

  bool receiving = true;
  bool includeVideos = true;
  String? backupTargetId;
  String? lastError;

  String? _qrSecret;
  DateTime? _qrSecretIssued;
  StreamSubscription<({NearbyDevice device, bool lost})>? _nearbySub;

  static Future<AppController> boot() async {
    final db = await AppDatabase.open();
    final dataDir = await getApplicationSupportDirectory();
    final identity = await DeviceIdentity.load(db, dataDir);
    final storage = await Storage.resolve(db);
    final app = AppController._(db, identity, storage);
    await app._init();
    return app;
  }

  Future<void> _init() async {
    server = LuceroServer(db: db, identity: identity, storage: storage, delegate: this);
    client = PeerClient(identity, serverPort: () => server.port ?? Protocol.defaultPort);
    discovery = Discovery(identity);
    backup = BackupEngine(db, client, discovery);
    shares = ShareSender(db, client);
    shares.addListener(() async {
      history = await db.listTransfers();
      notifyListeners();
    });
    server.addListener(notifyListeners);

    receiving = await db.getBool('receiving', fallback: true);
    includeVideos = await db.getBool('include_videos', fallback: true);
    backupTargetId = await db.getValue('backup_target');
    await _reloadPeers();
    history = await db.listTransfers();

    _nearbySub = discovery.events.listen(_onNearby);
    try {
      await discovery.startBrowsing();
    } catch (e) {
      _log('Discovery unavailable: $e');
    }
    if (receiving) await _startServer();
    final target = backupTarget;
    if (target != null) await backup.loadStats(target.deviceId);
  }

  // ---- receiving --------------------------------------------------------------------

  Future<void> _startServer() async {
    try {
      await server.start();
      await discovery.advertise(port: server.port!);
    } catch (e) {
      lastError = 'Could not start receiving: $e';
      _log(lastError!);
    }
    notifyListeners();
  }

  Future<void> setReceiving(bool on) async {
    receiving = on;
    await db.setBool('receiving', on);
    if (on) {
      await _startServer();
    } else {
      await discovery.stopAdvertising();
      await server.stop();
    }
    notifyListeners();
  }

  /// Re-announce after returning to the foreground or changing networks.
  Future<void> refreshNetwork() async {
    nearby.clear();
    notifyListeners();
    try {
      await discovery.restartBrowsing();
      if (receiving && server.isRunning) await discovery.advertise(port: server.port!);
    } catch (e) {
      _log('Discovery restart failed: $e');
    }
  }

  // ---- devices ----------------------------------------------------------------------

  Future<void> _reloadPeers() async {
    peers = await db.listPeers();
    notifyListeners();
  }

  PeerStatus statusOf(PeerDevice p) {
    final n = nearby[p.deviceId];
    if (n == null) return PeerStatus.offline;
    if (n.fingerprint.isNotEmpty && n.fingerprint != p.fingerprint) return PeerStatus.identityChanged;
    return PeerStatus.online;
  }

  List<NearbyDevice> get unpairedNearby =>
      nearby.values.where((n) => !peers.any((p) => p.deviceId == n.deviceId)).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  Future<void> _onNearby(({NearbyDevice device, bool lost}) e) async {
    if (e.lost) {
      nearby.remove(e.device.deviceId);
    } else {
      nearby[e.device.deviceId] = e.device;
      // Follow a paired device's new address, but only if it still advertises
      // the certificate we pinned (TLS proves it on connect anyway).
      final known = peers.where((p) => p.deviceId == e.device.deviceId).firstOrNull;
      if (known != null &&
          known.fingerprint == e.device.fingerprint &&
          (known.host != e.device.host || known.port != e.device.port || known.name != e.device.name)) {
        await db.upsertPeer(known.copyWith(host: e.device.host, port: e.device.port, name: e.device.name));
        await _reloadPeers();
      }
    }
    notifyListeners();
  }

  Future<OutgoingPairing> beginPairing(String host, int port, {String? expectFp, String? qrSecret}) =>
      client.startPairing(host, port, expectFp: expectFp, qrSecret: qrSecret);

  Future<PeerDevice> finishPairing(OutgoingPairing pairing) async {
    final peer = await pairing.confirm();
    await db.upsertPeer(peer);
    await _reloadPeers();
    if (backupTargetId == null) await setBackupTarget(peer.deviceId);
    _log('Paired with ${peer.name}');
    return peer;
  }

  Future<void> unpair(PeerDevice peer) async {
    await client.unpair(peer);
    await db.deletePeer(peer.deviceId);
    if (backupTargetId == peer.deviceId) await setBackupTarget(null);
    await _reloadPeers();
  }

  Future<void> setAutoAccept(PeerDevice peer, bool value) async {
    await db.upsertPeer(peer.copyWith(autoAccept: value));
    await _reloadPeers();
  }

  Future<void> rename(String name) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 40) return;
    identity.name = clean;
    await db.setValue('name', clean);
    if (receiving && server.isRunning) await discovery.advertise(port: server.port!);
    notifyListeners();
  }

  /// Fresh one-time secret for the pairing QR code (valid 10 minutes).
  String qrSecret() {
    final stale = _qrSecretIssued == null || DateTime.now().difference(_qrSecretIssued!) > const Duration(minutes: 10);
    if (_qrSecret == null || stale) {
      _qrSecret = PairingCrypto.randomHex(16);
      _qrSecretIssued = DateTime.now();
    }
    return _qrSecret!;
  }

  Future<PairingPayload?> pairingPayload() async {
    final host = await localIpv4();
    if (host == null || server.port == null) return null;
    return PairingPayload(
      deviceId: identity.deviceId,
      name: identity.name,
      platform: identity.platform,
      host: host,
      port: server.port!,
      fingerprint: identity.fingerprint,
      secret: qrSecret(),
    );
  }

  // ---- backup -----------------------------------------------------------------------

  PeerDevice? get backupTarget => peers.where((p) => p.deviceId == backupTargetId).firstOrNull;

  Future<void> setBackupTarget(String? deviceId) async {
    backupTargetId = deviceId;
    if (deviceId == null) {
      await db.removeValue('backup_target');
    } else {
      await db.setValue('backup_target', deviceId);
      await backup.loadStats(deviceId);
    }
    notifyListeners();
  }

  Future<void> setIncludeVideos(bool v) async {
    includeVideos = v;
    await db.setBool('include_videos', v);
    notifyListeners();
  }

  Future<void> runBackup() async {
    final target = backupTarget;
    if (target == null || !Caps.hasPhotoLibrary) return;
    await backup.run(target, includeVideos: includeVideos);
    history = await db.listTransfers();
    notifyListeners();
  }

  // ---- sharing ----------------------------------------------------------------------

  OutgoingShare sendFiles(PeerDevice peer, List<String> paths) => shares.sendFiles(peer, paths);

  OutgoingShare sendText(PeerDevice peer, String text) => shares.sendText(peer, text);

  Future<void> clearHistory() async {
    await db.clearTransfers();
    shares.clearFinished();
    history = [];
    notifyListeners();
  }

  // ---- folders ----------------------------------------------------------------------

  Future<void> setFolder({required bool backups, required String? path}) async {
    final key = backups ? Storage.kBackupsDir : Storage.kReceivedDir;
    if (path == null) {
      await db.removeValue(key);
    } else {
      await db.setValue(key, path);
    }
    await reloadStorage();
  }

  Future<void> reloadStorage() async {
    storage = await Storage.resolve(db);
    server.storage = storage;
    notifyListeners();
  }

  // ---- prompts ----------------------------------------------------------------------

  Future<bool> _ask(AppPrompt p) {
    prompts.add(p);
    notifyListeners();
    return p.result.whenComplete(() {
      prompts.remove(p);
      notifyListeners();
    });
  }

  @override
  Future<bool> approvePairing(PairingPrompt prompt) => _ask(PairingRequest(prompt));

  @override
  void pairingCancelled(String sessionId) {
    for (final p in prompts.whereType<PairingRequest>().where((p) => p.prompt.sessionId == sessionId).toList()) {
      p.answer(false);
    }
  }

  @override
  bool consumeQrSecret(String secret) {
    final valid = _qrSecret != null &&
        _qrSecretIssued != null &&
        DateTime.now().difference(_qrSecretIssued!) <= const Duration(minutes: 10) &&
        PairingCrypto.constantTimeEquals(secret, _qrSecret!);
    if (valid) {
      _qrSecret = null; // one-time
      notifyListeners();
    }
    return valid;
  }

  @override
  void peersChanged() => unawaited(_reloadPeers());

  @override
  Future<bool> approveShare(ShareOfferPrompt prompt) async {
    final request = ShareRequest(prompt);
    final ok = await _ask(request);
    if (ok) {
      incoming[prompt.offerId] = IncomingProgress(prompt.offerId, prompt.from.name, prompt.totalBytes);
      if (request.alwaysAccept) await setAutoAccept(prompt.from, true);
    }
    return ok;
  }

  @override
  void textReceived(PeerDevice from, String text) => unawaited(_ask(TextReceived(from, text)));

  @override
  void incomingProgress(String offerId, int receivedBytes, int totalBytes) {
    final p = incoming[offerId];
    if (p == null) return;
    p
      ..received = receivedBytes
      ..total = totalBytes;
    notifyListeners();
  }

  @override
  void incomingFinished(TransferRecord record) {
    incoming.remove(record.id);
    history = [record, ...history.where((h) => h.id != record.id)];
    notifyListeners();
  }

  @override
  void backupStored(PeerDevice from, String relPath) => _log('Backup from ${from.name}: $relPath');

  @override
  void log(String line) => _log(line);

  void _log(String line) {
    final t = DateTime.now();
    logLines.insert(0, '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}  $line');
    if (logLines.length > 300) logLines.removeLast();
    notifyListeners();
  }

  @override
  void dispose() {
    _nearbySub?.cancel();
    discovery.dispose();
    server.stop();
    super.dispose();
  }

  /// Opens the system file manager / photo library settings, etc. on desktop.
  static bool get canRevealFiles => Caps.isDesktop || Platform.isAndroid;
}
