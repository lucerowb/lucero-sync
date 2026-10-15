import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/db.dart';
import '../core/hashing.dart';
import '../core/models.dart';
import '../core/protocol.dart';
import '../net/discovery.dart';
import '../net/peer_client.dart';
import '../security/pairing_crypto.dart';
import 'library_scanner.dart';

enum BackupPhase { idle, scanning, waitingForPeer, transferring, done, cancelled, error }

class _ItemException implements Exception {
  _ItemException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Cancelled implements Exception {}

/// Photo-library backup to one paired device.
///
///   1. diff the library against `synced_assets` → persistent queue
///   2. per asset: hash → receiver pre-check → upload the remainder → ledger
///   3. on network loss: back off, re-find the receiver via mDNS (accepting a
///      new address only if it presents the pinned certificate), and resume
///      from the byte offset the receiver reports
class BackupEngine extends ChangeNotifier {
  BackupEngine(this._db, this._client, this._discovery, {LibraryScanner? scanner})
      : _scanner = scanner ?? LibraryScanner();

  final AppDatabase _db;
  final PeerClient _client;
  final Discovery _discovery;
  final LibraryScanner _scanner;

  static const maxAttempts = 5;
  static const _peerWaitLimit = Duration(minutes: 10);

  BackupPhase phase = BackupPhase.idle;
  String? message;
  String? peerId;
  int scanned = 0;
  int pending = 0;
  int failedPermanently = 0;
  int syncedTotal = 0;
  int? lastSyncedAt;
  int storedThisRun = 0;
  int skippedThisRun = 0;
  int failedThisRun = 0;
  String? currentFile;
  int currentSent = 0;
  int currentSize = 0;

  bool _cancelRequested = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// The receiver of the current run, told about progress so it can show it.
  PeerDevice? _reportTo;
  String _runId = '';
  DateTime _lastReport = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isRunning =>
      phase == BackupPhase.scanning || phase == BackupPhase.waitingForPeer || phase == BackupPhase.transferring;

  double? get fraction {
    final total = storedThisRun + skippedThisRun + failedThisRun + pending;
    if (total == 0) return null;
    return (storedThisRun + skippedThisRun + failedThisRun) / total;
  }

  void cancel() => _cancelRequested = true;

  Future<void> loadStats(String peerId) async {
    this.peerId = peerId;
    await _refreshStats(peerId);
  }

  Future<void> run(PeerDevice peer, {required bool includeVideos}) async {
    if (isRunning) return;
    _cancelRequested = false;
    peerId = peer.deviceId;
    scanned = storedThisRun = skippedThisRun = failedThisRun = 0;
    currentFile = null;
    message = null;
    _reportTo = peer;
    _runId = PairingCrypto.randomHex(8);
    await WakelockPlus.enable();

    try {
      if (!await _scanner.requestPermission()) throw _ItemException('Photo library access was denied.');
      await _db.resetInterruptedUploads(peer.deviceId);

      _setPhase(BackupPhase.scanning);
      await _buildQueue(peer, includeVideos: includeVideos);
      await _refreshStats(peer.deviceId);

      peer = await _waitForPeer(peer);
      _reportTo = peer;
      _setPhase(BackupPhase.transferring);
      await _drainQueue(peer);

      _setPhase(BackupPhase.done,
          msg: failedPermanently > 0 ? '$failedPermanently item(s) failed after $maxAttempts attempts.' : null);
    } on _Cancelled {
      _setPhase(BackupPhase.cancelled, msg: 'Stopped. The next backup resumes from here.');
    } on UnauthorizedException catch (e) {
      _setPhase(BackupPhase.error, msg: '$e');
    } on IdentityMismatchException catch (e) {
      _setPhase(BackupPhase.error, msg: '$e');
    } catch (e) {
      _setPhase(BackupPhase.error, msg: '$e');
    } finally {
      currentFile = null;
      await _refreshStats(peer.deviceId);
      unawaited(_report(force: true)); // reads _reportTo before its first await
      _reportTo = null;
      await WakelockPlus.disable();
      // iOS/macOS copy originals into the app cache; don't let it grow.
      try {
        await PhotoManager.clearFileCache();
      } catch (_) {}
      notifyListeners();
    }
  }

  Future<void> _buildQueue(PeerDevice peer, {required bool includeVideos}) async {
    final synced = await _db.syncedAssetIds(peer.deviceId);
    await for (final page in _scanner.pages(includeVideos: includeVideos)) {
      _checkCancel();
      await _db.enqueue(
        peer.deviceId,
        page
            .where((a) => !synced.contains(a.id))
            .map((a) => (assetId: a.id, createdAtMs: a.createDateTime.millisecondsSinceEpoch)),
      );
      scanned += page.length;
      _notifyThrottled();
    }
  }

  Future<void> _drainQueue(PeerDevice peer) async {
    String? lastTransientAsset;
    var transientStreak = 0;

    while (true) {
      _checkCancel();
      final item = await _db.nextQueueItem(peer.deviceId, maxAttempts: maxAttempts);
      if (item == null) return;

      try {
        await _transfer(peer, item);
        transientStreak = 0;
      } on _ItemException catch (e) {
        failedThisRun++;
        await _db.markFailed(item, e.message, countAttempt: true);
      } on UnauthorizedException {
        await _db.markFailed(item, 'unauthorized', countAttempt: false);
        rethrow;
      } on IdentityMismatchException {
        await _db.markFailed(item, 'identity mismatch', countAttempt: false);
        rethrow;
      } catch (e) {
        if (!isTransientNetworkError(e)) {
          failedThisRun++;
          await _db.markFailed(item, '$e', countAttempt: true);
        } else {
          // The same file failing repeatedly while the receiver stays
          // reachable means the file is the problem; count it.
          transientStreak = lastTransientAsset == item.assetId ? transientStreak + 1 : 1;
          lastTransientAsset = item.assetId;
          await _db.markFailed(item, '$e', countAttempt: transientStreak >= 4);
          peer = await _waitForPeer(peer);
          _reportTo = peer;
          _setPhase(BackupPhase.transferring);
        }
      }
      await _refreshStats(peer.deviceId);
      unawaited(_report());
    }
  }

  /// A Live Photo is two files (still + paired MOV); it only counts as synced
  /// once both are on the receiver.
  Future<void> _transfer(PeerDevice peer, QueueItem item) async {
    final asset = await AssetEntity.fromId(item.assetId);
    if (asset == null) {
      await _db.dropQueueItem(item); // deleted from the library meanwhile
      return;
    }

    var filename = item.filename ?? await asset.titleAsync;
    if (filename.isEmpty) filename = 'asset_${item.assetId.hashCode.abs()}';

    _startFile(filename, item.size ?? 0);
    final File? file = await asset.originFile;
    if (file == null) throw _ItemException('Original not available (iCloud-only and offline?)');

    final size = await file.length();
    final sha = (item.sha256 != null && item.size == size) ? item.sha256! : await sha256OfFile(file.path);
    await _db.markUploading(item, filename: filename, size: size, sha256: sha);

    final primary = FileDescriptor(sha256: sha, filename: filename, size: size, createdAtMs: item.createdAtMs);
    final results = [await _sendFile(peer, primary, file)];

    if ((Platform.isIOS || Platform.isMacOS) && asset.isLivePhoto) {
      final motion = await asset.originFileWithSubtype;
      if (motion == null || motion.path == file.path) {
        throw _ItemException('Live Photo video not available (iCloud-only and offline?)');
      }
      final motionName = '${p.basenameWithoutExtension(filename)}${p.extension(motion.path).toUpperCase()}';
      _startFile('$motionName (Live Photo video)', 0);
      results.add(await _sendFile(
        peer,
        FileDescriptor(
          sha256: await sha256OfFile(motion.path),
          filename: motionName,
          size: await motion.length(),
          createdAtMs: item.createdAtMs,
        ),
        motion,
      ));
    }

    final anyStored = results.contains(Protocol.stored);
    await _db.markSynced(item, primary, anyStored ? Protocol.stored : Protocol.skipped);
    anyStored ? storedThisRun++ : skippedThisRun++;
  }

  Future<String> _sendFile(PeerDevice peer, FileDescriptor desc, File file) async {
    currentSize = desc.size;
    final check = await _client.backupCheck(peer, desc);
    if (check.state == RemoteFileState.exists) return Protocol.skipped;

    var offset = check.state == RemoteFileState.partial ? check.offset : 0;
    if (offset > desc.size) offset = 0;

    for (var round = 0; round < 3; round++) {
      _checkCancel();
      final res = await _client.backupUpload(peer, desc, file, offset, onProgress: (sent) {
        currentSent = sent;
        _notifyThrottled();
      });
      switch (res.status) {
        case Protocol.stored:
        case Protocol.skipped:
          return res.status;
        case Protocol.partial:
        case Protocol.offsetMismatch:
          offset = res.offset;
          continue;
        case Protocol.busy:
          throw const SocketException('Receiver busy with this file');
        default:
          throw _ItemException('Receiver: ${res.status}${res.message != null ? ' (${res.message})' : ''}');
      }
    }
    throw _ItemException('Upload of ${desc.filename} did not complete after resuming 3 times');
  }

  void _startFile(String name, int size) {
    currentFile = name;
    currentSent = 0;
    currentSize = size;
    notifyListeners();
  }

  /// Backs off 2 s → 60 s. Every few tries, re-finds the receiver via mDNS in
  /// case its address changed; a new address is only used when the device
  /// advertises the fingerprint we pinned (and TLS then proves it).
  Future<PeerDevice> _waitForPeer(PeerDevice peer) async {
    if (await _client.ping(peer)) return peer;

    _setPhase(BackupPhase.waitingForPeer, msg: 'Waiting for ${peer.name}…');
    final deadline = DateTime.now().add(_peerWaitLimit);
    var delay = const Duration(seconds: 2);
    var attempt = 0;

    while (DateTime.now().isBefore(deadline)) {
      _checkCancel();
      await Future<void>.delayed(delay);
      attempt++;
      if (attempt % 3 == 0) {
        final found = await _discovery.find(peer.deviceId);
        if (found != null && found.fingerprint == peer.fingerprint && (found.host != peer.host || found.port != peer.port)) {
          peer = peer.copyWith(host: found.host, port: found.port);
          await _db.upsertPeer(peer);
        }
      }
      if (await _client.ping(peer)) {
        message = null;
        return peer;
      }
      delay = Duration(seconds: min(delay.inSeconds * 2, 60));
    }
    throw const SocketException('The receiving device is unreachable. The queue is saved; back up again to resume.');
  }

  void _checkCancel() {
    if (_cancelRequested) throw _Cancelled();
  }

  Future<void> _refreshStats(String peerId) async {
    final s = await _db.queueStats(peerId, maxAttempts: maxAttempts);
    pending = s.pending;
    failedPermanently = s.failed;
    syncedTotal = s.synced;
    lastSyncedAt = s.lastSyncedAt;
    notifyListeners();
  }

  void _setPhase(BackupPhase p, {String? msg}) {
    phase = p;
    message = msg;
    notifyListeners();
    // The final state is sent from run()'s finally, once stats are fresh.
    if (isRunning) unawaited(_report(force: true));
  }

  /// Sends this run's progress to the receiver: on phase changes, and at
  /// most every 2 s otherwise.
  Future<void> _report({bool force = false}) async {
    final peer = _reportTo;
    if (peer == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastReport) < const Duration(seconds: 2)) return;
    _lastReport = now;
    final done = storedThisRun + skippedThisRun + failedThisRun;
    await _client.backupStatus(
      peer,
      BackupRunStatus(
        runId: _runId,
        state: switch (phase) {
          BackupPhase.scanning => BackupRunState.scanning,
          BackupPhase.waitingForPeer => BackupRunState.waiting,
          BackupPhase.transferring => BackupRunState.running,
          BackupPhase.done => BackupRunState.done,
          BackupPhase.cancelled => BackupRunState.cancelled,
          _ => BackupRunState.error,
        },
        done: done,
        total: done + pending,
        file: currentFile,
      ).toJson(),
    );
  }

  void _notifyThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastNotify) > const Duration(milliseconds: 200)) {
      _lastNotify = now;
      notifyListeners();
    }
  }
}
