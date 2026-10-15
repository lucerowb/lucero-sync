import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/db.dart';
import '../core/hashing.dart';
import '../core/identity.dart';
import '../core/models.dart';
import '../core/protocol.dart';
import 'receiver_storage.dart';

/// Lightweight HTTP receiver built on dart:io. See [Protocol] for the API.
class ReceiverServer extends ChangeNotifier {
  ReceiverServer(this._db, this._identity);

  final AppDatabase _db;
  final DeviceIdentity _identity;

  HttpServer? _server;
  ReceiverStorage? _storage;
  final _inFlight = <String>{};

  final List<String> log = [];
  int storedThisSession = 0;
  int skippedThisSession = 0;
  int totalReceived = 0;

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  ReceiverStorage? get storage => _storage;

  Future<void> start({int port = Protocol.defaultPort}) async {
    if (_server != null) return;
    _storage = await ReceiverStorage.open();
    totalReceived = await _db.receivedCount();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    server.idleTimeout = const Duration(seconds: 30);
    _server = server;
    server.listen((req) => unawaited(_handle(req)));
    _log('Listening on port ${server.port} → ${_storage!.displayLocation}');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _log('Stopped');
  }

  // ---- routing -----------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    try {
      final seg = req.uri.pathSegments;
      if (req.method == 'GET' && _path(seg, ['v1', 'info'])) {
        return await _json(req, 200, {
          'deviceId': _identity.deviceId,
          'name': _identity.name,
          'version': Protocol.version,
        });
      }

      if (req.headers.value(Protocol.hToken) != _identity.pin) {
        await req.drain<void>();
        return await _json(req, 401, {'status': 'unauthorized'});
      }

      if (req.method == 'POST' && _path(seg, ['v1', 'check'])) return await _handleCheck(req);
      if (req.method == 'PUT' && seg.length == 3 && seg[0] == 'v1' && seg[1] == 'files') {
        return await _handleUpload(req, seg[2].toLowerCase());
      }

      await req.drain<void>();
      return await _json(req, 404, {'status': 'not_found'});
    } catch (e) {
      _log('Error: $e');
      try {
        await _json(req, 500, {'status': 'error', 'message': '$e'});
      } catch (_) {/* client already gone */}
    }
  }

  // ---- POST /v1/check ------------------------------------------------------------

  Future<void> _handleCheck(HttpRequest req) async {
    final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
    final results = <Map<String, Object?>>[];
    for (final f in (body['files'] as List).cast<Map<String, dynamic>>()) {
      final sha = (f['sha256'] as String).toLowerCase();
      final check = await _statusFor(sha, f['metaKey'] as String);
      results.add(check.toJson());
    }
    await _json(req, 200, {'results': results});
  }

  /// The dedup decision. A file "exists" if a record matches by content hash
  /// OR by filename|created|size, *and* the file is still on disk. If the user
  /// deleted it from the folder we forget the record and accept it again —
  /// this is a backup, so a missing file should be restorable.
  Future<FileCheck> _statusFor(String sha, String metaKey) async {
    final rec = await _db.findReceived(sha256: sha, metaKey: metaKey);
    if (rec != null) {
      if (await File(_storage!.absolute(rec.relPath)).exists()) {
        return FileCheck(sha, RemoteFileState.exists, 0);
      }
      await _db.deleteReceived(rec.sha256);
      totalReceived--;
    }
    final part = _storage!.partFile(sha);
    if (await part.exists()) return FileCheck(sha, RemoteFileState.partial, await part.length());
    return FileCheck(sha, RemoteFileState.missing, 0);
  }

  // ---- PUT /v1/files/<sha256> ----------------------------------------------------

  Future<void> _handleUpload(HttpRequest req, String sha) async {
    final h = req.headers;
    final size = int.tryParse(h.value(Protocol.hSize) ?? '');
    final offset = int.tryParse(h.value(Protocol.hOffset) ?? '0') ?? -1;
    final created = int.tryParse(h.value(Protocol.hCreated) ?? '') ?? 0;
    final senderId = h.value(Protocol.hDeviceId) ?? 'unknown';
    String filename;
    try {
      filename = sanitizeFilename(Uri.decodeComponent(h.value(Protocol.hFilename) ?? ''));
    } catch (_) {
      filename = 'file';
    }

    if (!isSha256Hex(sha) || size == null || size < 0 || offset < 0 || offset > size) {
      await req.drain<void>();
      return await _json(req, 400, {'status': 'bad_request'});
    }

    // One writer per file; a second concurrent upload of the same hash waits.
    if (!_inFlight.add(sha)) {
      await req.drain<void>();
      return await _json(req, 423, {'status': Protocol.busy});
    }

    try {
      final metaKey = FileDescriptor.buildMetaKey(filename, created, size);

      // Pre-check on the transfer request itself (the sender also calls
      // /v1/check first, so this only fires on races).
      final status = await _statusFor(sha, metaKey);
      if (status.state == RemoteFileState.exists) {
        await req.drain<void>();
        skippedThisSession++;
        _log('Skip $filename (already have it)');
        return await _json(req, 200, {'status': Protocol.skipped});
      }

      final onDisk = status.state == RemoteFileState.partial ? status.offset : 0;
      if (offset != onDisk && offset != 0) {
        await req.drain<void>();
        return await _json(req, 409, {'status': Protocol.offsetMismatch, 'offset': onDisk});
      }

      // Append (resume) or truncate (fresh start).
      final part = _storage!.partFile(sha);
      final sink = part.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
      Object? streamError;
      try {
        await sink.addStream(req);
      } catch (e) {
        streamError = e;
      }
      try {
        await sink.close();
      } catch (_) {}

      if (streamError != null) {
        // Connection dropped mid-file. Bytes so far stay in .part for resume.
        _log('Interrupted $filename at ${await part.length()} / $size bytes');
        return;
      }

      final received = await part.length();
      if (received < size) {
        return await _json(req, 200, {'status': Protocol.partial, 'offset': received});
      }
      if (received > size) {
        await part.delete();
        return await _json(req, 422, {'status': Protocol.sizeMismatch});
      }

      final actual = await sha256OfFile(part.path);
      if (actual != sha) {
        await part.delete();
        _log('Hash mismatch for $filename — discarded');
        return await _json(req, 422, {'status': Protocol.hashMismatch});
      }

      final relPath = await _storage!.commit(part, filename, created);
      await _db.insertReceived(ReceivedFile(
        sha256: sha,
        metaKey: metaKey,
        filename: filename,
        relPath: relPath,
        size: size,
        createdAtMs: created,
        senderId: senderId,
      ));
      await _storage!.notifyMediaScanner(relPath);

      storedThisSession++;
      totalReceived++;
      _log('Stored $relPath');
      return await _json(req, 200, {'status': Protocol.stored, 'path': relPath});
    } finally {
      _inFlight.remove(sha);
    }
  }

  // ---- helpers ---------------------------------------------------------------------

  bool _path(List<String> seg, List<String> expected) => listEquals(seg, expected);

  Future<void> _json(HttpRequest req, int status, Map<String, Object?> body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }

  void _log(String line) {
    final t = DateTime.now();
    log.insert(0, '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}  $line');
    if (log.length > 200) log.removeLast();
    notifyListeners();
  }
}
