import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/platform.dart';

/// Opens a received file: the default app on desktop, the share sheet on
/// mobile (where "Save to Photos" / "Open in…" live).
Future<void> openReceived(BuildContext context, List<String> paths) async {
  final existing = paths.where((p) => File(p).existsSync()).toList();
  if (existing.isEmpty) {
    _toast(context, 'The file was moved or deleted.');
    return;
  }
  final box = context.findRenderObject() as RenderBox?;
  if (Caps.isDesktop) {
    final ok = await launchUrl(Uri.file(existing.first));
    if (!ok && context.mounted) _toast(context, "Couldn't open the file.");
    return;
  }
  await SharePlus.instance.share(ShareParams(
    files: [for (final p in existing) XFile(p)],
    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
}

Future<void> revealFolder(BuildContext context, String path) async {
  if (!Caps.isDesktop) return;
  await Directory(path).create(recursive: true);
  if (!await launchUrl(Uri.directory(path))) {
    if (context.mounted) _toast(context, "Couldn't open the folder.");
  }
}

Future<void> openLink(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

void _toast(BuildContext context, String msg) {
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
