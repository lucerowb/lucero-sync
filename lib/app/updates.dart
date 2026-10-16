import 'dart:convert';
import 'dart:io';

import '../core/version.dart';

/// A newer release on GitHub, and where to get it for this platform.
class UpdateInfo {
  const UpdateInfo(this.version, this.url);
  final String version;
  final Uri url;
}

const _latest = 'https://api.github.com/repos/lucerowb/lucero-sync/releases/latest';

/// The release download for this platform. iOS updates through AltStore or
/// SideStore, so it gets the release notes instead.
String? get _assetName => Platform.isAndroid
    ? 'lucero-sync.apk'
    : Platform.isMacOS
        ? 'lucero-sync-macos.zip'
        : Platform.isWindows
            ? 'lucero-sync-windows-x64.zip'
            : Platform.isLinux
                ? 'lucero-sync-linux-x64.tar.gz'
                : null;

/// One anonymous request to GitHub; nothing about the device is sent.
/// Returns null when up to date or when GitHub can't be reached.
Future<UpdateInfo?> fetchUpdate() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(_latest));
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    final m = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    final version = (m['tag_name'] as String).replaceFirst(RegExp('^v'), '');
    if (!isNewerVersion(version, appVersion)) return null;
    final assets = {
      for (final a in (m['assets'] as List).cast<Map<String, dynamic>>())
        a['name'] as String: a['browser_download_url'] as String,
    };
    final url = Uri.parse(assets[_assetName] ?? m['html_url'] as String);
    return url.scheme == 'https' ? UpdateInfo(version, url) : null;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// Compares dotted versions numerically ("0.3.10" > "0.3.9").
bool isNewerVersion(String candidate, String current) {
  List<int> parts(String v) => v.split(RegExp(r'[.+-]')).take(3).map((s) => int.tryParse(s) ?? 0).toList();
  final a = parts(candidate), b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
