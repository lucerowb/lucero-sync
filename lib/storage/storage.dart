import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/db.dart';

/// Where received data lives.
///
/// * **Backups** (photo library sync) go to `<backups>/YYYY/MM/`.
/// * **Shared files** go to `<received>/`.
///
/// Defaults per platform:
///
/// | Platform | Backups                          | Received files                |
/// |----------|----------------------------------|-------------------------------|
/// | Android  | Pictures/LuceroSync *            | Download/LuceroSync           |
/// | iOS      | Files › Lucero Sync › Backups    | Files › Lucero Sync › Received|
/// | Desktop  | ~/Pictures/Lucero Sync           | ~/Downloads/Lucero Sync       |
///
/// \* with "All files access"; otherwise Download/LuceroSync/Backups (or the
/// app's own folder on the rare device that refuses writes to Download/).
/// Desktop and Android folders can be changed in Settings.
///
/// In-flight uploads are `.part` files under `.lucero_tmp/` (with `.nomedia`)
/// next to their destination, so the final rename never crosses filesystems.
class Storage {
  Storage({required this.backupsRoot, required this.receivedRoot});

  final Directory backupsRoot;
  final Directory receivedRoot;

  static const _channel = MethodChannel('lucero_sync/storage');

  static const kBackupsDir = 'backups_dir';
  static const kReceivedDir = 'received_dir';

  static Future<bool> hasAllFilesAccess() async =>
      Platform.isAndroid && (await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false);

  /// Whether the user may pick custom folders on this platform.
  static bool get foldersConfigurable => !Platform.isIOS;

  static Future<Storage> resolve(AppDatabase db) async {
    if (Platform.isIOS) {
      try {
        if ((await DeviceInfoPlugin().iosInfo).model.toLowerCase().contains('ipad')) iosDeviceWord = 'iPad';
      } catch (_) {}
    }
    final custom = (await db.getValue(kBackupsDir), await db.getValue(kReceivedDir));
    final (backups, received) = await _defaults();
    final storage = Storage(
      backupsRoot: Directory(custom.$1 ?? backups),
      receivedRoot: Directory(custom.$2 ?? received),
    );
    await storage.ensureDirs();
    return storage;
  }

  static Future<(String, String)> _defaults() async {
    if (Platform.isAndroid) {
      if (await hasAllFilesAccess()) {
        final pictures = await _channel.invokeMethod<String>('picturesDir');
        final downloads = await _channel.invokeMethod<String>('downloadsDir');
        return (p.join(pictures!, 'LuceroSync'), p.join(downloads!, 'LuceroSync'));
      }
      // Android 11+ lets any app create files in Download/ (not Pictures/,
      // which refuses the non-media .part files), so both live there.
      final root = p.join((await _channel.invokeMethod<String>('downloadsDir'))!, 'LuceroSync');
      if (await _writable(root)) return (p.join(root, 'Backups'), root);
      // Some devices still refuse; the app's own folder always works.
      final ext = (await getExternalStorageDirectory())!.path;
      return (p.join(ext, 'LuceroSync', 'Backups'), p.join(ext, 'LuceroSync', 'Received'));
    }
    if (Platform.isIOS) {
      final docs = (await getApplicationDocumentsDirectory()).path;
      return (p.join(docs, 'Backups'), p.join(docs, 'Received'));
    }
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    final downloads = (await getDownloadsDirectory())?.path ?? p.join(home, 'Downloads');
    return (p.join(home, 'Pictures', 'Lucero Sync'), p.join(downloads, 'Lucero Sync'));
  }

  static Future<bool> _writable(String dir) async {
    try {
      final probe = File(p.join(dir, '.lucero_tmp', '.probe'));
      await probe.parent.create(recursive: true);
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> ensureDirs() async {
    for (final d in [backupsRoot, receivedRoot]) {
      final tmp = Directory(p.join(d.path, '.lucero_tmp'));
      await tmp.create(recursive: true);
      final noMedia = File(p.join(tmp.path, '.nomedia'));
      if (!await noMedia.exists()) await noMedia.create();
    }
  }

  // ---- backups -------------------------------------------------------------------

  File backupPart(String sha256) => File(p.join(backupsRoot.path, '.lucero_tmp', '$sha256.part'));

  String absoluteBackup(String relPath) => p.join(backupsRoot.path, relPath);

  /// Moves a verified backup into its dated folder; returns the relative path.
  Future<String> commitBackup(File part, String filename, int createdAtMs) async {
    final date = createdAtMs > 0 ? DateTime.fromMillisecondsSinceEpoch(createdAtMs) : DateTime.now();
    final folder = Directory(p.join(backupsRoot.path, '${date.year}', date.month.toString().padLeft(2, '0')));
    final target = await _commit(part, folder, filename);
    try {
      await target.setLastModified(date);
    } catch (_) {}
    return p.relative(target.path, from: backupsRoot.path);
  }

  // ---- shared files ----------------------------------------------------------------

  File sharePart(String offerId, String fileId) =>
      File(p.join(receivedRoot.path, '.lucero_tmp', 'share-$offerId-$fileId.part'));

  /// Moves a verified shared file into the received folder; returns its path.
  ///
  /// [relPath] may contain folders (from a folder transfer, already passed
  /// through [sanitizeRelativePath]). [topDirs] maps each sent top-level
  /// folder to the one used here, so a folder sent twice lands as
  /// "Photos (1)" instead of mixing into the first copy.
  Future<String> commitShare(File part, String relPath, {Map<String, String>? topDirs}) {
    // One at a time: files arrive in parallel and would race to pick the same free name.
    final run = _commits.then((_) => _commitShare(part, relPath, topDirs));
    _commits = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _commits = Future.value();

  Future<String> _commitShare(File part, String relPath, Map<String, String>? topDirs) async {
    final segs = relPath.split('/');
    if (segs.length == 1) return (await _commit(part, receivedRoot, relPath)).path;
    final top = topDirs?[segs.first] ?? await _uniqueDir(segs.first);
    topDirs?[segs.first] = top;
    final folder = Directory(p.joinAll([receivedRoot.path, top, ...segs.sublist(1, segs.length - 1)]));
    return (await _commit(part, folder, segs.last)).path;
  }

  Future<String> _uniqueDir(String name) async {
    var candidate = name;
    for (var n = 1; await Directory(p.join(receivedRoot.path, candidate)).exists(); n++) {
      candidate = '$name ($n)';
    }
    return candidate;
  }

  Future<File> _commit(File part, Directory folder, String filename) async {
    await folder.create(recursive: true);
    var target = File(p.join(folder.path, filename));
    for (var n = 1; await target.exists(); n++) {
      target = File(p.join(folder.path, '${p.basenameWithoutExtension(filename)} ($n)${p.extension(filename)}'));
    }
    return part.rename(target.path);
  }

  /// Makes new files show up in Android's Gallery, Files app and other apps.
  Future<void> notifyMediaScanner(String absolutePath) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('scanFile', {'path': absolutePath});
    }
  }

  String get backupsLabel => _label(backupsRoot, 'Backups');
  String get receivedLabel => _label(receivedRoot, 'Received');

  /// "iPhone" or "iPad", as the Files app names local storage.
  static String iosDeviceWord = 'iPhone';

  String _label(Directory d, String iosName) {
    if (Platform.isIOS) return 'Files › On My $iosDeviceWord › Lucero Sync › $iosName';
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && d.path.startsWith(home)) return '~${d.path.substring(home.length)}';
    const androidRoot = '/storage/emulated/0/';
    if (d.path.startsWith(androidRoot)) return d.path.substring(androidRoot.length);
    return d.path;
  }
}

/// Like [sanitizeFilename] for each folder level of a path sent with a
/// folder transfer ("Trip/Day 1/IMG.jpg"). `.` and `..` levels are dropped,
/// so the result always stays inside the destination folder.
String sanitizeRelativePath(String raw) {
  final segs = raw
      .replaceAll('\\', '/')
      .split('/')
      .where((s) => s.trim().isNotEmpty && s != '.' && s != '..')
      .map(sanitizeFilename)
      .toList();
  if (segs.isEmpty) return 'file';
  // shortcut: deeper trees are flattened into their 16th level; raise if anyone hits it.
  return (segs.length > 16 ? [...segs.take(15), segs.last] : segs).join('/');
}

/// Strip path separators and control characters so a sender can't write
/// outside the destination folder or create hidden/odd names.
String sanitizeFilename(String raw) {
  var name = p
      .basename(raw.replaceAll('\\', '/'))
      .replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_')
      .trim();
  while (name.startsWith('.')) {
    name = name.substring(1);
  }
  if (name.isEmpty) name = 'file';
  if (name.length > 200) {
    final ext = p.extension(name);
    name = '${name.substring(0, 200 - ext.length)}$ext';
  }
  return name;
}
