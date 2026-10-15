import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/models.dart';
import 'app_controller.dart';

/// Menu bar (macOS) / system tray (Windows, Linux) for quick sharing and
/// progress, so the window can be closed while the app keeps receiving.
///
/// * The icon's title shows overall progress on macOS ("42%").
/// * The menu lists what's in flight, then "Send files to ▸ device",
///   "Send clipboard to ▸ device", receiving on/off, Open and Quit.
/// * Closing the window hides it; Quit is in the menu.
class DesktopTray with WindowListener {
  DesktopTray(this.app);

  final AppController app;
  static const _channel = MethodChannel('lucero_sync/permissions');

  TrayIcon? _icon;
  Menu? _menu;
  final _statusItems = <MenuItem>[];
  String _menuKey = '';
  Timer? _rebuild;

  Future<void> start() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    final icon = TrayIcon.create();
    if (icon == null) return; // no tray on this desktop (e.g. GNOME without AppIndicator)
    _icon = icon;
    if (Platform.isMacOS) {
      icon.icon = ImageAsset.fromAsset('assets/tray/tray_template.png');
      icon.isIconTemplate = true;
      icon.setContextMenuTrigger(ContextMenuTrigger.clicked);
    } else {
      icon.icon = ImageAsset.fromAsset('assets/tray/tray.png');
      icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      icon.addListener((e) {
        if (e is TrayIconClickedEvent) unawaited(showWindow());
      });
    }
    icon.setTooltip('Lucero Sync');
    icon.setVisible(true);

    app.addListener(_scheduleRebuild);
    app.live.addListener(_onLive);
    _buildMenu();
  }

  // ---- window -------------------------------------------------------------------

  @override
  void onWindowClose() => unawaited(windowManager.hide());

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    await windowManager.setPreventClose(false);
    _icon?.dispose();
    exit(0);
  }

  // ---- progress -----------------------------------------------------------------

  void _onLive() {
    final live = app.live.value;
    final icon = _icon;
    if (icon == null) return;
    final pct = live.fraction == null ? null : '${(live.fraction! * 100).round()}%';
    if (Platform.isMacOS) icon.setTitle(live.isEmpty ? null : (pct ?? '…'));
    icon.setTooltip(live.isEmpty ? 'Lucero Sync' : 'Lucero Sync · ${live.headline}${pct == null ? '' : ' · $pct'}');

    // The menu's status lines update in place; a different number of lines
    // needs a rebuild.
    final lines = _statusLines(live);
    if (lines.length != _statusItems.length) return _scheduleRebuild();
    for (var i = 0; i < lines.length; i++) {
      _statusItems[i].label = lines[i];
    }
  }

  List<String> _statusLines(LiveSummary live) {
    if (live.isEmpty) return ['Nothing in progress'];
    return [
      for (final i in live.items.take(5))
        '${i.direction == LiveDirection.sending ? '↑' : '↓'} ${i.backup ? 'Backup' : i.title} · '
            '${i.fraction == null ? i.status : '${(i.fraction! * 100).round()}%'}',
      if (live.items.length > 5) 'and ${live.items.length - 5} more',
    ];
  }

  // ---- menu ---------------------------------------------------------------------

  void _scheduleRebuild() {
    // Rebuild only when something the menu shows changed.
    final key = [
      app.receiving,
      for (final p in app.peers) '${p.deviceId}:${p.name}:${app.statusOf(p).name}',
      _statusLines(app.live.value).length,
    ].join('|');
    if (key == _menuKey) return;
    _rebuild?.cancel();
    _rebuild = Timer(const Duration(milliseconds: 300), _buildMenu);
  }

  MenuItem _item(String label, {void Function()? onClick, bool enabled = true, MenuItemType type = MenuItemType.normal}) {
    final item = MenuItem.createWithLabelAndType(label, type)!;
    item.isEnabled = enabled;
    if (onClick != null) {
      item.addListener((e) {
        if (e is MenuItemClickedEvent) onClick();
      });
    }
    return item;
  }

  void _buildMenu() {
    final icon = _icon;
    if (icon == null) return;
    _menuKey = [
      app.receiving,
      for (final p in app.peers) '${p.deviceId}:${p.name}:${app.statusOf(p).name}',
      _statusLines(app.live.value).length,
    ].join('|');

    final menu = Menu.create()!;
    _statusItems
      ..clear()
      ..addAll([for (final line in _statusLines(app.live.value)) _item(line, enabled: false)]);
    _statusItems.forEach(menu.addItem);
    menu.addSeparator();

    Menu devicesMenu(void Function(PeerDevice) onPick) {
      final sub = Menu.create()!;
      if (app.peers.isEmpty) sub.addItem(_item('No paired devices', enabled: false));
      for (final p in app.peers) {
        final online = app.statusOf(p) == PeerStatus.online;
        sub.addItem(_item(online ? p.name : '${p.name} (not nearby)', onClick: () => onPick(p)));
      }
      return sub;
    }

    final sendFiles = _item('Send files to', type: MenuItemType.submenu)..submenu = devicesMenu(_pickAndSend);
    final sendClip = _item('Send clipboard to', type: MenuItemType.submenu)..submenu = devicesMenu(_sendClipboard);
    menu
      ..addItem(sendFiles)
      ..addItem(sendClip)
      ..addSeparator()
      ..addItem(_item('Receiving', type: MenuItemType.checkbox, onClick: () => app.setReceiving(!app.receiving))
        ..state = app.receiving ? MenuItemState.checked : MenuItemState.unchecked)
      ..addItem(_item('Open Lucero Sync', onClick: () => unawaited(showWindow())))
      ..addSeparator()
      ..addItem(_item('Quit Lucero Sync', onClick: () => unawaited(_quit())));

    icon.setContextMenu(menu);
    _menu?.dispose();
    _menu = menu;
    _onLive();
  }

  Future<void> _pickAndSend(PeerDevice peer) async {
    if (Platform.isMacOS) {
      // A menu-bar app isn't frontmost; bring it forward so the panel shows on top.
      try {
        await _channel.invokeMethod('activateApp');
      } catch (_) {}
    }
    try {
      final files = await FilePicker.pickFiles(dialogTitle: 'Send to ${peer.name}');
      final paths = [for (final f in files) ?f.path];
      if (paths.isNotEmpty) app.sendFiles(peer, paths);
    } catch (e) {
      await showWindow();
    }
  }

  Future<void> _sendClipboard(PeerDevice peer) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.trim().isNotEmpty) app.sendText(peer, text);
  }
}
