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
import '../discovery/discovery_service.dart';
import 'library_scanner.dart';
import 'transfer_client.dart';

enum SyncPhase { idle, scanning, waitingForPeer, transferring, done, cancelled, error }

/// A problem with one specific file. It costs a retry attempt; the queue moves on.
class _ItemException implements Exception {
  _ItemException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Cancelled implements Exception {}

/// Sender-side engine:
///   1. diff the photo library against `synced_assets` -> persistent queue
///   2. for each queued asset: hash -> ask receiver -> upload remainder -> ledger
///   3. on network loss: back off, re-resolve via mDNS, resume from the
///      receiver-reported byte offset
class SyncEngine extends ChangeNotifier {
  SyncEngine(this._db, this._scanner, this._client, this._discovery);

  final AppDatabase _db;
  final LibraryScanner _scanner;
  final TransferClient _client;
  final DiscoveryService _discovery;

  static const maxAttempts = 5;
  static const _peerWaitLimit = Duration(minutes: 10);

  // Observable progress (read by the UI).
  SyncPhase phase = SyncPhase.idle;
  String? message;
  int scanned = 0;
  int pending = 0;
  int failedPermanently = 0;
  int syncedTotal = 0;
  int storedThisRun = 0;
  int skippedThisRun = 0;
  int failedThisRun = 0;
  String? currentFile;
  int currentSent = 0;
  int currentSize = 0;

  bool _cancelRequested = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isRunning =>
      phase == SyncPhase.scanning || phase == SyncPhase.waitingForPeer || phase == SyncPhase.transferring;

  void cancel() => _cancelRequested = true;

  Future<void> sync(PeerInfo peer) async {
    if (isRunning) return;
    _cancelRequested = false;
    scanned = storedThisRun = skippedThisRun = failedThisRun = 0;
    currentFile = null;
    message = null;
    await WakelockPlus.enable();

    try {
      if (!await _scanner.requestPermission()) {
        throw _ItemException('Photo library access was denied');
      }
      await _db.resetInterruptedUploads(peer.deviceId);

      _setPhase(SyncPhase.scanning);
      await _buildQueue(peer);
      await _refreshStats(peer);

      peer = await _waitForPeer(peer);
      _setPhase(SyncPhase.transferring);
      await _drainQueue(peer);

      _setPhase(SyncPhase.done,
          msg: failedPermanently > 0 ? '$failedPermanently item(s) failed after $maxAttempts attempts' : null);
    } on _Cancelled {
      _setPhase(SyncPhase.cancelled, msg: 'Stopped. The next sync resumes from here.');
    } on UnauthorizedException catch (e) {
      _setPhase(SyncPhase.error, msg: '$e — re-pair with this receiver.');
    } catch (e) {
      _setPhase(SyncPhase.error, msg: '$e');
    } finally {
      currentFile = null;
      await _refreshStats(peer);
      await WakelockPlus.disable();
      // iOS copies originals into the app cache; don't let it grow unbounded.
      await PhotoManager.clearFileCache();
      notifyListeners();
    }
  }

  // ---- step 1: diff library vs ledger ---------------------------------------

  Future<void> _buildQueue(PeerInfo peer) async {
    final synced = await _db.syncedAssetIds(peer.deviceId);
    await for (final page in _scanner.pages()) {
      _checkCancel();
      final fresh = page.where((a) => !synced.contains(a.id));
      await _db.enqueue(
        peer.deviceId,
        fresh.map((a) => (assetId: a.id, createdAtMs: a.createDateTime.millisecondsSinceEpoch)),
      );
      scanned += page.length;
      _notifyThrottled();
    }
  }

  // ---- step 2: work the queue -----------------------------------------------

  Future<void> _drainQueue(PeerInfo peer) async {
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
      } catch (e) {
        if (!isTransientNetworkError(e)) {
          failedThisRun++;
          await _db.markFailed(item, '$e', countAttempt: true);
        } else {
          // Connection dropped: don't penalise the file, wait for the receiver.
          // But if the same file keeps dropping while the receiver stays
          // reachable, the file itself is the problem — count it.
          transientStreak = lastTransientAsset == item.assetId ? transientStreak + 1 : 1;
          lastTransientAsset = item.assetId;
          await _db.markFailed(item, '$e', countAttempt: transientStreak >= 4);
          peer = await _waitForPeer(peer);
          _setPhase(SyncPhase.transferring);
        }
      }
      await _refreshStats(peer);
    }
  }

  /// Sends every file that makes up one library asset, then records it in the
  /// ledger. A Live Photo is two files (still + paired MOV) and only counts as
  /// synced once both are on the receiver; if the MOV fails, the next attempt
  /// re-checks the still (instant "exists") and retries just the video.
  Future<void> _transfer(PeerInfo peer, QueueItem item) async {
    final asset = await AssetEntity.fromId(item.assetId);
    if (asset == null) {
      // Deleted from the library before we got to it — nothing to back up.
      await _db.dropQueueItem(item);
      return;
    }

    var filename = item.filename ?? await asset.titleAsync;
    if (filename.isEmpty) filename = 'asset_${item.assetId.hashCode.abs()}';

    // Part 1: the original still image or video (HEIC/RAW/MOV, unedited).
    // May pull from iCloud on iOS.
    _startFile(filename, item.size ?? 0);
    final File? file = await asset.originFile;
    if (file == null) throw _ItemException('Original not available (iCloud-only and offline?)');

    final size = await file.length();
    final sha = (item.sha256 != null && item.size == size) ? item.sha256! : await sha256OfFile(file.path);
    await _db.markUploading(item, filename: filename, size: size, sha256: sha);

    final primary = FileDescriptor(sha256: sha, filename: filename, size: size, createdAtMs: item.createdAtMs);
    final results = [await _sendFile(peer, primary, file)];

    // Part 2: the Live Photo's motion video. Named after the still
    // (IMG_0001.HEIC + IMG_0001.MOV) so the pair stays together on disk.
    if (Platform.isIOS && asset.isLivePhoto) {
      final motion = await asset.originFileWithSubtype;
      if (motion == null || motion.path == file.path) {
        throw _ItemException('Live Photo video not available (iCloud-only and offline?)');
      }
      final motionName = '${p.basenameWithoutExtension(filename)}${p.extension(motion.path).toUpperCase()}';
      _startFile('$motionName (Live Photo video)', 0);
      final motionSize = await motion.length();
      final motionDesc = FileDescriptor(
        sha256: await sha256OfFile(motion.path),
        filename: motionName,
        size: motionSize,
        createdAtMs: item.createdAtMs,
      );
      results.add(await _sendFile(peer, motionDesc, motion));
    }

    final anyStored = results.contains(Protocol.stored);
    await _db.markSynced(item, primary, anyStored ? Protocol.stored : Protocol.skipped);
    if (anyStored) {
      storedThisRun++;
    } else {
      skippedThisRun++;
    }
  }

  /// Pre-check + resumable upload of a single file. Returns `stored` or `skipped`.
  Future<String> _sendFile(PeerInfo peer, FileDescriptor desc, File file) async {
    currentSize = desc.size;
    final check = await _client.check(peer, desc);
    if (check.state == RemoteFileState.exists) return Protocol.skipped;

    var offset = check.state == RemoteFileState.partial ? check.offset : 0;
    if (offset > desc.size) offset = 0;

    for (var round = 0; round < 3; round++) {
      _checkCancel();
      final res = await _client.upload(peer, desc, file, offset, onProgress: (sent) {
        currentSent = sent;
        _notifyThrottled();
      });

      switch (res.status) {
        case Protocol.stored:
        case Protocol.skipped:
          return res.status;
        case Protocol.partial:
        case Protocol.offsetMismatch:
          offset = res.offset; // receiver tells us where to continue
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

  // ---- reconnect / backoff ---------------------------------------------------

  /// Polls the receiver with exponential backoff (2s → 60s). Every few tries it
  /// re-resolves via mDNS in case the receiver got a new IP from DHCP.
  Future<PeerInfo> _waitForPeer(PeerInfo peer) async {
    if (await _client.ping(peer)) return peer;

    _setPhase(SyncPhase.waitingForPeer, msg: 'Waiting for ${peer.name}…');
    final deadline = DateTime.now().add(_peerWaitLimit);
    var delay = const Duration(seconds: 2);
    var attempt = 0;

    while (DateTime.now().isBefore(deadline)) {
      _checkCancel();
      await Future<void>.delayed(delay);
      attempt++;

      if (attempt % 3 == 0) {
        final found = await _discovery.find(peer.deviceId);
        if (found != null && (found.host != peer.host || found.port != peer.port)) {
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
    throw const SocketException('Receiver unreachable. Queue saved; sync again to resume.');
  }

  // ---- helpers ----------------------------------------------------------------

  void _checkCancel() {
    if (_cancelRequested) throw _Cancelled();
  }

  Future<void> _refreshStats(PeerInfo peer) async {
    final s = await _db.queueStats(peer.deviceId, maxAttempts: maxAttempts);
    pending = s.pending;
    failedPermanently = s.failed;
    syncedTotal = s.synced;
    notifyListeners();
  }

  void _setPhase(SyncPhase p, {String? msg}) {
    phase = p;
    message = msg;
    notifyListeners();
  }

  void _notifyThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastNotify) > const Duration(milliseconds: 200)) {
      _lastNotify = now;
      notifyListeners();
    }
  }
}
