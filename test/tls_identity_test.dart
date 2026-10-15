import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lucero_sync/security/tls_identity.dart';

/// Client that only trusts a server presenting [expectedFp].
HttpClient pinnedClient(String expectedFp) => HttpClient(context: SecurityContext(withTrustedRoots: false))
  ..badCertificateCallback = (cert, host, port) => fingerprintOf(cert.der) == expectedFp;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('lucero_tls'));
  tearDown(() async => tmp.delete(recursive: true));

  test('generates a persistent identity with a stable fingerprint', () async {
    final a = await TlsIdentity.loadOrCreate(tmp, deviceId: 'dev1');
    final b = await TlsIdentity.loadOrCreate(tmp, deviceId: 'dev1');
    expect(a.fingerprint, hasLength(64));
    expect(b.fingerprint, a.fingerprint);
  });

  test('pinned client accepts the right server and rejects an impostor', () async {
    final real = await TlsIdentity.loadOrCreate(Directory('${tmp.path}/real'), deviceId: 'real');
    final fake = await TlsIdentity.loadOrCreate(Directory('${tmp.path}/fake'), deviceId: 'fake');

    Future<HttpServer> serve(TlsIdentity id) async {
      final s = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, id.serverContext());
      s.listen((r) => r.response
        ..write('hello')
        ..close());
      return s;
    }

    final realServer = await serve(real);
    final fakeServer = await serve(fake);
    final client = pinnedClient(real.fingerprint);

    final ok = await (await client.getUrl(Uri.parse('https://127.0.0.1:${realServer.port}/'))).close();
    expect(fingerprintOf(ok.certificate!.der), real.fingerprint);
    expect(await ok.transform(utf8.decoder).join(), 'hello');

    await expectLater(
      () async => (await client.getUrl(Uri.parse('https://127.0.0.1:${fakeServer.port}/'))).close(),
      throwsA(isA<HandshakeException>()),
    );

    client.close(force: true);
    await realServer.close(force: true);
    await fakeServer.close(force: true);
  });
}
