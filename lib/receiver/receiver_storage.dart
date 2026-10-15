import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where received files live.
///
/// Android: /storage/emulated/0/Pictures/LuceroSync/YYYY/MM/ when "All files
///          access" is granted (visible in Gallery), otherwise the app's
///          external files dir.
/// iOS:     <Documents>/LuceroSync/ — exposed in the Files app.
///
/// In-flight uploads are `<sha256>.part` files under `.lucero_tmp/` (with a
/// `.nomedia` marker so galleries ignore them). They are what makes resume work.
class ReceiverStorage {
  ReceiverStorage._(this.root, this.isPublic);

  final Directory root;
  final bool isPublic;

  static const _channel = MethodChannel('lucero_sync/storage');

  static Future<bool> hasAllFilesAccess() async =>
      Platform.isAndroid && (await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false);

  static Future<ReceiverStorage> open() async {
    Directory base;
    var isPublic = false;
    if (Platform.isAndroid) {
      if (await hasAllFilesAccess()) {
        final pictures = await _channel.invokeMethod<String>('picturesDir');
        base = Directory(p.join(pictures!, 'LuceroSync'));
        isPublic = true;
      } else {
        base = Directory(p.join((await getExternalStorageDirectory())!.path, 'LuceroSync'));
      }
    } else {
      base = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'LuceroSync'));
    }

    final storage = ReceiverStorage._(base, isPublic);
    await storage.tmpDir.create(recursive: true);
    final noMedia = File(p.join(storage.tmpDir.path, '.nomedia'));
    if (!await noMedia.exists()) await noMedia.create();
    return storage;
  }

  Directory get tmpDir => Directory(p.join(root.path, '.lucero_tmp'));

  File partFile(String sha256) => File(p.join(tmpDir.path, '$sha256.part'));

  String absolute(String relPath) => p.join(root.path, relPath);

  /// Moves a verified .part into its final dated folder without overwriting
  /// anything, and returns the path relative to [root].
  Future<String> commit(File part, String filename, int createdAtMs) async {
    final date = createdAtMs > 0 ? DateTime.fromMillisecondsSinceEpoch(createdAtMs) : DateTime.now();
    final folder = Directory(p.join(root.path, '${date.year}', date.month.toString().padLeft(2, '0')));
    await folder.create(recursive: true);

    var target = File(p.join(folder.path, filename));
    for (var n = 1; await target.exists(); n++) {
      target = File(p.join(
        folder.path,
        '${p.basenameWithoutExtension(filename)} ($n)${p.extension(filename)}',
      ));
    }
    await part.rename(target.path);
    try {
      await target.setLastModified(date);
    } catch (_) {}
    return p.relative(target.path, from: root.path);
  }

  /// Makes the new file show up in Android's Gallery / Google Photos.
  Future<void> notifyMediaScanner(String relPath) async {
    if (Platform.isAndroid && isPublic) {
      await _channel.invokeMethod('scanFile', {'path': absolute(relPath)});
    }
  }
}

/// Strip path separators and control chars so a sender can't write outside root.
String sanitizeFilename(String raw) {
  var name = p.basename(raw.replaceAll('\\', '/')).replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_').trim();
  if (name.isEmpty || name == '.' || name == '..') name = 'file';
  return name;
}
