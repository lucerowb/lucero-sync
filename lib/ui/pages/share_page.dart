import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../app/updates.dart';
import '../../core/models.dart';
import '../../core/platform.dart';
import '../../share/share_sender.dart';
import '../format.dart';
import '../open.dart';
import '../pairing.dart';
import '../widgets/common.dart';
import '../widgets/live_transfers.dart';
import 'transfer_page.dart';

class _Picked {
  _Picked(this.path, this.size, {this.files});
  final String path;
  final int size;

  /// Set for a folder: how many files it holds.
  final int? files;
  String get name => p.basename(path);
}

/// Home: this device, what to send, and the devices to send it to.
class SharePage extends StatefulWidget {
  const SharePage({super.key, required this.app});
  final AppController app;

  @override
  State<SharePage> createState() => _SharePageState();
}

class _SharePageState extends State<SharePage> {
  final _picked = <_Picked>[];
  bool _dragging = false;

  /// Text/links shared into the app from another app, sent with the files.
  final _texts = <String>[];

  @override
  void initState() {
    super.initState();
    app.mobile.incoming.addListener(_takeShared);
    _takeShared();
  }

  @override
  void dispose() {
    app.mobile.incoming.removeListener(_takeShared);
    super.dispose();
  }

  void _takeShared() {
    final payload = app.mobile.incoming.value;
    if (payload == null) return;
    app.mobile.incoming.value = null;
    _addPaths(payload.files);
    setState(() => _texts.addAll(payload.texts.where((t) => !_texts.contains(t))));
    final n = payload.files.length + payload.texts.length;
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _toast('$n item${n == 1 ? '' : 's'} ready to send. Tap a device.'));
  }

  /// Which picker is opening; the system sheet can take a second or two.
  /// A [FileType], or [_folder] for the folder picker.
  Object? _opening;
  static const _folder = 'folder';

  void _addPaths(Iterable<String> paths) {
    setState(() {
      for (final path in paths) {
        if (_picked.any((x) => x.path == path)) continue;
        final f = File(path);
        if (f.existsSync()) {
          _picked.add(_Picked(path, f.lengthSync()));
        } else if (Directory(path).existsSync()) {
          final inside = expandPaths([path]);
          if (inside.isEmpty) continue;
          _picked.add(_Picked(path, inside.fold(0, (a, f) => a + f.size), files: inside.length));
        }
      }
    });
  }

  AppController get app => widget.app;
  int get _totalBytes => _picked.fold(0, (a, f) => a + f.size);

  Future<void> _pick(FileType type) async {
    if (_opening != null) return;
    setState(() => _opening = type);
    try {
      final files = await FilePicker.pickFiles(type: type);
      _addPaths([for (final f in files) ?f.path]);
    } catch (e) {
      _toast("Couldn't open the picker. Check Settings › Permissions. ($e)");
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _pickFolder() async {
    if (_opening != null) return;
    setState(() => _opening = _folder);
    try {
      final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder to send');
      if (dir != null) _addPaths([dir]);
    } catch (e) {
      _toast("Couldn't open the folder picker. Check Settings › Permissions. ($e)");
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _addText() async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (!mounted) return;
    final text = await _askText(title: 'Text to send', initial: clip, action: 'Add');
    if (text != null) setState(() => _texts.add(text));
  }

  Future<String?> _askText({required String title, required String action, String? initial}) async {
    final controller = TextEditingController(text: initial);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(hintText: 'A link, a note, a Wi-Fi password…'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(action)),
        ],
      ),
    );
    return text == null || text.trim().isEmpty ? null : text;
  }

  Future<void> _sendTo(PeerDevice peer) async {
    if (_picked.isEmpty && _texts.isEmpty) return _deviceActions(peer);
    final share = _picked.isEmpty ? null : app.sendFiles(peer, _picked.map((f) => f.path).toList());
    for (final t in _texts) {
      app.sendText(peer, t);
    }
    setState(() {
      _picked.clear();
      _texts.clear();
    });
    if (share == null) return _toast('Sent to ${peer.name}.');
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => TransferPage.outgoing(app: app, share: share)));
  }

  Future<void> _sendText(PeerDevice peer) async {
    final text = await _askText(title: 'Send text to ${peer.name}', action: 'Send');
    if (text == null) return;
    app.sendText(peer, text);
    _toast('Text sent to ${peer.name}.');
  }

  Future<void> _deviceActions(PeerDevice peer) async {
    final status = app.statusOf(peer);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: DeviceAvatar(platform: peer.platform, name: peer.name, status: status),
            title: Text(peer.name),
            subtitle: Text('${platformLabel(peer.platform)} · paired'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.upload_file_rounded),
            title: const Text('Send files'),
            onTap: () async {
              Navigator.pop(ctx);
              await _pick(FileType.any);
              if (_picked.isNotEmpty) await _sendTo(peer);
            },
          ),
          if (Caps.isMobile)
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Send photos & videos'),
              onTap: () async {
                Navigator.pop(ctx);
                await _pick(FileType.media);
                if (_picked.isNotEmpty) await _sendTo(peer);
              },
            ),
          ListTile(
            leading: const Icon(Icons.notes_rounded),
            title: const Text('Send text'),
            onTap: () {
              Navigator.pop(ctx);
              _sendText(peer);
            },
          ),
          if (Caps.hasPhotoLibrary)
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: Text(app.backupTargetId == peer.deviceId ? 'Photo backups go here' : 'Back up photos to this device'),
              enabled: app.backupTargetId != peer.deviceId,
              onTap: () {
                Navigator.pop(ctx);
                app.setBackupTarget(peer.deviceId);
                _toast('Photo backups will go to ${peer.name}.');
              },
            ),
          SwitchListTile(
            secondary: const Icon(Icons.verified_user_outlined),
            title: const Text('Accept files automatically'),
            subtitle: const Text('Skip the confirmation for this device'),
            value: peer.autoAccept,
            onChanged: (v) {
              Navigator.pop(ctx);
              app.setAutoAccept(peer, v);
            },
          ),
          ListTile(
            leading: Icon(Icons.link_off_rounded, color: Theme.of(ctx).colorScheme.error),
            title: Text('Remove device', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            onTap: () async {
              Navigator.pop(ctx);
              final ok = await _confirm('Remove ${peer.name}?',
                  'It will no longer be able to send to this device, and you will need to pair again to use it.');
              if (ok) await app.unpair(peer);
            },
          ),
        ])),
      ),
    );
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(title: Text(title), content: Text(body), actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ]),
      ) ??
      false;

  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final wide = MediaQuery.sizeOf(context).width >= 1000;
        final composer = _composer(context);
        final devices = _devices(context);
        return PageScaffold(
          title: 'Share',
          subtitle: 'Send files and text to your devices. Nothing leaves your network.',
          actions: [
            IconButton(tooltip: 'Refresh nearby devices', onPressed: app.refreshNetwork, icon: const Icon(Icons.refresh_rounded)),
          ],
          children: [
            if (app.update != null) ...[_UpdateCard(app: app, update: app.update!), const SizedBox(height: 12)],
            _ThisDeviceCard(app: app),
            LiveTransfersSection(app: app),
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 5, child: composer),
                const SizedBox(width: 24),
                Expanded(flex: 6, child: devices),
              ])
            else ...[
              composer,
              devices,
            ],
          ],
        );
      },
    );
  }

  Widget _composer(BuildContext context) {
    final theme = Theme.of(context);
    final box = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('1 · Choose what to send'),
      Card(
        color: _dragging ? theme.colorScheme.primary.withValues(alpha: 0.12) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: _dragging ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
            width: _dragging ? 2 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              _PickChip(
                  icon: Icons.upload_file_rounded,
                  label: 'Files',
                  busy: _opening == FileType.any,
                  onTap: () => _pick(FileType.any)),
              _PickChip(
                  icon: Icons.photo_library_outlined,
                  label: 'Photos & videos',
                  busy: _opening == FileType.media,
                  onTap: () => _pick(FileType.media)),
              // iOS hands out folders as security-scoped URLs the app can't walk with plain file APIs.
              if (!Platform.isIOS)
                _PickChip(
                    icon: Icons.folder_outlined,
                    label: 'Folder',
                    busy: _opening == _folder,
                    onTap: _pickFolder),
              _PickChip(icon: Icons.notes_rounded, label: 'Text', onTap: _addText),
            ]),
            for (final t in _texts)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(t.startsWith('http') ? Icons.link_rounded : Icons.notes_rounded),
                title: Text(t, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => setState(() => _texts.remove(t)),
                ),
              ),
            if (_picked.isEmpty && _texts.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  Caps.isDesktop
                      ? 'Drop files or folders here, or pick them, then click a device.'
                      : 'Pick what to send, then tap a device below.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            else if (_picked.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final f in _picked.take(6))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(f.files != null ? Icons.folder_rounded : fileIcon(f.name)),
                  title: Text(f.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(f.files != null
                      ? '${f.files} file${f.files == 1 ? '' : 's'} · ${formatBytes(f.size)}'
                      : formatBytes(f.size)),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() => _picked.remove(f)),
                  ),
                ),
              if (_picked.length > 6) Text('and ${_picked.length - 6} more', style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text('${_picked.length} item${_picked.length == 1 ? '' : 's'} · ${formatBytes(_totalBytes)}',
                      style: theme.textTheme.titleSmall),
                ),
                TextButton(onPressed: () => setState(_picked.clear), child: const Text('Clear')),
              ]),
            ],
          ]),
        ),
      ),
    ]);
    if (!Caps.isDesktop) return box;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        _addPaths(d.files.map((f) => f.path));
      },
      child: box,
    );
  }

  Widget _devices(BuildContext context) {
    final peers = app.peers;
    final nearby = app.unpairedNearby;
    final selecting = _picked.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(
        selecting ? '2 · Tap a device to send' : 'Your devices',
        trailing: _AddDeviceMenu(app: app),
      ),
      if (peers.isEmpty && nearby.isEmpty)
        EmptyState(
          icon: Icons.devices_rounded,
          title: 'No devices yet',
          body: 'Open Lucero Sync on another device on the same Wi-Fi. It will show up here, '
              'or pair by QR code.',
          actions: [
            if (Caps.canScanQr)
              FilledButton.icon(
                onPressed: () => scanAndPair(context, app),
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('Scan QR'),
              ),
            OutlinedButton.icon(
              onPressed: () => showMyQr(context, app),
              icon: const Icon(Icons.qr_code_rounded),
              label: const Text('Show my code'),
            ),
          ],
        ),
      for (final peer in peers) ...[
        PeerCard(
          peer: peer,
          status: app.statusOf(peer),
          highlight: selecting && app.statusOf(peer) == PeerStatus.online,
          onTap: () => _sendTo(peer),
          menu: IconButton(
            tooltip: 'Options',
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () => _deviceActions(peer),
          ),
        ),
        const SizedBox(height: 10),
      ],
      if (nearby.isNotEmpty) ...[
        if (peers.isNotEmpty) const SectionLabel('Nearby'),
        for (final d in nearby) ...[
          NearbyCard(device: d, onPair: () => pairNearby(context, app, d)),
          const SizedBox(height: 10),
        ],
      ],
    ]);
  }
}

class _PickChip extends StatelessWidget {
  const _PickChip({required this.icon, required this.label, required this.onTap, this.busy = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => ActionChip(
        avatar: busy
            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon, size: 18),
        label: Text(label),
        onPressed: onTap,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      );
}

class _AddDeviceMenu extends StatelessWidget {
  const _AddDeviceMenu({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      builder: (context, controller, _) => TextButton.icon(
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('Add device'),
      ),
      menuChildren: [
        if (Caps.canScanQr)
          MenuItemButton(
            leadingIcon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: () => scanAndPair(context, app),
            child: const Text('Scan QR code'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.qr_code_rounded),
          onPressed: () => showMyQr(context, app),
          child: const Text('Show my pairing code'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.lan_outlined),
          onPressed: () => pairByAddress(context, app),
          child: const Text('Enter IP address'),
        ),
      ],
    );
  }
}

class _ThisDeviceCard extends StatelessWidget {
  const _ThisDeviceCard({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = app.receiving && app.server.isRunning;
    return Card(
      color: on ? scheme.primary.withValues(alpha: 0.08) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
        child: Row(children: [
          DeviceAvatar(platform: app.identity.platform, name: app.identity.name, size: 48),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(app.identity.name, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Row(children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: on ? Colors.greenAccent.shade400 : scheme.outline, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    on ? 'Ready to receive' : 'Not receiving',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ]),
          ),
          IconButton.filledTonal(
            tooltip: 'Show pairing code',
            onPressed: on ? () => showMyQr(context, app) : null,
            icon: const Icon(Icons.qr_code_rounded),
          ),
          const SizedBox(width: 4),
          Switch(value: app.receiving, onChanged: app.setReceiving),
        ]),
      ),
    );
  }
}

/// Paths that still exist on disk (for re-sending dropped files etc).
List<String> existingPaths(Iterable<String> paths) => paths.where((p) => File(p).existsSync()).toList();

class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.app, required this.update});
  final AppController app;
  final UpdateInfo update;

  @override
  Widget build(BuildContext context) {
    final ios = Platform.isIOS;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.system_update_rounded, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Lucero Sync ${update.version} is available', style: Theme.of(context).textTheme.titleSmall),
            ),
          ]),
          if (ios)
            const Padding(
              padding: EdgeInsets.only(left: 36, top: 4),
              child: Text('Open AltStore or SideStore to update.'),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(spacing: 4, children: [
              TextButton(onPressed: app.dismissUpdate, child: const Text('Later')),
              TextButton(
                onPressed: () => openLink(update.url.toString()),
                child: Text(ios ? "What's new" : 'Download'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
