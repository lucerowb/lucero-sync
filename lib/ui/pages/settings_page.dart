import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/app_controller.dart';
import '../../core/identity.dart';
import '../../core/platform.dart';
import '../../core/version.dart';
import '../../storage/storage.dart';
import '../format.dart';
import '../open.dart';
import '../pairing.dart';
import '../widgets/common.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});
  final AppController app;

  static const website = 'https://lucerosync.lucerowb.com';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final theme = Theme.of(context);
        return PageScaffold(
          title: 'Settings',
          children: [
            const SectionLabel('This device'),
            Card(
              child: Column(children: [
                ListTile(
                  leading: DeviceAvatar(platform: app.identity.platform, name: app.identity.name, size: 40),
                  title: Text(app.identity.name),
                  subtitle: const Text('Name shown to other devices'),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => _rename(context),
                ),
                const Divider(indent: 72),
                ListTile(
                  leading: const Icon(Icons.fingerprint_rounded),
                  title: const Text('Security fingerprint'),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: FingerprintText(fingerprint: app.identity.fingerprint),
                  ),
                ),
              ]),
            ),
            const SectionLabel('Receiving'),
            Card(
              child: Column(children: [
                SwitchListTile(
                  secondary: const Icon(Icons.wifi_tethering_rounded),
                  title: const Text('Receive files and backups'),
                  subtitle: Text(app.server.isRunning ? 'On · port ${app.server.port}' : 'Off'),
                  value: app.receiving,
                  onChanged: app.setReceiving,
                ),
                const Divider(indent: 72),
                ListTile(
                  leading: const Icon(Icons.qr_code_rounded),
                  title: const Text('Pair a new device'),
                  subtitle: const Text('Show a one-time QR code'),
                  onTap: app.server.isRunning ? () => showMyQr(context, app) : null,
                ),
                const Divider(indent: 72),
                ListTile(
                  leading: const Icon(Icons.help_outline_rounded),
                  title: const Text('Connection help'),
                  subtitle: const Text("Addresses and fixes if devices can't see each other"),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ConnectionHelpPage(app: app))),
                ),
              ]),
            ),
            const SectionLabel('Storage'),
            Card(
              child: Column(children: [
                _FolderTile(app: app, backups: true),
                const Divider(indent: 72),
                _FolderTile(app: app, backups: false),
                if (Platform.isAndroid) _AndroidAccessTile(app: app),
              ]),
            ),
            const SectionLabel('Paired devices'),
            if (app.peers.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.devices_rounded),
                  title: Text('No paired devices'),
                  subtitle: Text('Pair devices from the Share tab'),
                ),
              )
            else
              Card(
                child: Column(children: [
                  for (var i = 0; i < app.peers.length; i++) ...[
                    if (i > 0) const Divider(indent: 72),
                    ExpansionTile(
                      leading: DeviceAvatar(platform: app.peers[i].platform, name: app.peers[i].name, status: app.statusOf(app.peers[i]), size: 40),
                      title: Text(app.peers[i].name),
                      subtitle: Text(platformLabel(app.peers[i].platform)),
                      shape: const Border(),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Accept files automatically'),
                          value: app.peers[i].autoAccept,
                          onChanged: (v) => app.setAutoAccept(app.peers[i], v),
                        ),
                        Text('Fingerprint', style: theme.textTheme.labelSmall),
                        const SizedBox(height: 4),
                        FingerprintText(fingerprint: app.peers[i].fingerprint),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () => app.unpair(app.peers[i]),
                          icon: const Icon(Icons.link_off_rounded),
                          label: const Text('Remove device'),
                        ),
                      ],
                    ),
                  ],
                ]),
              ),
            const SectionLabel('About'),
            Card(
              child: Column(children: [
                const ListTile(
                  leading: Icon(Icons.auto_awesome_outlined),
                  title: Text('Lucero Sync'),
                  subtitle: Text('Version $appVersion · open source (MIT)'),
                ),
                const Divider(indent: 72),
                ListTile(
                  leading: const Icon(Icons.public_rounded),
                  title: const Text('Website & guide'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => openLink(website),
                ),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy policy'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => openLink('$website/privacy.html'),
                ),
                ListTile(
                  leading: const Icon(Icons.gavel_rounded),
                  title: const Text('Terms of use'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => openLink('$website/terms.html'),
                ),
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: const Text('Source code'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => openLink('https://github.com/lucerowb/lucero-sync'),
                ),
                ListTile(
                  leading: const Icon(Icons.article_outlined),
                  title: const Text('Open-source licences'),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Lucero Sync',
                    applicationVersion: appVersion,
                  ),
                ),
              ]),
            ),
          ],
        );
      },
    );
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: app.identity.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'e.g. Living-room Mac'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null) await app.rename(name);
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.app, required this.backups});
  final AppController app;
  final bool backups;

  @override
  Widget build(BuildContext context) {
    final s = app.storage;
    final dir = backups ? s.backupsRoot : s.receivedRoot;
    return ListTile(
      leading: Icon(backups ? Icons.photo_library_outlined : Icons.download_rounded),
      title: Text(backups ? 'Photo backups' : 'Received files'),
      subtitle: Text(backups ? s.backupsLabel : s.receivedLabel),
      onTap: Caps.isDesktop ? () => revealFolder(context, dir.path) : null,
      trailing: Storage.foldersConfigurable
          ? PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'change') {
                  final picked = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder');
                  if (picked != null) await app.setFolder(backups: backups, path: picked);
                } else if (v == 'reset') {
                  await app.setFolder(backups: backups, path: null);
                } else if (v == 'open' && context.mounted) {
                  await revealFolder(context, dir.path);
                }
              },
              itemBuilder: (_) => [
                if (Caps.isDesktop) const PopupMenuItem(value: 'open', child: Text('Open folder')),
                const PopupMenuItem(value: 'change', child: Text('Change folder…')),
                const PopupMenuItem(value: 'reset', child: Text('Use default')),
              ],
            )
          : null,
    );
  }
}

class _AndroidAccessTile extends StatefulWidget {
  const _AndroidAccessTile({required this.app});
  final AppController app;

  @override
  State<_AndroidAccessTile> createState() => _AndroidAccessTileState();
}

class _AndroidAccessTileState extends State<_AndroidAccessTile> {
  bool? granted;

  @override
  void initState() {
    super.initState();
    Storage.hasAllFilesAccess().then((v) => mounted ? setState(() => granted = v) : null);
  }

  @override
  Widget build(BuildContext context) {
    if (granted != false) return const SizedBox.shrink();
    return Column(children: [
      const Divider(indent: 72),
      ListTile(
        leading: const Icon(Icons.folder_special_outlined),
        title: const Text('Save to Pictures and Downloads'),
        subtitle: const Text('Grant "All files access" so received photos appear in your gallery.'),
        trailing: FilledButton.tonal(
          onPressed: () async {
            await Permission.manageExternalStorage.request();
            final ok = await Storage.hasAllFilesAccess();
            if (ok) await widget.app.reloadStorage();
            if (mounted) setState(() => granted = ok);
          },
          child: const Text('Grant'),
        ),
      ),
    ]);
  }
}

class _ConnectionHelpPage extends StatelessWidget {
  const _ConnectionHelpPage({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Connection help')),
      body: FutureBuilder<List<String>>(
        future: localIpv4s(),
        builder: (context, snap) {
          final ips = snap.data ?? const [];
          final port = app.server.port;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Column(children: [
                ListTile(
                  leading: Icon(app.server.isRunning ? Icons.check_circle_rounded : Icons.cancel_rounded,
                      color: app.server.isRunning ? Colors.green : theme.colorScheme.error),
                  title: Text(app.server.isRunning ? 'Receiving on port $port' : 'Receiving is off'),
                ),
                ListTile(
                  leading: const Icon(Icons.lan_outlined),
                  title: Text(ips.isEmpty ? 'No Wi-Fi or Ethernet address found' : ips.join('\n')),
                  subtitle: const Text('Use one of these with "Enter IP address" on the other device'),
                ),
                ListTile(
                  leading: const Icon(Icons.radar_rounded),
                  title: Text('${app.nearby.length} device${app.nearby.length == 1 ? '' : 's'} found nearby'),
                  trailing: TextButton(onPressed: app.refreshNetwork, child: const Text('Scan again')),
                ),
              ]),
            ),
            const SectionLabel("If devices can't see each other"),
            _tip(theme, Icons.wifi_rounded, 'Same network',
                'Both devices must be on the same Wi-Fi. Guest networks and "client/AP isolation" block devices from reaching each other.'),
            _tip(theme, Icons.vpn_lock_outlined, 'VPNs',
                'Turn off VPNs on both devices; many route local traffic away from your network.'),
            if (Platform.isIOS || Platform.isMacOS)
              _tip(theme, Icons.privacy_tip_outlined, 'Local Network permission',
                  'Settings › Privacy & Security › Local Network › Lucero Sync must be on.'),
            if (Platform.isWindows)
              _tip(theme, Icons.shield_outlined, 'Windows Firewall',
                  'Allow Lucero Sync on Private networks when Windows asks, and make sure your Wi-Fi is set to "Private", not "Public".'),
            if (Platform.isLinux)
              _tip(theme, Icons.shield_outlined, 'Firewall',
                  'Allow incoming TCP on port ${port ?? 8765} and mDNS (UDP 5353), e.g. `sudo ufw allow ${port ?? 8765}/tcp`.'),
            if (Platform.isAndroid)
              _tip(theme, Icons.battery_saver_outlined, 'Battery saver',
                  'Set Lucero Sync to "Unrestricted" battery use so Android doesn\'t pause it during transfers.'),
            _tip(theme, Icons.keyboard_alt_outlined, 'Still not found?',
                'Use "Enter IP address" with the address above. Discovery is a convenience; direct connections work without it.'),
            const SectionLabel('Recent log'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  app.logLines.isEmpty ? 'Nothing logged yet.' : app.logLines.take(60).join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _tip(ThemeData theme, IconData icon, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Card(child: ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(body))),
      );
}

String describeBytes(int b) => formatBytes(b);
