import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lucero_sync/app/live_transfers.dart';
import 'package:lucero_sync/core/models.dart';
import 'package:lucero_sync/net/local_api.dart';
import 'package:lucero_sync/net/web_access.dart';
import 'package:lucero_sync/storage/storage.dart';

class _WebHost implements WebAccessHost {
  _WebHost(this.storage);
  @override
  final Storage storage;
  final texts = <String>[];
  final finished = <TransferRecord>[];

  @override
  String get deviceName => 'Test Mac';
  @override
  String get platform => 'macos';
  @override
  LiveSummary get liveSummary => const LiveSummary([]);
  @override
  void webUploadStarted(String id, String from, int total, String name) {}
  @override
  void webUploadProgress(String id, int received, int total) {}
  @override
  Future<void> webUploadFinished(TransferRecord record) async => finished.add(record);
  @override
  void webText(String from, String text) => texts.add(text);
}

class _ApiHost implements LocalApiHost {
  final sentText = <String>[];
  final sentFiles = <String>[];
  List<String> hashes = [];
  final peer = const PeerDevice(
    deviceId: 'abc',
    name: 'Pixel',
    platform: 'android',
    fingerprint: '',
    host: '127.0.0.1',
    port: 1,
    tokenOut: '',
    tokenInHash: '',
  );

  @override
  String get deviceName => 'Test Mac';
  @override
  List<PeerDevice> get peers => [peer];
  @override
  bool isOnline(PeerDevice peer) => true;
  @override
  LiveSummary get liveSummary => const LiveSummary([]);
  @override
  String sendTextTo(PeerDevice peer, String text) {
    sentText.add(text);
    return 'id1';
  }

  @override
  String sendFilesTo(PeerDevice peer, List<String> paths) {
    sentFiles.addAll(paths);
    return 'id2';
  }

  @override
  Future<List<String>> loadExtensionTokenHashes() async => hashes;
  @override
  Future<void> saveExtensionTokenHashes(List<String> h) async => hashes = h;
}

Future<(int, Map<String, dynamic>)> call(String method, Uri uri,
    {Object? json, List<int>? bytes, String? token, String? origin}) async {
  final c = HttpClient();
  try {
    final req = await c.openUrl(method, uri);
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (origin != null) req.headers.set('origin', origin);
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    if (bytes != null) req.add(bytes);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (res.statusCode, body.isEmpty || !body.startsWith('{') ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>);
  } finally {
    c.close();
  }
}

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('lucero_browser'));
  tearDown(() async => root.delete(recursive: true));

  group('web access', () {
    late WebAccess web;
    late _WebHost host;
    late HttpServer server;
    late Uri base;

    setUp(() async {
      final storage = Storage(backupsRoot: Directory('${root.path}/b'), receivedRoot: Directory('${root.path}/r'));
      await storage.ensureDirs();
      host = _WebHost(storage);
      web = WebAccess(host, loadPage: () async => '<html>page</html>');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (!await web.handle(req)) {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
      base = Uri.parse('http://127.0.0.1:${server.port}');
    });
    tearDown(() => server.close(force: true));

    test('is closed until turned on', () async {
      expect((await call('POST', base.resolve('/web/api/login'), json: {'code': '000000'})).$1, 403);
    });

    test('code login, upload, text and download', () async {
      web.setEnabled(true);
      expect((await call('POST', base.resolve('/web/api/login'), json: {'code': 'nope'})).$1, 401);
      final (status, login) = await call('POST', base.resolve('/web/api/login'), json: {'code': web.code});
      expect(status, 200);
      final token = login['token'] as String;

      expect((await call('GET', base.resolve('/web/api/state'))).$1, 401);
      final data = List.generate(5000, (i) => i % 251);
      final up = await call('PUT', base.resolve('/web/api/upload?name=..%2Fevil.txt&size=5000'), bytes: data, token: token);
      expect(up.$1, 200);
      final saved = File('${root.path}/r/evil.txt');
      expect(await saved.readAsBytes(), data, reason: 'traversal stripped, content intact');
      expect(host.finished.single.status, TransferStatus.done);

      expect((await call('PUT', base.resolve('/web/api/upload?name=x&size=10'), bytes: [1, 2, 3], token: token)).$1, 400);

      await call('POST', base.resolve('/web/api/text'), json: {'text': 'hello'}, token: token);
      expect(host.texts, ['hello']);

      web.addToOutbox([saved.path]);
      final state = (await call('GET', base.resolve('/web/api/state'), token: token)).$2;
      final url = (state['outbox'] as List).single['url'] as String;
      final c = HttpClient();
      final res = await (await c.getUrl(base.resolve(url))).close();
      expect(await res.fold<List<int>>([], (a, b) => a..addAll(b)), data);
      c.close();

      web.setEnabled(false);
      expect((await call('GET', base.resolve('/web/api/state'), token: token)).$1, 403);
    });

    test('rate limits code guessing', () async {
      web.setEnabled(true);
      for (var i = 0; i < 5; i++) {
        await call('POST', base.resolve('/web/api/login'), json: {'code': '000000'});
      }
      expect((await call('POST', base.resolve('/web/api/login'), json: {'code': web.code})).$1, 429);
    });
  });

  group('extension API', () {
    late LocalApi api;
    late _ApiHost host;
    late Uri base;

    setUp(() async {
      host = _ApiHost();
      api = LocalApi(host, tempDir: Directory('${root.path}/tmp'));
      await api.start();
      base = Uri.parse('http://127.0.0.1:${api.port}/ext/v1/');
    });
    tearDown(() => api.stop());

    test('connect with a one-time code, then send', () async {
      expect((await call('GET', base.resolve('hello'))).$2['app'], 'lucero-sync');
      expect((await call('GET', base.resolve('devices'))).$1, 401);

      final code = api.issueCode();
      const ext = 'chrome-extension://abcdef';
      final (status, body) = await call('POST', base.resolve('connect'), json: {'code': code}, origin: ext);
      expect(status, 200);
      final token = body['token'] as String;
      expect((await call('POST', base.resolve('connect'), json: {'code': code})).$1, 401, reason: 'one-time');

      final devices = (await call('GET', base.resolve('devices'), token: token, origin: ext)).$2['devices'] as List;
      expect(devices.single['name'], 'Pixel');
      await call('POST', base.resolve('send'), json: {'deviceId': 'abc', 'text': 'https://example.com'}, token: token);
      expect(host.sentText, ['https://example.com']);
      await call('PUT', base.resolve('file?deviceId=abc&name=pic.png'), bytes: [1, 2, 3], token: token);
      expect(File(host.sentFiles.single).readAsBytesSync(), [1, 2, 3]);
    });

    test('web pages are refused even with a token', () async {
      final code = api.issueCode();
      final token = (await call('POST', base.resolve('connect'), json: {'code': code})).$2['token'] as String;
      expect((await call('GET', base.resolve('devices'), token: token, origin: 'https://evil.example')).$1, 403);
    });
  });
}
