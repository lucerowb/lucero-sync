import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../share/linux_airdrop.dart';

/// "Send to anyone nearby", through the system's own sharing: AirDrop on
/// iPhone, iPad and Mac, Quick Share on Android, Nearby Sharing on Windows,
/// and AirDrop on Linux when owly or a4e is installed. Null when there's none.
String? systemShareLabel({required bool linuxAirDrop}) => Platform.isIOS || Platform.isMacOS
    ? 'AirDrop & more'
    : Platform.isAndroid
        ? 'Quick Share & more'
        : Platform.isWindows
            ? 'Nearby Sharing & more'
            : linuxAirDrop
                ? 'AirDrop'
                : null;

const _mac = MethodChannel('lucero_sync/permissions');

/// Shares [paths] and [texts] outside Lucero Sync. Returns false when the
/// user backed out, so the caller can keep their selection.
Future<bool> shareElsewhere(BuildContext context, {List<String> paths = const [], List<String> texts = const []}) async {
  if (Platform.isLinux) {
    final tool = await LinuxAirDrop.detect();
    if (tool == null || !context.mounted) return false;
    return await _airDropSheet(context, tool, paths, texts) ?? false;
  }
  if (Platform.isMacOS) {
    // Straight to AirDrop's window; the full share menu only if AirDrop can't take these.
    final ok = await _mac.invokeMethod<bool>('airDrop', {'paths': paths, 'texts': texts}).catchError((Object _) => false);
    if (ok == true) return true;
  }
  if (Platform.isAndroid) {
    // Native chooser: leaves Lucero Sync itself out and shares files in place.
    final text = texts.join('\n\n');
    final ok = await const MethodChannel('lucero_sync/storage')
        .invokeMethod<bool>('share', {'paths': paths, 'text': text.isEmpty ? null : text}).catchError((Object _) => false);
    if (ok == true) return true;
  }
  if (!context.mounted) return false;
  final box = context.findRenderObject() as RenderBox?;
  final text = texts.join('\n\n');
  final res = await SharePlus.instance.share(ShareParams(
    files: paths.isEmpty ? null : [for (final p in paths) XFile(p)],
    text: text.isEmpty ? null : text,
    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
  return res.status != ShareResultStatus.dismissed;
}

Future<bool?> _airDropSheet(BuildContext context, LinuxAirDrop tool, List<String> paths, List<String> texts) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AirDropSheet(tool: tool, paths: paths, texts: texts),
    );

class _AirDropSheet extends StatefulWidget {
  const _AirDropSheet({required this.tool, required this.paths, required this.texts});
  final LinuxAirDrop tool;
  final List<String> paths;
  final List<String> texts;

  @override
  State<_AirDropSheet> createState() => _AirDropSheetState();
}

class _AirDropSheetState extends State<_AirDropSheet> {
  LinuxAirDrop get _tool => widget.tool;
  List<AirDropPeer>? _found;
  String? _status;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _tool.release();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _status = 'Looking for iPhones, iPads and Macs…';
    });
    try {
      await _tool.prepare();
      final found = await _tool.browse();
      if (!mounted) return;
      setState(() {
        _found = found;
        _status = found.isEmpty ? 'No one found. Is their AirDrop set to Everyone for 10 minutes?' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send(AirDropPeer to) async {
    setState(() {
      _busy = true;
      _status = 'Waiting for ${to.name} to accept…';
    });
    // AirDrop takes links, not plain text: other text (and links, for a4e) goes as a .txt file.
    final urls = [
      if (_tool.sendsLinks)
        for (final t in widget.texts)
          if (const {'http', 'https'}.contains(Uri.tryParse(t.trim())?.scheme)) t.trim(),
    ];
    final notes = <String>[];
    final tmp = await Directory.systemTemp.createTemp('lucero-airdrop');
    var n = 0;
    for (final t in widget.texts.where((t) => !urls.contains(t.trim()))) {
      final f = File('${tmp.path}/Note${n++ == 0 ? '' : ' $n'}.txt');
      await f.writeAsString(t);
      notes.add(f.path);
    }
    final error = await _tool.send(to, paths: [...widget.paths, ...notes], urls: urls);
    await tmp.delete(recursive: true);
    if (!mounted) return;
    if (error == null) return Navigator.pop(context, true);
    setState(() {
      _busy = false;
      _status = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('AirDrop', style: theme.textTheme.titleLarge),
            const Spacer(),
            IconButton(
              tooltip: 'Look again',
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ]),
          Text(
            'Through ${_tool.tool}. Wi-Fi may pause for a moment while AirDrop is on.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          for (final r in _found ?? const <AirDropPeer>[])
            ListTile(
              leading: const Icon(Icons.phone_iphone_rounded),
              title: Text(r.name),
              enabled: !_busy,
              onTap: () => _send(r),
            ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(children: [
                if (_busy) ...[
                  const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                ],
                Expanded(child: Text(_status!)),
              ]),
            ),
        ]),
      ),
    );
  }
}
