import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/db.dart';
import '../core/hashing.dart';
import '../core/identity.dart';
import '../core/models.dart';
import '../core/protocol.dart';
import '../security/pairing_crypto.dart';
import '../storage/storage.dart';

/// A device asking to pair, shown to the user with the comparison code.
class PairingPrompt {
  PairingPrompt({required this.sessionId, required this.name, required this.platform, required this.code});

  final String sessionId;
  final String name;
  final String platform;

  /// Six-digit code that must match the one on the other device.
  final String code;
}

/// Files offered by a paired device, shown for accept/decline.
class ShareOfferPrompt {
  ShareOfferPrompt({required this.offerId, required this.from, required this.files});

  final String offerId;
  final PeerDevice from;
  final List<ShareFile> files;

  int get totalBytes => files.fold(0, (a, f) => a + f.size);
}

/// What the server needs from the app (UI prompts, notifications).
abstract class ServerDelegate {
  /// Shows the comparison code; completes with the user's decision.
  Future<bool> approvePairing(PairingPrompt prompt);

  /// Dismisses an approval dialog the other side gave up on.
  void pairingCancelled(String sessionId);

  /// Validates and consumes the one-time secret from the displayed QR code.
  bool consumeQrSecret(String secret);

  void peersChanged();

  Future<bool> approveShare(ShareOfferPrompt prompt);

  void textReceived(PeerDevice from, String text);

  /// An accepted offer (prompted or auto-accepted) is about to receive [files].
  void incomingStarted(String offerId, PeerDevice from, List<ShareFile> files);

  /// [fileBytes] of file [fileId] are on disk; equals its size once verified.
  void incomingProgress(String offerId, String fileId, int fileBytes);

  /// The sender's view of a backup run (see `/v2/backup/status`).
  void backupStatus(PeerDevice from, BackupRunStatus status);

  /// Bytes of the backup file currently arriving from [from].
  void backupFileProgress(PeerDevice from, String filename, int received, int size);

  void incomingFinished(TransferRecord record);

  void backupStored(PeerDevice from, String relPath);

  void log(String line);
}

class _PairSession {
  _PairSession({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.fingerprint,
    required this.port,
    required this.commitment,
    required this.serverNonce,
    required this.viaQr,
    required this.remote,
  });

  final String id;
  final String deviceId;
  final String name;
  final String platform;
  final String fingerprint;
  final int port;
  final String commitment;
  final String serverNonce;
  final bool viaQr;
  final String remote;
  final created = DateTime.now();

  /// Set once the receiver approved; the token the client will present to us.
  String? tokenForClient;
  bool cancelled = false;
}

class _IncomingOffer {
  _IncomingOffer(this.id, this.from, this.files, this.accepted);

  final String id;
  final PeerDevice from;
  final Map<String, ShareFile> files;
  final Set<String> accepted;
  final Map<String, String> savedPaths = {};
  final topDirs = <String, String>{};
  final created = DateTime.now();
  int receivedBytes = 0;

  int get totalBytes => accepted.fold(0, (a, id) => a + files[id]!.size);
  bool get complete => savedPaths.length == accepted.length;
}

/// HTTPS server implementing protocol v2. See `core/protocol.dart`.
class LuceroServer extends ChangeNotifier {
  LuceroServer({required this.db, required this.identity, required this.storage, required this.delegate});

  final AppDatabase db;
  final DeviceIdentity identity;
  Storage storage;
  final ServerDelegate delegate;

  /// Handles requests outside `/v2` (web access). Returns false if unhandled.
  Future<bool> Function(HttpRequest req)? extraHandler;

  HttpServer? _server;
  final _pairSessions = <String, _PairSession>{};
  final _offers = <String, _IncomingOffer>{};
  final _inFlight = <String>{};
  final _failedPairAttempts = <String, List<DateTime>>{};

  int storedThisSession = 0;
  int skippedThisSession = 0;
  int totalReceived = 0;

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  static const _approvalTimeout = Duration(minutes: 2);
  static const _maxBodyBytes = 1 << 20; // JSON bodies

  Future<void> start({int port = Protocol.defaultPort}) async {
    if (_server != null) return;
    totalReceived = await db.receivedCount();
    HttpServer? server;
    // Fall back to an OS-assigned port if the default is taken (common on desktops).
    for (final candidate in [port, port + 1, port + 2, 0]) {
      try {
        server = await HttpServer.bindSecure(InternetAddress.anyIPv4, candidate, identity.tls.serverContext());
        break;
      } on SocketException {
        if (candidate == 0) rethrow;
      }
    }
    server!.idleTimeout = const Duration(seconds: 30);
    _server = server;
    server.listen((req) => unawaited(_handle(req)), onError: (Object e) => delegate.log('Server error: $e'));
    delegate.log('Receiving on port ${server.port}');
    notifyListeners();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    notifyListeners();
  }

  // ---- routing ------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    try {
      final seg = req.uri.pathSegments;
      if (seg.isEmpty || seg.first != 'v2') {
        if (extraHandler != null && await extraHandler!(req)) return;
        return await _reply(req, 404, {'status': 'not_found'});
      }
      final route = seg.skip(1).join('/');

      // Unauthenticated: identity and pairing.
      if (req.method == 'GET' && route == 'info') return await _info(req);
      if (req.method == 'POST' && route == 'pair/start') return await _pairStart(req);
      if (req.method == 'POST' && route == 'pair/finish') return await _pairFinish(req);
      if (req.method == 'POST' && route == 'pair/confirm') return await _pairConfirm(req);
      if (req.method == 'POST' && route == 'pair/cancel') return await _pairCancel(req);

      final peer = await _authenticate(req);
      if (peer == null) {
        await req.drain<void>();
        return await _reply(req, 401, {'status': 'unauthorized'});
      }

      if (req.method == 'POST' && route == 'unpair') return await _unpair(req, peer);
      if (req.method == 'POST' && route == 'backup/check') return await _backupCheck(req);
      if (req.method == 'POST' && route == 'backup/status') return await _backupRunStatus(req, peer);
      if (req.method == 'PUT' && seg.length == 4 && seg[1] == 'backup' && seg[2] == 'files') {
        return await _backupUpload(req, peer, seg[3].toLowerCase());
      }
      if (req.method == 'POST' && route == 'share/offer') return await _shareOffer(req, peer);
      if (seg.length == 4 && seg[1] == 'share') {
        if (req.method == 'PUT') return await _shareUpload(req, peer, seg[2], seg[3]);
        if (req.method == 'POST' && seg[3] == 'cancel') return await _shareCancel(req, peer, seg[2]);
      }

      await req.drain<void>();
      return await _reply(req, 404, {'status': 'not_found'});
    } catch (e) {
      delegate.log('Request error: $e');
      try {
        await _reply(req, 500, {'status': 'error', 'message': '$e'});
      } catch (_) {/* client already gone */}
    }
  }

  Future<void> _info(HttpRequest req) => _reply(req, 200, {
        'deviceId': identity.deviceId,
        'name': identity.name,
        'platform': identity.platform,
        'fingerprint': identity.fingerprint,
        'version': Protocol.version,
      });

  Future<PeerDevice?> _authenticate(HttpRequest req) async {
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (auth == null || !auth.startsWith('Bearer ')) return null;
    final peer = await db.peerByTokenHash(PairingCrypto.hashToken(auth.substring(7).trim()));
    if (peer == null) return null;
    final claimed = req.headers.value(Protocol.hDeviceId);
    if (claimed != null && claimed != peer.deviceId) return null;
    // Follow the peer if DHCP gave it a new address.
    final remote = req.connectionInfo?.remoteAddress.address;
    if (remote != null && remote != peer.host) {
      final moved = peer.copyWith(host: remote);
      await db.upsertPeer(moved);
      return moved;
    }
    return peer;
  }

  // ---- pairing ------------------------------------------------------------------

  bool _rateLimited(String remote) {
    final now = DateTime.now();
    final hits = (_failedPairAttempts[remote] ?? [])..removeWhere((t) => now.difference(t) > const Duration(minutes: 5));
    _failedPairAttempts[remote] = hits;
    return hits.length >= 5;
  }

  void _recordFailure(String remote) => (_failedPairAttempts[remote] ??= []).add(DateTime.now());

  Future<void> _pairStart(HttpRequest req) async {
    final remote = req.connectionInfo?.remoteAddress.address ?? '?';
    final body = await _json(req);
    if (_rateLimited(remote)) return _reply(req, 429, {'status': 'too_many_attempts'});

    final deviceId = body['deviceId'] as String? ?? '';
    final fingerprint = (body['fingerprint'] as String? ?? '').toLowerCase();
    final commitment = body['commit'] as String? ?? '';
    final port = body['port'] as int? ?? 0;
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(deviceId) ||
        !isSha256Hex(fingerprint) ||
        !isSha256Hex(commitment) ||
        port <= 0 ||
        port > 65535 ||
        deviceId == identity.deviceId) {
      return await _reply(req, 400, {'status': 'bad_request'});
    }

    final secret = body['qrSecret'] as String?;
    final viaQr = secret != null && delegate.consumeQrSecret(secret);
    if (secret != null && !viaQr) {
      _recordFailure(remote);
      return await _reply(req, 403, {'status': 'qr_expired'});
    }

    // Bound the number of concurrent sessions.
    _pairSessions.removeWhere((_, s) => DateTime.now().difference(s.created) > const Duration(minutes: 5));
    if (_pairSessions.length >= 8) _pairSessions.remove(_pairSessions.keys.first);

    final session = _PairSession(
      id: PairingCrypto.randomHex(16),
      deviceId: deviceId,
      name: _cleanName(body['name'] as String?),
      platform: _cleanPlatform(body['platform'] as String?),
      fingerprint: fingerprint,
      port: port,
      commitment: commitment,
      serverNonce: PairingCrypto.randomHex(32),
      viaQr: viaQr,
      remote: remote,
    );
    _pairSessions[session.id] = session;
    return await _reply(req, 200, {
      'session': session.id,
      'nonce': session.serverNonce,
      'deviceId': identity.deviceId,
      'name': identity.name,
      'platform': identity.platform,
    });
  }

  Future<void> _pairFinish(HttpRequest req) async {
    final body = await _json(req);
    final session = _pairSessions[body['session']];
    final nonce = body['nonce'] as String? ?? '';
    if (session == null || session.tokenForClient != null) return _reply(req, 404, {'status': 'no_session'});

    if (!PairingCrypto.verifyCommit(
      nonceHex: nonce,
      clientFp: session.fingerprint,
      serverFp: identity.fingerprint,
      commitment: session.commitment,
    )) {
      _pairSessions.remove(session.id);
      _recordFailure(session.remote);
      delegate.log('Pairing from ${session.name} rejected: commitment mismatch (possible interception)');
      return await _reply(req, 403, {'status': 'commit_mismatch'});
    }

    final code = PairingCrypto.sas(
      serverFp: identity.fingerprint,
      clientFp: session.fingerprint,
      clientNonce: nonce,
      serverNonce: session.serverNonce,
    );

    var approved = session.viaQr;
    if (!approved) {
      approved = await delegate
          .approvePairing(PairingPrompt(sessionId: session.id, name: session.name, platform: session.platform, code: code))
          .timeout(_approvalTimeout, onTimeout: () => false);
    }
    if (!approved || session.cancelled) {
      _pairSessions.remove(session.id);
      if (!session.cancelled) delegate.pairingCancelled(session.id);
      return await _reply(req, 403, {'status': Protocol.declined});
    }

    session.tokenForClient = PairingCrypto.newToken();
    return await _reply(req, 200, {'status': Protocol.accepted, 'token': session.tokenForClient});
  }

  /// The client's user confirmed the codes match; store the pairing.
  Future<void> _pairConfirm(HttpRequest req) async {
    final body = await _json(req);
    final session = _pairSessions.remove(body['session']);
    final token = body['token'] as String? ?? '';
    if (session == null || session.tokenForClient == null || token.length < 32) {
      return await _reply(req, 404, {'status': 'no_session'});
    }
    await db.upsertPeer(PeerDevice(
      deviceId: session.deviceId,
      name: session.name,
      platform: session.platform,
      fingerprint: session.fingerprint,
      host: session.remote,
      port: session.port,
      tokenOut: token,
      tokenInHash: PairingCrypto.hashToken(session.tokenForClient!),
    ));
    delegate.peersChanged();
    delegate.log('Paired with ${session.name}');
    return await _reply(req, 200, {'status': 'paired'});
  }

  Future<void> _pairCancel(HttpRequest req) async {
    final body = await _json(req);
    final session = _pairSessions.remove(body['session']);
    if (session != null) {
      session.cancelled = true;
      delegate.pairingCancelled(session.id);
    }
    return await _reply(req, 200, {'status': Protocol.cancelled});
  }

  Future<void> _unpair(HttpRequest req, PeerDevice peer) async {
    await req.drain<void>();
    await db.deletePeer(peer.deviceId);
    delegate.peersChanged();
    delegate.log('${peer.name} unpaired');
    return await _reply(req, 200, {'status': 'unpaired'});
  }

  // ---- backup -------------------------------------------------------------------

  Future<void> _backupCheck(HttpRequest req) async {
    final body = await _json(req);
    final results = <Map<String, Object?>>[];
    for (final f in (body['files'] as List).cast<Map<String, dynamic>>()) {
      final sha = (f['sha256'] as String).toLowerCase();
      results.add((await _backupStatus(sha, f['metaKey'] as String)).toJson());
    }
    return await _reply(req, 200, {'results': results});
  }

  /// Exists if a record matches by content hash OR filename|created|size and
  /// the file is still on disk. A file deleted from the backup folder is
  /// accepted again: backups should be restorable.
  Future<FileCheck> _backupStatus(String sha, String metaKey) async {
    final rec = await db.findReceived(sha256: sha, metaKey: metaKey);
    if (rec != null) {
      if (await File(storage.absoluteBackup(rec.relPath)).exists()) return FileCheck(sha, RemoteFileState.exists, 0);
      await db.deleteReceived(rec.sha256);
      totalReceived--;
    }
    final part = storage.backupPart(sha);
    if (await part.exists()) return FileCheck(sha, RemoteFileState.partial, await part.length());
    return FileCheck(sha, RemoteFileState.missing, 0);
  }

  Future<void> _backupRunStatus(HttpRequest req, PeerDevice peer) async {
    final status = BackupRunStatus.tryParse(await _json(req));
    if (status == null) return _reply(req, 400, {'status': 'bad_request'});
    delegate.backupStatus(peer, status);
    return _reply(req, 200, {'status': 'ok'});
  }

  Future<void> _backupUpload(HttpRequest req, PeerDevice peer, String sha) async {
    final h = req.headers;
    final size = int.tryParse(h.value(Protocol.hSize) ?? '');
    final offset = int.tryParse(h.value(Protocol.hOffset) ?? '0') ?? -1;
    final created = int.tryParse(h.value(Protocol.hCreated) ?? '') ?? 0;
    final filename = _decodedFilename(h.value(Protocol.hFilename));
    if (!isSha256Hex(sha) || size == null || size < 0 || offset < 0 || offset > size) {
      await req.drain<void>();
      return await _reply(req, 400, {'status': 'bad_request'});
    }
    if (!_inFlight.add(sha)) {
      await req.drain<void>();
      return await _reply(req, 423, {'status': Protocol.busy});
    }
    try {
      final metaKey = FileDescriptor.buildMetaKey(filename, created, size);
      final status = await _backupStatus(sha, metaKey);
      if (status.state == RemoteFileState.exists) {
        await req.drain<void>();
        skippedThisSession++;
        notifyListeners();
        return await _reply(req, 200, {'status': Protocol.skipped});
      }

      final part = storage.backupPart(sha);
      final result = await _receiveInto(req, part,
          offset: offset,
          size: size,
          sha: sha,
          onDisk: status.state == RemoteFileState.partial ? status.offset : 0,
          onProgress: (n) => delegate.backupFileProgress(peer, filename, n, size));
      if (result != null) return await _reply(req, result.$1, result.$2);

      final relPath = await storage.commitBackup(part, filename, created);
      await db.insertReceived(ReceivedFile(
        sha256: sha,
        metaKey: metaKey,
        filename: filename,
        relPath: relPath,
        size: size,
        createdAtMs: created,
        senderId: peer.deviceId,
      ));
      await storage.notifyMediaScanner(storage.absoluteBackup(relPath));
      storedThisSession++;
      totalReceived++;
      delegate.backupStored(peer, relPath);
      notifyListeners();
      return await _reply(req, 200, {'status': Protocol.stored, 'path': relPath});
    } finally {
      _inFlight.remove(sha);
    }
  }

  // ---- sharing ------------------------------------------------------------------

  Future<void> _shareOffer(HttpRequest req, PeerDevice peer) async {
    final body = await _json(req);
    final offerId = body['offerId'] as String? ?? '';
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(offerId)) return _reply(req, 400, {'status': 'bad_request'});

    final text = body['text'] as String?;
    if (text != null) {
      final clipped = text.length > 100000 ? text.substring(0, 100000) : text;
      delegate.textReceived(peer, clipped);
      await _record(TransferRecord(
        id: offerId,
        direction: TransferDirection.incoming,
        kind: TransferKind.text,
        peerId: peer.deviceId,
        peerName: peer.name,
        title: 'Text',
        detail: clipped,
        status: TransferStatus.done,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
      return await _reply(req, 200, {'status': Protocol.accepted});
    }

    final files = [
      for (final f in (body['files'] as List? ?? const []).cast<Map<String, dynamic>>())
        ShareFile.fromJson(f).let((s) => ShareFile(id: s.id, name: sanitizeRelativePath(s.name), size: s.size, sha256: s.sha256)),
    ];
    if (files.isEmpty ||
        files.length > 5000 ||
        files.any((f) => !isSha256Hex(f.sha256) || f.size < 0 || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(f.id))) {
      return await _reply(req, 400, {'status': 'bad_request'});
    }

    // Resuming an offer we already accepted (sender reconnected).
    final existing = _offers[offerId];
    if (existing != null && existing.from.deviceId == peer.deviceId) {
      return await _reply(req, 200, await _offerResponse(existing));
    }

    final accepted = peer.autoAccept ||
        await delegate
            .approveShare(ShareOfferPrompt(offerId: offerId, from: peer, files: files))
            .timeout(_approvalTimeout, onTimeout: () => false);
    if (!accepted) {
      await _record(TransferRecord(
        id: offerId,
        direction: TransferDirection.incoming,
        kind: TransferKind.files,
        peerId: peer.deviceId,
        peerName: peer.name,
        title: _filesTitle(files),
        size: files.fold(0, (a, f) => a + f.size),
        status: TransferStatus.declined,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
      return await _reply(req, 403, {'status': Protocol.declined});
    }

    final offer = _IncomingOffer(offerId, peer, {for (final f in files) f.id: f}, {for (final f in files) f.id});
    delegate.incomingStarted(offerId, peer, files);
    _offers.removeWhere((_, o) => DateTime.now().difference(o.created) > const Duration(hours: 24));
    _offers[offerId] = offer;
    return await _reply(req, 200, await _offerResponse(offer));
  }

  Future<Map<String, Object?>> _offerResponse(_IncomingOffer offer) async {
    final offsets = <String, int>{};
    for (final id in offer.accepted) {
      if (offer.savedPaths.containsKey(id)) {
        offsets[id] = offer.files[id]!.size;
        continue;
      }
      final part = storage.sharePart(offer.id, id);
      offsets[id] = await part.exists() ? await part.length() : 0;
    }
    return {'status': Protocol.accepted, 'accepted': offer.accepted.toList(), 'offsets': offsets};
  }

  Future<void> _shareUpload(HttpRequest req, PeerDevice peer, String offerId, String fileId) async {
    final offer = _offers[offerId];
    final file = offer?.files[fileId];
    if (offer == null || file == null || offer.from.deviceId != peer.deviceId || !offer.accepted.contains(fileId)) {
      await req.drain<void>();
      return await _reply(req, 404, {'status': 'no_offer'});
    }
    if (offer.savedPaths.containsKey(fileId)) {
      await req.drain<void>();
      return await _reply(req, 200, {'status': Protocol.stored});
    }
    final key = 'share:$offerId:$fileId';
    if (!_inFlight.add(key)) {
      await req.drain<void>();
      return await _reply(req, 423, {'status': Protocol.busy});
    }
    try {
      final offset = int.tryParse(req.headers.value(Protocol.hOffset) ?? '0') ?? -1;
      final part = storage.sharePart(offerId, fileId);
      final onDisk = await part.exists() ? await part.length() : 0;
      final before = onDisk;
      final result = await _receiveInto(req, part,
          offset: offset,
          size: file.size,
          sha: file.sha256,
          onDisk: onDisk,
          onProgress: (n) => delegate.incomingProgress(offerId, fileId, n));
      if (result != null) return await _reply(req, result.$1, result.$2);

      offer.receivedBytes += file.size - before;
      final path = await storage.commitShare(part, file.name, topDirs: offer.topDirs);
      offer.savedPaths[fileId] = path;
      await storage.notifyMediaScanner(path);
      if (offer.complete) {
        _offers.remove(offerId);
        await _record(TransferRecord(
          id: offerId,
          direction: TransferDirection.incoming,
          kind: TransferKind.files,
          peerId: peer.deviceId,
          peerName: peer.name,
          title: _filesTitle(offer.files.values.where((f) => offer.accepted.contains(f.id)).toList()),
          size: offer.totalBytes,
          status: TransferStatus.done,
          paths: offer.savedPaths.values.toList(),
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      return await _reply(req, 200, {'status': Protocol.stored});
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<void> _shareCancel(HttpRequest req, PeerDevice peer, String offerId) async {
    await req.drain<void>();
    final offer = _offers[offerId];
    if (offer != null && offer.from.deviceId == peer.deviceId) {
      _offers.remove(offerId);
      for (final id in offer.accepted) {
        final part = storage.sharePart(offerId, id);
        if (await part.exists()) await part.delete();
      }
      await _record(TransferRecord(
        id: offerId,
        direction: TransferDirection.incoming,
        kind: TransferKind.files,
        peerId: peer.deviceId,
        peerName: peer.name,
        title: _filesTitle(offer.files.values.toList()),
        size: offer.totalBytes,
        status: TransferStatus.cancelled,
        paths: offer.savedPaths.values.toList(),
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    return await _reply(req, 200, {'status': Protocol.cancelled});
  }

  // ---- shared upload plumbing -----------------------------------------------------

  /// Streams the body into [part] starting at [offset]. Returns null when the
  /// file is complete and verified, otherwise the (status, body) to send.
  Future<(int, Map<String, Object?>)?> _receiveInto(
    HttpRequest req,
    File part, {
    required int offset,
    required int size,
    required String sha,
    required int onDisk,
    void Function(int bytesOnDisk)? onProgress,
  }) async {
    if (offset < 0 || offset > size) {
      await req.drain<void>();
      return (400, {'status': 'bad_request'});
    }
    if (offset != onDisk && offset != 0) {
      await req.drain<void>();
      return (409, {'status': Protocol.offsetMismatch, 'offset': onDisk});
    }

    final sink = part.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
    var written = offset;
    var lastReport = DateTime.now();
    Object? streamError;
    try {
      await sink.addStream(req.map((chunk) {
        written += chunk.length;
        if (written > size) throw const FormatException('more data than declared');
        if (onProgress != null && DateTime.now().difference(lastReport).inMilliseconds > 250) {
          lastReport = DateTime.now();
          onProgress(written);
        }
        return chunk;
      }));
    } catch (e) {
      streamError = e;
    }
    try {
      await sink.close();
    } catch (_) {}

    if (streamError is FormatException) {
      await part.delete();
      return (422, {'status': Protocol.sizeMismatch});
    }
    if (streamError != null) {
      // Connection dropped mid-file; keep the bytes for resume.
      return (499, {'status': Protocol.partial, 'offset': await part.length()});
    }

    final received = await part.length();
    if (received < size) return (200, {'status': Protocol.partial, 'offset': received});
    if (received > size) {
      await part.delete();
      return (422, {'status': Protocol.sizeMismatch});
    }
    if (await sha256OfFile(part.path) != sha) {
      await part.delete();
      delegate.log('Discarded a file that failed its integrity check');
      return (422, {'status': Protocol.hashMismatch});
    }
    onProgress?.call(size);
    return null;
  }

  // ---- helpers ------------------------------------------------------------------

  Future<void> _record(TransferRecord r) async {
    await db.addTransfer(r);
    delegate.incomingFinished(r);
  }

  String _filesTitle(List<ShareFile> files) => transferTitle([for (final f in files) f.name]);

  String _decodedFilename(String? raw) {
    try {
      return sanitizeFilename(Uri.decodeComponent(raw ?? ''));
    } catch (_) {
      return 'file';
    }
  }

  static String _cleanName(String? raw) {
    final s = (raw ?? '').replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    if (s.isEmpty) return 'Unknown device';
    return s.length > 60 ? s.substring(0, 60) : s;
  }

  static String _cleanPlatform(String? raw) =>
      const {'ios', 'android', 'macos', 'windows', 'linux'}.contains(raw) ? raw! : 'unknown';

  Future<Map<String, dynamic>> _json(HttpRequest req) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBodyBytes) throw const FormatException('request body too large');
    }
    if (bytes.isEmpty) return {};
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<void> _reply(HttpRequest req, int status, Map<String, Object?> body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
