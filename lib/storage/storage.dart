import 'dart:io';

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
/// | Android  | Pictures/LuceroSync *            | Download/LuceroSync *         |
/// | iOS      | Files › Lucero Sync › Backups    | Files › Lucero Sync › Received|
/// | Desktop  | ~/Pictures/Lucero Sync           | ~/Downloads/Lucero Sync       |
///
/// \* with "All files access"; otherwise the app's external files folder.
/// Desktop and Android folders can be changed in Settings.
///
/// In-flight uploads are `.part` files under `.lucero_tmp/` (with `.nomedia`)
/// next to their destination, so the final rename never crosses filesystems.
class Storage {
  Storage({required this.backupsRoot, required this.receivedRoot, this.publicMedia = false});

  final Directory backupsRoot;
  final Directory receivedRoot;

  /// True when backups are in a folder the Android media scanner indexes.
  final bool publicMedia;

  static const _channel = MethodChannel('lucero_sync/storage');

  static const kBackupsDir = 'backups_dir';
  static const kReceivedDir = 'received_dir';

  static Future<bool> hasAllFilesAccess() async =>
      Platform.isAndroid && (await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false);

  /// Whether the user may pick custom folders on this platform.
  static bool get foldersConfigurable => !Platform.isIOS;

  static Future<Storage> resolve(AppDatabase db) async {
    final custom = (await db.getValue(kBackupsDir), await db.getValue(kReceivedDir));
    final (backups, received, public) = await _defaults();
    final storage = Storage(
      backupsRoot: Directory(custom.$1 ?? backups),
      receivedRoot: Directory(custom.$2 ?? received),
      publicMedia: public && custom.$1 == null,
    );
    await storage.ensureDirs();
    return storage;
  }

  static Future<(String, String, bool)> _defaults() async {
    if (Platform.isAndroid) {
      if (await hasAllFilesAccess()) {
        final pictures = await _channel.invokeMethod<String>('picturesDir');
        final downloads = await _channel.invokeMethod<String>('downloadsDir');
        return (p.join(pictures!, 'LuceroSync'), p.join(downloads!, 'LuceroSync'), true);
      }
      final ext = (await getExternalStorageDirectory())!.path;
      return (p.join(ext, 'LuceroSync', 'Backups'), p.join(ext, 'LuceroSync', 'Received'), false);
    }
    if (Platform.isIOS) {
      final docs = (await getApplicationDocumentsDirectory()).path;
      return (p.join(docs, 'Backups'), p.join(docs, 'Received'), false);
    }
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    final downloads = (await getDownloadsDirectory())?.path ?? p.join(home, 'Downloads');
    return (p.join(home, 'Pictures', 'Lucero Sync'), p.join(downloads, 'Lucero Sync'), false);
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
  Future<String> commitShare(File part, String filename) async => (await _commit(part, receivedRoot, filename)).path;

  Future<File> _commit(File part, Directory folder, String filename) async {
    await folder.create(recursive: true);
    var target = File(p.join(folder.path, filename));
    for (var n = 1; await target.exists(); n++) {
      target = File(p.join(folder.path, '${p.basenameWithoutExtension(filename)} ($n)${p.extension(filename)}'));
    }
    return part.rename(target.path);
  }

  /// Makes new media show up in Android's Gallery / Google Photos.
  Future<void> notifyMediaScanner(String absolutePath) async {
    if (Platform.isAndroid && publicMedia) {
      await _channel.invokeMethod('scanFile', {'path': absolutePath});
    }
  }

  String get backupsLabel => _label(backupsRoot, 'Backups');
  String get receivedLabel => _label(receivedRoot, 'Received');

  String _label(Directory d, String iosName) {
    if (Platform.isIOS) return 'Files › On My iPhone › Lucero Sync › $iosName';
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && d.path.startsWith(home)) return '~${d.path.substring(home.length)}';
    const androidRoot = '/storage/emulated/0/';
    if (d.path.startsWith(androidRoot)) return d.path.substring(androidRoot.length);
    return d.path;
  }
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
