import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app/live_transfers.dart';
import '../core/models.dart';
import '../core/version.dart';
import '../security/pairing_crypto.dart';
import '../storage/storage.dart';
import 'http_util.dart';

/// What the extension API needs from the rest of the app.
abstract class LocalApiHost {
  String get deviceName;
  List<PeerDevice> get peers;
  bool isOnline(PeerDevice peer);
  LiveSummary get liveSummary;

  /// Starts sending; returns an id the extension can match in `live`.
  String sendTextTo(PeerDevice peer, String text);
  String sendFilesTo(PeerDevice peer, List<String> paths);

  Future<List<String>> loadExtensionTokenHashes();
  Future<void> saveExtensionTokenHashes(List<String> hashes);
}

/// Loopback-only HTTP API for the Lucero Sync browser extension (desktop).
///
/// Bound to 127.0.0.1, so nothing on the network can reach it. Against other
/// local software and web pages it requires a bearer token, issued in
/// exchange for a short-lived code shown in Settings; browser requests are
/// only accepted from extension origins, and the Host header must be the
/// loopback address (stops DNS-rebinding pages).
class LocalApi extends ChangeNotifier {
  LocalApi(this.host, {required this.tempDir});

  final LocalApiHost host;
  final Directory tempDir;

  static const firstPort = 47865;
  static const lastPort = 47869;

  HttpServer? _server;
  int? get port => _server?.port;
  bool get isRunning => _server != null;

  /// Shown in Settings while a browser is being connected.
  String? connectCode;
  DateTime? _codeIssued;
  final _limiter = FailureLimiter();
  List<String> _tokenHashes = [];
  int get connectedCount => _tokenHashes.length;

  Future<void> start() async {
    if (_server != null) return;
    _tokenHashes = await host.loadExtensionTokenHashes();
    for (var port = firstPort; port <= lastPort; port++) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        break;
      } on SocketException {
        continue;
      }
    }
    final server = _server;
    if (server == null) throw const SocketException('No free port for the browser extension API');
    server.listen((req) => unawaited(_handle(req)));
    unawaited(_cleanTemp());
    notifyListeners();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    notifyListeners();
  }

  String issueCode() {
    connectCode = (Random.secure().nextInt(900000) + 100000).toString();
    _codeIssued = DateTime.now();
    notifyListeners();
    return connectCode!;
  }

  Future<void> disconnectAll() async {
    _tokenHashes = [];
    await host.saveExtensionTokenHashes(_tokenHashes);
    notifyListeners();
  }

  // ---- HTTP -----------------------------------------------------------------------

  static bool _extensionOrigin(String o) => o.startsWith('chrome-extension://') || o.startsWith('moz-extension://');

  Future<void> _handle(HttpRequest req) async {
    final origin = req.headers.value('origin');
    final hostHeader = req.headers.host ?? '';
    if ((origin != null && !_extensionOrigin(origin)) || !(hostHeader == '127.0.0.1' || hostHeader == 'localhost')) {
      await req.drain<void>();
      return await replyJson(req, 403, {'error': 'forbidden'});
    }
    if (origin != null) {
      req.response.headers
        ..set('Access-Control-Allow-Origin', origin)
        ..set('Vary', 'Origin')
        ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type')
        ..set('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
        ..set('Access-Control-Max-Age', '600');
    }
    if (req.method == 'OPTIONS') {
      await req.drain<void>();
      req.response.statusCode = 204;
      return await req.response.close();
    }

    final seg = req.uri.pathSegments;
    if (seg.length < 3 || seg[0] != 'ext' || seg[1] != 'v1') {
      await req.drain<void>();
      return await replyJson(req, 404, {'error': 'not_found'});
    }
    final route = seg.skip(2).join('/');
    try {
      if (req.method == 'GET' && route == 'hello') {
        await req.drain<void>();
        return await replyJson(req, 200, {'app': 'lucero-sync', 'version': appVersion, 'name': host.deviceName});
      }
      if (req.method == 'POST' && route == 'connect') return await _connect(req);

      final token = bearerToken(req);
      if (token == null || !_tokenHashes.any((h) => PairingCrypto.constantTimeEquals(h, PairingCrypto.hashToken(token)))) {
        await req.drain<void>();
        return await replyJson(req, 401, {'error': 'unauthorized'});
      }
      switch ((req.method, route)) {
        case ('GET', 'devices'):
          await req.drain<void>();
          return await replyJson(req, 200, {
            'devices': [
              for (final d in host.peers)
                {'id': d.deviceId, 'name': d.name, 'platform': d.platform, 'online': host.isOnline(d)},
            ],
          });
        case ('GET', 'live'):
          await req.drain<void>();
          return await replyJson(req, 200, host.liveSummary.toJson());
        case ('POST', 'send'):
          final body = await readJson(req, maxBytes: 256 * 1024);
          final peer = _peer('${body['deviceId']}');
          final text = '${body['text'] ?? ''}';
          if (peer == null) return await replyJson(req, 404, {'error': 'no_device'});
          if (text.trim().isEmpty) return await replyJson(req, 400, {'error': 'empty'});
          return await replyJson(req, 200, {'status': 'sent', 'id': host.sendTextTo(peer, text)});
        case ('PUT', 'file'):
          return await _file(req);
        case ('POST', 'disconnect'):
          await req.drain<void>();
          _tokenHashes.removeWhere((h) => PairingCrypto.constantTimeEquals(h, PairingCrypto.hashToken(token)));
          await host.saveExtensionTokenHashes(_tokenHashes);
          notifyListeners();
          return await replyJson(req, 200, {});
      }
      await req.drain<void>();
      return await replyJson(req, 404, {'error': 'not_found'});
    } on FormatException {
      return await replyJson(req, 400, {'error': 'bad_request'});
    }
  }

  PeerDevice? _peer(String id) => host.peers.where((d) => d.deviceId == id).firstOrNull;

  Future<void> _connect(HttpRequest req) async {
    final body = await readJson(req, maxBytes: 1024);
    if (_limiter.blocked('connect')) return await replyJson(req, 429, {'error': 'rate_limited'});
    final fresh = _codeIssued != null && DateTime.now().difference(_codeIssued!) < const Duration(minutes: 10);
    final attempt = '${body['code'] ?? ''}'.trim();
    if (connectCode == null || !fresh || !PairingCrypto.constantTimeEquals(attempt, connectCode!)) {
      _limiter.fail('connect');
      return await replyJson(req, 401, {'error': 'bad_code'});
    }
    connectCode = null; // one-time
    final token = PairingCrypto.newToken();
    _tokenHashes = [..._tokenHashes, PairingCrypto.hashToken(token)];
    await host.saveExtensionTokenHashes(_tokenHashes);
    notifyListeners();
    return await replyJson(req, 200, {'token': token});
  }

  Future<void> _file(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final peer = _peer(q['deviceId'] ?? '');
    if (peer == null) {
      await req.drain<void>();
      return await replyJson(req, 404, {'error': 'no_device'});
    }
    final dir = Directory(p.join(tempDir.path, PairingCrypto.randomHex(8)));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, sanitizeFilename(q['name'] ?? 'file')));
    await req.cast<List<int>>().pipe(file.openWrite());
    return await replyJson(req, 200, {'status': 'sending', 'id': host.sendFilesTo(peer, [file.path])});
  }

  /// Files the extension handed over are copies; drop them after a day.
  Future<void> _cleanTemp() async {
    try {
      if (!await tempDir.exists()) return;
      await for (final e in tempDir.list()) {
        final age = DateTime.now().difference((await e.stat()).modified);
        if (age > const Duration(days: 1)) await e.delete(recursive: true);
      }
    } catch (_) {}
  }
}
