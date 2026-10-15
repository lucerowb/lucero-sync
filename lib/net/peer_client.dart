import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/identity.dart';
import '../core/models.dart';
import '../core/protocol.dart';
import '../security/pairing_crypto.dart';
import '../security/tls_identity.dart';

class UnauthorizedException implements Exception {
  @override
  String toString() => 'The other device no longer recognises this one. Pair again.';
}

/// The device presented a different certificate than the one we pinned.
class IdentityMismatchException implements Exception {
  @override
  String toString() =>
      "Couldn't verify the other device's identity. If it was reinstalled, remove it and pair again.";
}

class PairingDeclinedException implements Exception {
  PairingDeclinedException(this.reason);
  final String reason;
  @override
  String toString() => switch (reason) {
        'too_many_attempts' => 'Too many attempts. Wait a few minutes and try again.',
        'qr_expired' => 'That QR code has expired. Show a fresh one and scan again.',
        'commit_mismatch' => 'Pairing was blocked because the connection may have been intercepted.',
        _ => 'Pairing was declined on the other device.',
      };
}

class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Failures that mean "network or receiver went away" rather than "this file
/// is broken". They pause work instead of burning a retry.
bool isTransientNetworkError(Object e) =>
    e is SocketException || e is HttpException || e is TimeoutException || (e is OSError);

typedef RemoteInfo = ({String deviceId, String name, String platform, String fingerprint});

/// An [HttpClient] that only talks to a server presenting the pinned
/// certificate. With [pinned] null it trusts the first certificate it sees
/// (used only before pairing, where the comparison code protects the user)
/// and then sticks to it.
class PinnedHttp {
  PinnedHttp(this.pinned) {
    _client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 15)
      ..badCertificateCallback = (cert, host, port) {
        final fp = fingerprintOf(cert.der);
        pinned ??= fp;
        return PairingCrypto.constantTimeEquals(fp, pinned!);
      };
  }

  String? pinned;
  late final HttpClient _client;

  Future<HttpClientRequest> open(String method, Uri uri) async {
    try {
      return await _client.openUrl(method, uri).timeout(const Duration(seconds: 10));
    } on HandshakeException {
      throw IdentityMismatchException();
    }
  }

  /// Defence in depth: re-check the certificate on every response.
  void verify(HttpClientResponse res) {
    final cert = res.certificate;
    if (cert == null || pinned == null || !PairingCrypto.constantTimeEquals(fingerprintOf(cert.der), pinned!)) {
      throw IdentityMismatchException();
    }
  }

  void close() => _client.close(force: true);
}

class PeerClient {
  PeerClient(this.identity, {required this.serverPort});

  final DeviceIdentity identity;

  /// Our own server port, sent during pairing so the peer can call back.
  int Function() serverPort;

  final _clients = <String, PinnedHttp>{};

  PinnedHttp _for(PeerDevice peer) => _clients.putIfAbsent(peer.fingerprint, () => PinnedHttp(peer.fingerprint));

  void forget(PeerDevice peer) => _clients.remove(peer.fingerprint)?.close();

  static const _short = Duration(seconds: 12);

  // ---- requests -----------------------------------------------------------------

  Future<Map<String, dynamic>> _call(
    PinnedHttp http,
    String method,
    Uri uri, {
    Object? json,
    String? token,
    Duration timeout = _short,
  }) async {
    final req = await http.open(method, uri);
    if (token != null) {
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..set(Protocol.hDeviceId, identity.deviceId);
    }
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    final res = await req.close().timeout(timeout);
    http.verify(res);
    return _readJson(res, timeout);
  }

  Future<Map<String, dynamic>> _readJson(HttpClientResponse res, Duration timeout) async {
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    if (res.statusCode == HttpStatus.unauthorized) throw UnauthorizedException();
    try {
      final m = jsonDecode(text) as Map<String, dynamic>;
      return m..['_http'] = res.statusCode;
    } on FormatException {
      throw ProtocolException('Unexpected response (${res.statusCode})');
    }
  }

  /// Reads a device's identity. [expectFp] pins it; otherwise trust-on-first-use.
  Future<RemoteInfo> info(String host, int port, {String? expectFp}) async {
    final http = PinnedHttp(expectFp);
    try {
      final m = await _call(http, 'GET', Uri(scheme: 'https', host: host, port: port, path: '/v2/info'));
      return (
        deviceId: m['deviceId'] as String,
        name: m['name'] as String,
        platform: m['platform'] as String? ?? 'unknown',
        fingerprint: http.pinned!,
      );
    } finally {
      http.close();
    }
  }

  Future<bool> ping(PeerDevice peer) async {
    try {
      final m = await _call(_for(peer), 'GET', peer.uri('/v2/info'));
      return m['deviceId'] == peer.deviceId;
    } catch (_) {
      return false;
    }
  }

  // ---- pairing ------------------------------------------------------------------

  /// Starts pairing. [expectFp] and [qrSecret] come from a scanned QR code.
  Future<OutgoingPairing> startPairing(String host, int port, {String? expectFp, String? qrSecret}) async {
    final http = PinnedHttp(expectFp);
    final base = Uri(scheme: 'https', host: host, port: port);
    final nonce = PairingCrypto.randomHex(32);

    // Learn (or verify) the server's certificate before committing to it.
    final info = await _call(http, 'GET', base.replace(path: '/v2/info'));
    final serverFp = http.pinned!;

    final start = await _call(http, 'POST', base.replace(path: '/v2/pair/start'), json: {
      'deviceId': identity.deviceId,
      'name': identity.name,
      'platform': identity.platform,
      'fingerprint': identity.fingerprint,
      'port': serverPort(),
      'commit': PairingCrypto.commit(nonceHex: nonce, clientFp: identity.fingerprint, serverFp: serverFp),
      if (qrSecret != null) 'qrSecret': qrSecret,
    });
    if (start['_http'] != 200) {
      http.close();
      throw PairingDeclinedException(start['status'] as String? ?? 'declined');
    }

    return OutgoingPairing._(
      http: http,
      base: base,
      session: start['session'] as String,
      code: PairingCrypto.sas(
        serverFp: serverFp,
        clientFp: identity.fingerprint,
        clientNonce: nonce,
        serverNonce: start['nonce'] as String,
      ),
      nonce: nonce,
      viaQr: qrSecret != null,
      remote: (
        deviceId: start['deviceId'] as String,
        name: start['name'] as String,
        platform: start['platform'] as String? ?? (info['platform'] as String? ?? 'unknown'),
        fingerprint: serverFp,
      ),
      host: host,
      port: port,
      client: this,
    );
  }

  Future<void> unpair(PeerDevice peer) async {
    try {
      await _call(_for(peer), 'POST', peer.uri('/v2/unpair'), token: peer.tokenOut);
    } catch (_) {/* best effort */}
    forget(peer);
  }

  // ---- backup -------------------------------------------------------------------

  Future<FileCheck> backupCheck(PeerDevice peer, FileDescriptor file) async {
    final m = await _call(_for(peer), 'POST', peer.uri('/v2/backup/check'),
        token: peer.tokenOut, json: {'files': [file.toJson()]});
    return FileCheck.fromJson((m['results'] as List).first as Map<String, dynamic>);
  }

  Future<UploadResult> backupUpload(PeerDevice peer, FileDescriptor desc, File file, int offset,
      {required void Function(int bytesSent) onProgress}) {
    return _upload(
      peer,
      peer.uri('/v2/backup/files/${desc.sha256}'),
      file,
      offset,
      desc.size,
      headers: {
        Protocol.hFilename: Uri.encodeComponent(desc.filename),
        Protocol.hSize: '${desc.size}',
        Protocol.hCreated: '${desc.createdAtMs}',
      },
      onProgress: onProgress,
    );
  }

  /// Tells the receiver how far a backup run has got. Best effort: older
  /// receivers don't have this endpoint, and progress isn't worth retrying.
  Future<void> backupStatus(PeerDevice peer, Map<String, Object?> status) async {
    try {
      await _call(_for(peer), 'POST', peer.uri('/v2/backup/status'),
          token: peer.tokenOut, json: status, timeout: const Duration(seconds: 5));
    } catch (_) {}
  }

  // ---- sharing ------------------------------------------------------------------

  /// Offers files; waits (up to ~2 minutes) for the other person to accept.
  Future<({bool accepted, Map<String, int> offsets})> shareOffer(
      PeerDevice peer, String offerId, List<ShareFile> files) async {
    final m = await _call(_for(peer), 'POST', peer.uri('/v2/share/offer'),
        token: peer.tokenOut,
        json: {'offerId': offerId, 'files': [for (final f in files) f.toJson()]},
        timeout: const Duration(minutes: 3));
    if (m['status'] != Protocol.accepted) return (accepted: false, offsets: <String, int>{});
    return (accepted: true, offsets: (m['offsets'] as Map).map((k, v) => MapEntry(k as String, v as int)));
  }

  Future<void> shareText(PeerDevice peer, String offerId, String text) async {
    final m = await _call(_for(peer), 'POST', peer.uri('/v2/share/offer'),
        token: peer.tokenOut, json: {'offerId': offerId, 'text': text});
    if (m['status'] != Protocol.accepted) throw ProtocolException('The other device did not accept the text.');
  }

  Future<UploadResult> shareUpload(PeerDevice peer, String offerId, ShareFile f, File file, int offset,
          {required void Function(int bytesSent) onProgress}) =>
      _upload(peer, peer.uri('/v2/share/$offerId/${f.id}'), file, offset, f.size, onProgress: onProgress);

  Future<void> shareCancel(PeerDevice peer, String offerId) async {
    try {
      await _call(_for(peer), 'POST', peer.uri('/v2/share/$offerId/cancel'), token: peer.tokenOut);
    } catch (_) {}
  }

  // ---- upload plumbing ------------------------------------------------------------

  static const _stallTimeout = Duration(seconds: 30);

  Future<UploadResult> _upload(
    PeerDevice peer,
    Uri uri,
    File file,
    int offset,
    int size, {
    Map<String, String> headers = const {},
    required void Function(int bytesSent) onProgress,
  }) async {
    final http = _for(peer);
    final req = await http.open('PUT', uri);
    req.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${peer.tokenOut}')
      ..set(Protocol.hDeviceId, identity.deviceId)
      ..set(Protocol.hOffset, '$offset')
      ..contentType = ContentType.binary;
    headers.forEach(req.headers.set);
    req.contentLength = size - offset;

    var sent = offset;
    var lastProgress = DateTime.now();
    final watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(lastProgress) > _stallTimeout) req.abort(TimeoutException('Upload stalled'));
    });
    try {
      await req.addStream(file.openRead(offset).map((chunk) {
        sent += chunk.length;
        lastProgress = DateTime.now();
        onProgress(sent);
        return chunk;
      }));
    } finally {
      watchdog.cancel();
    }
    // The receiver hashes the whole file before answering; allow for big videos.
    final res = await req.close().timeout(const Duration(minutes: 5));
    http.verify(res);
    final m = await _readJson(res, const Duration(minutes: 5));
    return UploadResult.fromJson(res.statusCode, m);
  }
}

/// Client side of an in-progress pairing. Show [code] to the user; call
/// [waitForApproval] (receiver's Accept) and, once the user confirms the codes
/// match, [confirm] to exchange tokens.
class OutgoingPairing {
  OutgoingPairing._({
    required PinnedHttp http,
    required Uri base,
    required this.session,
    required this.code,
    required String nonce,
    required this.viaQr,
    required this.remote,
    required this.host,
    required this.port,
    required PeerClient client,
  })  : _http = http,
        _base = base,
        _nonce = nonce,
        _client = client;

  final PinnedHttp _http;
  final Uri _base;
  final String _nonce;
  final PeerClient _client;

  final String session;
  final String code;
  final bool viaQr;
  final RemoteInfo remote;
  final String host;
  final int port;

  String? _tokenFromServer;

  /// Reveals our nonce and waits for the other user to accept.
  Future<void> waitForApproval() async {
    final m = await _client._call(_http, 'POST', _base.replace(path: '/v2/pair/finish'),
        json: {'session': session, 'nonce': _nonce}, timeout: const Duration(minutes: 3));
    if (m['status'] != Protocol.accepted) throw PairingDeclinedException(m['status'] as String? ?? 'declined');
    _tokenFromServer = m['token'] as String;
  }

  /// Our user confirmed the codes match: hand over our token and save the pair.
  Future<PeerDevice> confirm() async {
    final tokenForServer = PairingCrypto.newToken();
    final m = await _client._call(_http, 'POST', _base.replace(path: '/v2/pair/confirm'),
        json: {'session': session, 'token': tokenForServer});
    _http.close();
    if (m['status'] != 'paired') throw ProtocolException('Pairing could not be completed.');
    return PeerDevice(
      deviceId: remote.deviceId,
      name: remote.name,
      platform: remote.platform,
      fingerprint: remote.fingerprint,
      host: host,
      port: port,
      tokenOut: _tokenFromServer!,
      tokenInHash: PairingCrypto.hashToken(tokenForServer),
    );
  }

  Future<void> cancel() async {
    try {
      await _client._call(_http, 'POST', _base.replace(path: '/v2/pair/cancel'), json: {'session': session});
    } catch (_) {}
    _http.close();
  }
}
