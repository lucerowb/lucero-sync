import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../backup/backup_engine.dart';
import '../core/db.dart';
import '../core/identity.dart';
import '../core/models.dart';
import '../core/platform.dart';
import '../core/protocol.dart';
import '../net/discovery.dart';
import '../net/local_api.dart';
import '../net/peer_client.dart';
import '../net/server.dart';
import '../net/web_access.dart';
import '../security/pairing_crypto.dart';
import '../share/linux_airdrop.dart';
import '../share/share_sender.dart';
import '../storage/storage.dart';
import 'live_transfers.dart';
import 'mobile_bridge.dart';
import 'updates.dart';

export 'live_transfers.dart';

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

/// Someone nearby wants to AirDrop to this computer (Linux, owly or a4e).
class AirDropRequest extends AppPrompt {
  AirDropRequest(this.ask);
  final AirDropAsk ask;
}

class TextReceived extends AppPrompt {
  TextReceived(this.from, this.text);
  final PeerDevice from;
  final String text;
}

/// Live progress of a file transfer coming in, file by file.
class IncomingProgress {
  IncomingProgress(this.offerId, this.fromName, this.files) : title = transferTitle([for (final f in files) f.name]);
  final String offerId;
  final String fromName;
  final String title;
  final List<ShareFile> files;

  /// Bytes on disk per file id.
  final fileBytes = <String, int>{};
  final rate = RateMeter();
  DateTime updatedAt = DateTime.now();

  /// Set when the transfer ends (done, cancelled by the sender, failed).
  TransferStatus? status;
  List<String> paths = const [];

  int get total => files.fold(0, (a, f) => a + f.size);
  int get received => files.fold(0, (a, f) => a + (fileBytes[f.id] ?? 0));
  int get filesDone => files.where((f) => (fileBytes[f.id] ?? -1) >= f.size).length;

  /// No bytes for a while: the sender probably lost the connection.
  bool get stalled => DateTime.now().difference(updatedAt) > const Duration(seconds: 30);
  double? get fraction => total == 0 ? null : (received / total).clamp(0.0, 1.0);
}

enum PeerStatus { online, offline, identityChanged }

/// Central app state. Owns every service and is the server's delegate.
class AppController extends ChangeNotifier implements ServerDelegate, WebAccessHost, LocalApiHost {
  AppController._(this.db, this.identity, this.storage, this._dataDir);
  final Directory _dataDir;

  final AppDatabase db;
  final DeviceIdentity identity;
  @override
  Storage storage;

  late final LuceroServer server;
  late final PeerClient client;
  late final Discovery discovery;
  late final BackupEngine backup;
  late final ShareSender shares;
  late final WebAccess webAccess;
  late final MobileBridge mobile;

  /// Loopback API for the browser extension (desktop only).
  LocalApi? localApi;

  @override
  List<PeerDevice> peers = [];
  final Map<String, NearbyDevice> nearby = {};
  List<TransferRecord> history = [];
  final prompts = <AppPrompt>[];
  final incoming = <String, IncomingProgress>{};
  final incomingBackups = <String, IncomingBackup>{};

  /// Everything in flight in either direction, updated about once a second
  /// while anything is active. Drives the nav badge, tray and Live Activity.
  final live = ValueNotifier<LiveSummary>(const LiveSummary([]));
  Timer? _liveTimer;

  bool checkUpdates = true;

  /// Linux: owly or a4e, when installed.
  LinuxAirDrop? linuxAirDrop;

  /// When AirDrop receiving switches itself off; null while off.
  DateTime? airDropUntil;
  AirDropListener? _airDrop;

  /// A newer release the user hasn't dismissed; shown on the Share page.
  UpdateInfo? update;
  Timer? _updateTimer;
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
    final app = AppController._(db, identity, storage, dataDir);
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
    webAccess = WebAccess(this, loadPage: () => rootBundle.loadString('assets/web/index.html'));
    webAccess.addListener(notifyListeners);
    server.extraHandler = webAccess.handle;
    mobile = MobileBridge(this)..start();
    backup.addListener(_scheduleLive);
    addListener(_scheduleLive);

    receiving = await db.getBool('receiving', fallback: true);
    includeVideos = await db.getBool('include_videos', fallback: true);
    checkUpdates = await db.getBool('check_updates', fallback: true);
    linuxAirDrop = await LinuxAirDrop.detect();
    unawaited(_checkForUpdate());
    _updateTimer = Timer.periodic(const Duration(hours: 12), (_) => _checkForUpdate());
    backupTargetId = await db.getValue('backup_target');
    await _reloadPeers();
    history = await db.listTransfers();

    _nearbySub = discovery.events.listen(_onNearby);
    // Start browsing in the background: the first call can wait on the OS
    // local-network permission prompt, and receiving must not wait for it.
    unawaited(discovery.startBrowsing().timeout(const Duration(seconds: 20)).catchError((Object e) {
      _log('Discovery unavailable: $e');
    }));
    if (receiving) await _startServer();
    if (Caps.isDesktop) {
      final api = LocalApi(this, tempDir: Directory('${_dataDir.path}${Platform.pathSeparator}extension_uploads'));
      try {
        await api.start();
        api.addListener(notifyListeners);
        localApi = api;
      } catch (e) {
        _log('Browser extension API unavailable: $e');
      }
    }
    final target = backupTarget;
    if (target != null) await backup.loadStats(target.deviceId);
  }

  // ---- receiving --------------------------------------------------------------------

  Future<void> _startServer() async {
    try {
      await server.start();
      unawaited(discovery.advertise(port: server.port!).timeout(const Duration(seconds: 20)).catchError((Object e) {
        _log('Could not announce on the network: $e');
      }));
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

  Future<void> setCheckUpdates(bool v) async {
    checkUpdates = v;
    await db.setBool('check_updates', v);
    if (!v) update = null;
    notifyListeners();
    if (v) await _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    if (!checkUpdates) return;
    final found = await fetchUpdate();
    if (found == null || found.version == await db.getValue('dismissed_update')) return;
    update = found;
    notifyListeners();
  }

  /// Lets iPhones, iPads and Macs nearby AirDrop to this computer for 10
  /// minutes, like Apple's "Everyone for 10 minutes". Each request asks first.
  Future<void> setAirDropReceiving(bool on) async {
    _airDrop?.stop();
    _airDrop = null;
    airDropUntil = null;
    final tool = linuxAirDrop;
    if (on && tool != null) {
      const window = Duration(minutes: 10);
      try {
        final listener = await tool.receive(
          dir: storage.receivedRoot.path,
          duration: window,
          ask: (a) {
            final request = AirDropRequest(a);
            // The tools decline by themselves after ~15 s; close the dialog first.
            Timer(const Duration(seconds: 12), () => request.answer(false));
            return _ask(request);
          },
          onFiles: _airDropReceived,
          onLinks: (from, links) => unawaited(_ask(TextReceived(_browser(from), links.join('\n')))),
        );
        _airDrop = listener;
        airDropUntil = DateTime.now().add(window);
        unawaited(listener.done.then((_) {
          if (_airDrop != listener) return;
          _airDrop = null;
          airDropUntil = null;
          notifyListeners();
        }));
      } catch (e) {
        _log('AirDrop receiving failed: $e');
      }
    }
    notifyListeners();
  }

  Future<void> _airDropReceived(String from, List<String> paths) async {
    final record = TransferRecord(
      id: 'airdrop-${DateTime.now().microsecondsSinceEpoch}',
      direction: TransferDirection.incoming,
      kind: TransferKind.files,
      peerId: 'airdrop',
      peerName: from,
      title: transferTitle([for (final p in paths) p.split(Platform.pathSeparator).last]),
      size: paths.fold(0, (a, p) => a + (File(p).existsSync() ? File(p).lengthSync() : 0)),
      status: TransferStatus.done,
      paths: paths,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await db.addTransfer(record);
    incomingFinished(record);
  }

  /// "Later": hide this version's banner; a newer one shows again.
  Future<void> dismissUpdate() async {
    final u = update;
    if (u == null) return;
    update = null;
    await db.setValue('dismissed_update', u.version);
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
    if (ok && request.alwaysAccept) await setAutoAccept(prompt.from, true);
    return ok;
  }

  @override
  void incomingStarted(String offerId, PeerDevice from, List<ShareFile> files) {
    incoming[offerId] = IncomingProgress(offerId, from.name, files);
    notifyListeners();
  }

  @override
  void textReceived(PeerDevice from, String text) => unawaited(_ask(TextReceived(from, text)));

  @override
  void incomingProgress(String offerId, String fileId, int fileBytes) {
    final p = incoming[offerId];
    if (p == null) return;
    p.fileBytes[fileId] = fileBytes;
    p.updatedAt = DateTime.now();
    p.rate.add(p.received);
    notifyListeners();
  }

  @override
  void backupStatus(PeerDevice from, BackupRunStatus status) {
    final b = incomingBackups.putIfAbsent(from.deviceId, () => IncomingBackup(from.deviceId, from.name));
    if (b.runId != status.runId) {
      b
        ..runId = status.runId
        ..storedHere = 0;
    }
    b
      ..fromName = from.name
      ..state = status.state
      ..done = status.done
      ..total = status.total
      ..updatedAt = DateTime.now();
    if (status.file != null && status.file != b.file) {
      b
        ..file = status.file
        ..fileReceived = 0
        ..fileSize = 0;
    }
    notifyListeners();
  }

  @override
  void backupFileProgress(PeerDevice from, String filename, int received, int size) {
    final b = incomingBackups.putIfAbsent(from.deviceId, () => IncomingBackup(from.deviceId, from.name));
    if (b.finished) b.state = BackupRunState.running; // a sender too old to report status
    b
      ..file = filename
      ..fileReceived = received
      ..fileSize = size
      ..updatedAt = DateTime.now();
    notifyListeners();
  }

  // ---- web access (browsers on the network) -----------------------------------------

  @override
  String get deviceName => identity.name;
  @override
  String get platform => identity.platform;
  @override
  LiveSummary get liveSummary => live.value;

  PeerDevice _browser(String label) => PeerDevice(
        deviceId: 'web',
        name: label,
        platform: 'web',
        fingerprint: '',
        host: '',
        port: 0,
        tokenOut: '',
        tokenInHash: '',
      );

  @override
  void webUploadStarted(String id, String from, int total, String name) =>
      incomingStarted(id, _browser(from), [ShareFile(id: 'f', name: name, size: total, sha256: '')]);

  @override
  void webUploadProgress(String id, int received, int total) => incomingProgress(id, 'f', received);

  @override
  Future<void> webUploadFinished(TransferRecord record) async {
    await db.addTransfer(record);
    incomingFinished(record);
  }

  @override
  void webText(String from, String text) {
    unawaited(db.addTransfer(TransferRecord(
      id: PairingCrypto.randomHex(16),
      direction: TransferDirection.incoming,
      kind: TransferKind.text,
      peerId: 'web',
      peerName: from,
      title: 'Text',
      detail: text,
      status: TransferStatus.done,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    )).then((_) async {
      history = await db.listTransfers();
      notifyListeners();
    }));
    unawaited(_ask(TextReceived(_browser(from), text)));
  }

  // ---- browser extension (loopback API) ---------------------------------------------

  @override
  bool isOnline(PeerDevice peer) => statusOf(peer) == PeerStatus.online;

  @override
  String sendTextTo(PeerDevice peer, String text) => shares.sendText(peer, text).id;

  @override
  String sendFilesTo(PeerDevice peer, List<String> paths) => shares.sendFiles(peer, paths).id;

  @override
  Future<List<String>> loadExtensionTokenHashes() async {
    final raw = await db.getValue('extension_tokens');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> saveExtensionTokenHashes(List<String> hashes) => db.setValue('extension_tokens', jsonEncode(hashes));

  // ---- live summary ---------------------------------------------------------------

  void _scheduleLive() {
    _refreshLive();
    _liveTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => _refreshLive(tick: true));
  }

  void _refreshLive({bool tick = false}) {
    // Finished incoming backups linger briefly so "Done" is visible.
    incomingBackups.removeWhere((_, b) =>
        (b.finished && DateTime.now().difference(b.updatedAt) > const Duration(seconds: 15)) ||
        DateTime.now().difference(b.updatedAt) > const Duration(minutes: 10));
    incoming.removeWhere((_, p) => DateTime.now().difference(p.updatedAt) > const Duration(hours: 1));

    final items = <LiveItem>[
      for (final s in shares.active.where((s) => s.isActive))
        LiveItem(
          id: s.id,
          direction: LiveDirection.sending,
          backup: false,
          peerName: s.peer.name,
          title: s.title,
          status: switch (s.state) {
            ShareState.preparing => 'Preparing',
            ShareState.waitingForAccept => 'Waiting for ${s.peer.name} to accept',
            _ => '${_bytes(s.sentBytes)} of ${_bytes(s.totalBytes)}',
          },
          fraction: s.state == ShareState.sending ? s.fraction : null,
        ),
      for (final p in incoming.values)
        LiveItem(
          id: p.offerId,
          direction: LiveDirection.receiving,
          backup: false,
          peerName: p.fromName,
          title: p.title,
          status: p.stalled ? 'Paused, waiting for ${p.fromName}' : '${_bytes(p.received)} of ${_bytes(p.total)}',
          fraction: p.fraction,
        ),
      if (backup.isRunning)
        LiveItem(
          id: 'backup-out',
          direction: LiveDirection.sending,
          backup: true,
          peerName: backupTarget?.name ?? 'device',
          title: 'Photo backup',
          status: switch (backup.phase) {
            BackupPhase.scanning => 'Scanning library · ${backup.scanned}',
            BackupPhase.waitingForPeer => 'Waiting for ${backupTarget?.name ?? 'device'}',
            _ => '${backup.storedThisRun + backup.skippedThisRun + backup.failedThisRun} of '
                '${backup.storedThisRun + backup.skippedThisRun + backup.failedThisRun + backup.pending}',
          },
          fraction: backup.phase == BackupPhase.transferring ? backup.fraction : null,
        ),
      for (final b in incomingBackups.values.where((b) => !b.finished))
        LiveItem(
          id: 'backup-in-${b.peerId}',
          direction: LiveDirection.receiving,
          backup: true,
          peerName: b.fromName,
          title: 'Photo backup',
          status: b.stalled
              ? 'Paused, waiting for ${b.fromName}'
              : b.total > 0
                  ? '${b.done} of ${b.total}'
                  : 'Receiving',
          fraction: b.fraction,
        ),
    ];
    live.value = LiveSummary(items);
    if (items.isEmpty && incomingBackups.isEmpty) {
      _liveTimer?.cancel();
      _liveTimer = null;
    } else if (tick) {
      notifyListeners(); // so "paused" states and lingering cards update
    }
  }

  static String _bytes(int n) {
    if (n < 1024) return '$n B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var v = n / 1024;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
  }

  @override
  void incomingFinished(TransferRecord record) {
    // An open transfer page keeps the object, so give it the outcome.
    incoming.remove(record.id)
      ?..status = record.status
      ..paths = record.paths;
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
    _liveTimer?.cancel();
    _updateTimer?.cancel();
    _airDrop?.stop();
    _nearbySub?.cancel();
    localApi?.stop();
    discovery.dispose();
    server.stop();
    super.dispose();
  }

  /// Opens the system file manager / photo library settings, etc. on desktop.
  static bool get canRevealFiles => Caps.isDesktop || Platform.isAndroid;
}
