import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app/live_transfers.dart';
import '../core/models.dart';
import '../security/pairing_crypto.dart';
import '../storage/storage.dart';
import 'http_util.dart';

/// What web access needs from the rest of the app.
abstract class WebAccessHost {
  String get deviceName;
  String get platform;
  Storage get storage;
  LiveSummary get liveSummary;

  void webUploadStarted(String id, String from, int total, String name);
  void webUploadProgress(String id, int received, int total);
  Future<void> webUploadFinished(TransferRecord record);
  void webText(String from, String text);
}

class WebSession {
  WebSession(this.token, this.label, this.address);
  final String token;
  final String label;
  final String address;
  final DateTime created = DateTime.now();
  DateTime lastSeen = DateTime.now();
}

class OutboxItem {
  OutboxItem(this.id, this.path, this.name, this.size);
  final String id;
  final String path;
  final String name;
  final int size;
}

/// "Web access": any browser on the network can open `https://<ip>:<port>/`,
/// sign in with a 6-digit code shown on this device, send files and text
/// here, and download files this device offers.
///
/// Served by the same TLS server as the app protocol. Browsers can't pin our
/// self-signed certificate, so they show a warning once; the code (rate
/// limited, rotated after repeated failures) is what keeps other people on
/// the network out. Off by default; turning it off ends every session.
class WebAccess extends ChangeNotifier {
  WebAccess(this.host, {required this.loadPage});

  final WebAccessHost host;
  final Future<String> Function() loadPage;

  bool enabled = false;
  String code = '';
  final sessions = <String, WebSession>{};
  final outbox = <OutboxItem>[];

  final _limiter = FailureLimiter();
  int _globalFailures = 0;
  String? _page;

  static const _sessionIdle = Duration(hours: 12);
  static const _maxUpload = 64 * 1024 * 1024 * 1024; // 64 GB

  void setEnabled(bool on) {
    enabled = on;
    if (on) {
      newCode();
    } else {
      sessions.clear();
      code = '';
    }
    notifyListeners();
  }

  void newCode() {
    code = (Random.secure().nextInt(900000) + 100000).toString();
    _globalFailures = 0;
    notifyListeners();
  }

  void endSession(String token) {
    sessions.remove(token);
    notifyListeners();
  }

  void addToOutbox(List<String> paths) {
    for (final path in paths) {
      final f = File(path);
      if (!f.existsSync()) continue;
      outbox.add(OutboxItem(PairingCrypto.randomHex(8), path, p.basename(path), f.lengthSync()));
    }
    notifyListeners();
  }

  void removeFromOutbox(String id) {
    outbox.removeWhere((o) => o.id == id);
    notifyListeners();
  }

  /// Handles `/` and `/web/...`. Returns false for paths it doesn't own.
  Future<bool> handle(HttpRequest req) async {
    final seg = req.uri.pathSegments;
    final isPage = req.method == 'GET' && (seg.isEmpty || (seg.length == 1 && (seg.first == 'web' || seg.first == 'index.html')));
    if (!isPage && (seg.isEmpty || seg.first != 'web')) return false;

    if (isPage) {
      await _servePage(req);
      return true;
    }
    if (!enabled) {
      await req.drain<void>();
      await replyJson(req, 403, {'error': 'web_access_off'});
      return true;
    }
    final route = seg.skip(1).join('/');
    try {
      switch ((req.method, route)) {
        case ('GET', 'api/hello'):
          await replyJson(req, 200, {'name': host.deviceName, 'platform': host.platform});
        case ('POST', 'api/login'):
          await _login(req);
        default:
          final session = _session(req);
          if (session == null) {
            await req.drain<void>();
            await replyJson(req, 401, {'error': 'unauthorized'});
          } else {
            await _authed(req, route, session);
          }
      }
    } on FormatException {
      await replyJson(req, 400, {'error': 'bad_request'});
    }
    return true;
  }

  Future<void> _servePage(HttpRequest req) async {
    await req.drain<void>();
    final html = enabled
        ? (_page ??= await loadPage())
        : '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            '<title>Lucero Sync</title><body style="background:#100d0a;color:#f2e8d8;font:16px system-ui;padding:40px">'
            '<h1 style="font-weight:600">Web access is off</h1>'
            '<p>Turn it on in Lucero Sync under <b>Settings › Web access</b>, then reload this page.</p>';
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('Content-Security-Policy',
          "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'")
      ..headers.set('X-Frame-Options', 'DENY')
      ..headers.set('Referrer-Policy', 'no-referrer')
      ..write(html);
    await req.response.close();
  }

  WebSession? _session(HttpRequest req) {
    final token = bearerToken(req) ?? req.uri.queryParameters['t'];
    if (token == null) return null;
    sessions.removeWhere((_, s) => DateTime.now().difference(s.lastSeen) > _sessionIdle);
    final match = sessions.values.where((s) => PairingCrypto.constantTimeEquals(s.token, token)).firstOrNull;
    match?.lastSeen = DateTime.now();
    return match;
  }

  Future<void> _login(HttpRequest req) async {
    final remote = req.connectionInfo?.remoteAddress.address ?? '?';
    final body = await readJson(req, maxBytes: 1024);
    if (_limiter.blocked(remote)) return await replyJson(req, 429, {'error': 'rate_limited'});
    final attempt = '${body['code'] ?? ''}'.trim();
    if (code.isEmpty || !PairingCrypto.constantTimeEquals(attempt, code)) {
      _limiter.fail(remote);
      // Many failures from anywhere: someone may be guessing from several
      // addresses. Rotate so earlier guesses are worthless.
      if (++_globalFailures >= 20) newCode();
      return await replyJson(req, 401, {'error': 'bad_code'});
    }
    _limiter.clear(remote);
    final session = WebSession(PairingCrypto.randomHex(16), describeUserAgent(req.headers.value('user-agent')), remote);
    sessions[session.token] = session;
    notifyListeners();
    await replyJson(req, 200, {'token': session.token, 'name': host.deviceName, 'platform': host.platform});
  }

  Future<void> _authed(HttpRequest req, String route, WebSession s) async {
    if (req.method == 'POST' && route == 'api/logout') {
      await req.drain<void>();
      endSession(s.token);
      return await replyJson(req, 200, {});
    }
    if (req.method == 'GET' && route == 'api/state') {
      return await replyJson(req, 200, {
        'name': host.deviceName,
        'platform': host.platform,
        'live': host.liveSummary.toJson(),
        'outbox': [
          for (final o in outbox)
            {'id': o.id, 'name': o.name, 'size': o.size, 'url': '/web/api/outbox/${o.id}?t=${s.token}'},
        ],
      });
    }
    if (req.method == 'POST' && route == 'api/text') {
      final body = await readJson(req, maxBytes: 256 * 1024);
      final text = '${body['text'] ?? ''}';
      if (text.trim().isEmpty) return await replyJson(req, 400, {'error': 'empty'});
      host.webText(s.label, text.length > 100000 ? text.substring(0, 100000) : text);
      return await replyJson(req, 200, {'status': 'accepted'});
    }
    if (req.method == 'PUT' && route == 'api/upload') return await _upload(req, s);
    final seg = req.uri.pathSegments;
    if (req.method == 'GET' && seg.length == 4 && seg[2] == 'outbox') return await _download(req, seg[3]);
    await req.drain<void>();
    return await replyJson(req, 404, {'error': 'not_found'});
  }

  Future<void> _upload(HttpRequest req, WebSession s) async {
    final q = req.uri.queryParameters;
    final name = sanitizeFilename(q['name'] ?? 'file');
    final size = int.tryParse(q['size'] ?? '');
    if (size == null || size < 0) {
      await req.drain<void>();
      return await replyJson(req, 400, {'error': 'bad_request'});
    }
    if (size > _maxUpload) {
      await req.drain<void>();
      return await replyJson(req, 413, {'error': 'too_large'});
    }

    final id = PairingCrypto.randomHex(16);
    final part = host.storage.sharePart('web$id', 'f');
    await part.parent.create(recursive: true);
    host.webUploadStarted(id, s.label, size, name);

    final sink = part.openWrite();
    var written = 0;
    var last = DateTime.now();
    Object? error;
    try {
      await sink.addStream(req.map((chunk) {
        written += chunk.length;
        if (written > size) throw const FormatException('more data than declared');
        if (DateTime.now().difference(last).inMilliseconds > 250) {
          last = DateTime.now();
          host.webUploadProgress(id, written, size);
        }
        return chunk;
      }));
    } catch (e) {
      error = e;
    }
    try {
      await sink.close();
    } catch (e) {
      error ??= e;
    }

    Future<void> finish(TransferStatus status, {List<String> paths = const []}) => host.webUploadFinished(TransferRecord(
          id: id,
          direction: TransferDirection.incoming,
          kind: TransferKind.files,
          peerId: 'web',
          peerName: s.label,
          title: name,
          size: size,
          status: status,
          paths: paths,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ));

    if (error != null || written != size) {
      if (await part.exists()) await part.delete();
      await finish(TransferStatus.failed);
      final noSpace = error is FileSystemException && (error.osError?.errorCode == 28 || error.osError?.errorCode == 112);
      if (noSpace) return await replyJson(req, 507, {'error': 'no_space'});
      // The browser may already be gone; replying is best effort.
      try {
        return await replyJson(req, 400, {'error': 'incomplete'});
      } catch (_) {
        return;
      }
    }
    final path = await host.storage.commitShare(part, name);
    await host.storage.notifyMediaScanner(path);
    await finish(TransferStatus.done, paths: [path]);
    await replyJson(req, 200, {'status': 'stored', 'name': p.basename(path)});
  }

  Future<void> _download(HttpRequest req, String id) async {
    await req.drain<void>();
    final item = outbox.where((o) => o.id == id).firstOrNull;
    final file = item == null ? null : File(item.path);
    if (item == null || file == null || !await file.exists()) return await replyJson(req, 404, {'error': 'not_found'});
    final encoded = Uri.encodeComponent(item.name);
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.binary
      ..headers.contentLength = await file.length()
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('Content-Disposition', "attachment; filename=\"${item.name.replaceAll('"', '')}\"; filename*=UTF-8''$encoded");
    await req.response.addStream(file.openRead());
    await req.response.close();
  }
}
