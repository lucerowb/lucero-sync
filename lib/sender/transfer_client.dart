import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/identity.dart';
import '../core/models.dart';
import '../core/protocol.dart';

class UnauthorizedException implements Exception {
  @override
  String toString() => 'Receiver rejected the PIN';
}

class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// True for failures that mean "the network/receiver went away" rather than
/// "this particular file is broken". Those pause the queue instead of
/// burning a retry attempt.
bool isTransientNetworkError(Object e) =>
    e is SocketException || e is HttpException || e is TimeoutException || e is OSError;

class TransferClient {
  TransferClient(this._identity);

  final DeviceIdentity _identity;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 10);

  static const _short = Duration(seconds: 10);
  static const _stallTimeout = Duration(seconds: 30);

  Future<({String deviceId, String name})> info(String host, int port) async {
    final req = await _http
        .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/v1/info'))
        .timeout(_short);
    final res = await req.close().timeout(_short);
    final body = await _readJson(res);
    return (deviceId: body['deviceId'] as String, name: body['name'] as String);
  }

  /// Verifies host + PIN and returns a peer ready to be saved.
  Future<PeerInfo> pair(String host, int port, String pin) async {
    final i = await info(host, port);
    final peer = PeerInfo(deviceId: i.deviceId, name: i.name, host: host, port: port, token: pin);
    await checkMany(peer, const []); // throws UnauthorizedException on a bad PIN
    return peer;
  }

  Future<bool> ping(PeerInfo peer) async {
    try {
      final i = await info(peer.host, peer.port);
      return i.deviceId == peer.deviceId;
    } catch (_) {
      return false;
    }
  }

  Future<FileCheck> check(PeerInfo peer, FileDescriptor file) async =>
      (await checkMany(peer, [file])).first;

  Future<List<FileCheck>> checkMany(PeerInfo peer, List<FileDescriptor> files) async {
    final req = await _http.postUrl(peer.uri('/v1/check')).timeout(_short);
    _authHeaders(req, peer);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'files': files.map((f) => f.toJson()).toList()}));
    final res = await req.close().timeout(_short);
    final body = await _readJson(res);
    return (body['results'] as List)
        .map((r) => FileCheck.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Streams bytes [offset, size) of [file]. A watchdog aborts the request if
  /// no bytes move for [_stallTimeout] (Wi-Fi drop, receiver asleep), which
  /// surfaces as a transient error so the engine waits and resumes.
  Future<UploadResult> upload(
    PeerInfo peer,
    FileDescriptor desc,
    File file,
    int offset, {
    required void Function(int bytesSent) onProgress,
  }) async {
    final req = await _http.putUrl(peer.uri('/v1/files/${desc.sha256}')).timeout(_short);
    _authHeaders(req, peer);
    req.headers
      ..contentType = ContentType.binary
      ..set(Protocol.hFilename, Uri.encodeComponent(desc.filename))
      ..set(Protocol.hSize, '${desc.size}')
      ..set(Protocol.hCreated, '${desc.createdAtMs}')
      ..set(Protocol.hOffset, '$offset');
    req.contentLength = desc.size - offset;

    var sent = offset;
    var lastProgress = DateTime.now();
    final watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(lastProgress) > _stallTimeout) {
        req.abort(TimeoutException('Upload stalled'));
      }
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
    final res = await req.close().timeout(const Duration(minutes: 3));
    return UploadResult.fromJson(res.statusCode, await _readJson(res));
  }

  void _authHeaders(HttpClientRequest req, PeerInfo peer) {
    req.headers
      ..set(Protocol.hToken, peer.token)
      ..set(Protocol.hDeviceId, _identity.deviceId);
  }

  Future<Map<String, dynamic>> _readJson(HttpClientResponse res) async {
    final text = await res.transform(utf8.decoder).join().timeout(_short);
    if (res.statusCode == HttpStatus.unauthorized) throw UnauthorizedException();
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } on FormatException {
      throw ProtocolException('Unexpected response (${res.statusCode}): $text');
    }
  }
}
