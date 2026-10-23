import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../share/owly.dart';

/// "Send to anyone nearby", through the system's own sharing: AirDrop on
/// iPhone, iPad and Mac, Quick Share on Android, Nearby Sharing on Windows,
/// and owly's AirDrop on Linux when it's installed. Null when there's none.
String? systemShareLabel({required bool owly}) => Platform.isIOS || Platform.isMacOS
    ? 'AirDrop & more'
    : Platform.isAndroid
        ? 'Quick Share & more'
        : Platform.isWindows
            ? 'Nearby Sharing & more'
            : owly
                ? 'AirDrop'
                : null;

const _mac = MethodChannel('lucero_sync/permissions');

/// Shares [paths] and [texts] outside Lucero Sync. Returns false when the
/// user backed out, so the caller can keep their selection.
Future<bool> shareElsewhere(BuildContext context, {List<String> paths = const [], List<String> texts = const []}) async {
  if (Platform.isLinux) return await _owlySheet(context, paths, texts) ?? false;
  if (Platform.isMacOS) {
    // Straight to AirDrop's window; the full share menu only if AirDrop can't take these.
    final ok = await _mac.invokeMethod<bool>('airDrop', {'paths': paths, 'texts': texts}).catchError((Object _) => false);
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

Future<bool?> _owlySheet(BuildContext context, List<String> paths, List<String> texts) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OwlySheet(paths: paths, texts: texts),
    );

class _OwlySheet extends StatefulWidget {
  const _OwlySheet({required this.paths, required this.texts});
  final List<String> paths;
  final List<String> texts;

  @override
  State<_OwlySheet> createState() => _OwlySheetState();
}

class _OwlySheetState extends State<_OwlySheet> {
  final _owly = Owly();
  List<OwlyReceiver>? _found;
  String? _status;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _owly.radioDown();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _status = 'Looking for iPhones, iPads and Macs…';
    });
    try {
      await _owly.radioUp();
      final found = await _owly.browse();
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

  Future<void> _send(OwlyReceiver to) async {
    setState(() {
      _busy = true;
      _status = 'Waiting for ${to.name} to accept…';
    });
    // owly sends links, not plain text: other text goes as a .txt file.
    final urls = [for (final t in widget.texts) if (const {'http', 'https'}.contains(Uri.tryParse(t.trim())?.scheme)) t.trim()];
    final notes = <String>[];
    final tmp = await Directory.systemTemp.createTemp('lucero-airdrop');
    var n = 0;
    for (final t in widget.texts.where((t) => !urls.contains(t.trim()))) {
      final f = File('${tmp.path}/Note${n++ == 0 ? '' : ' $n'}.txt');
      await f.writeAsString(t);
      notes.add(f.path);
    }
    final error = await _owly.send(to, paths: [...widget.paths, ...notes], urls: urls);
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
            'Through owly. Wi-Fi may pause for a moment while AirDrop is on.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          for (final r in _found ?? const <OwlyReceiver>[])
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
