import 'dart:convert';
import 'dart:io';

/// Small helpers shared by the browser-facing servers (web access, extension API).

Future<Map<String, dynamic>> readJson(HttpRequest req, {int maxBytes = 1 << 20}) async {
  final bytes = <int>[];
  await for (final chunk in req) {
    bytes.addAll(chunk);
    if (bytes.length > maxBytes) throw const FormatException('body too large');
  }
  if (bytes.isEmpty) return {};
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) throw const FormatException('expected an object');
  return decoded;
}

Future<void> replyJson(HttpRequest req, int status, Map<String, Object?> body) async {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
    ..write(jsonEncode(body));
  await req.response.close();
}

String? bearerToken(HttpRequest req) {
  final h = req.headers.value(HttpHeaders.authorizationHeader);
  if (h == null || !h.startsWith('Bearer ')) return null;
  return h.substring(7).trim();
}

/// N failures per window per key (usually the remote IP).
class FailureLimiter {
  FailureLimiter({this.max = 5, this.window = const Duration(minutes: 5)});
  final int max;
  final Duration window;
  final _hits = <String, List<DateTime>>{};

  bool blocked(String key) {
    final now = DateTime.now();
    final hits = (_hits[key] ?? [])..removeWhere((t) => now.difference(t) > window);
    _hits[key] = hits;
    return hits.length >= max;
  }

  void fail(String key) => (_hits[key] ??= []).add(DateTime.now());
  void clear(String key) => _hits.remove(key);
}

/// "Chrome on Windows" from a User-Agent, for naming browser sessions.
String describeUserAgent(String? ua) {
  if (ua == null) return 'Browser';
  final browser = ua.contains('Edg/')
      ? 'Edge'
      : ua.contains('Firefox/')
          ? 'Firefox'
          : ua.contains('Chrome/')
              ? 'Chrome'
              : ua.contains('Safari/')
                  ? 'Safari'
                  : 'Browser';
  final os = ua.contains('iPhone')
      ? 'iPhone'
      : ua.contains('iPad')
          ? 'iPad'
          : ua.contains('Android')
              ? 'Android'
              : ua.contains('Mac OS X')
                  ? 'Mac'
                  : ua.contains('Windows')
                      ? 'Windows'
                      : ua.contains('Linux')
                          ? 'Linux'
                          : null;
  return os == null ? browser : '$browser on $os';
}
