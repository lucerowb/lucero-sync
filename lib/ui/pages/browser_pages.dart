import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/identity.dart';
import '../format.dart';
import '../open.dart';
import '../pairing.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Settings › Web access: let any browser on the network send and fetch files.
class WebAccessPage extends StatelessWidget {
  const WebAccessPage({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final web = app.webAccess;
    return Scaffold(
      appBar: AppBar(title: const Text('Web access')),
      body: ListenableBuilder(
        listenable: Listenable.merge([web, app.server]),
        builder: (context, _) {
          final theme = Theme.of(context);
          final dim = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: SwitchListTile(
                secondary: const Icon(Icons.language_rounded),
                title: const Text('Allow browsers on this network'),
                subtitle: Text(!app.server.isRunning
                    ? 'Turn on receiving first'
                    : web.enabled
                        ? 'On until you turn it off or close the app'
                        : 'Off'),
                value: web.enabled,
                onChanged: app.server.isRunning ? web.setEnabled : null,
              ),
            ),
            if (!web.enabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
                child: Text(
                  'Use any computer or phone without the app: open an address in Chrome, Firefox, Safari or Edge, '
                  'enter a code shown here, then send files to this device or download files you offer. '
                  'Everything stays on your Wi-Fi.',
                  style: dim,
                ),
              )
            else ...[
              const SectionLabel('1 · Open in a browser'),
              FutureBuilder<List<String>>(
                future: localIpv4s(),
                builder: (context, snap) {
                  final urls = [for (final ip in snap.data ?? const <String>[]) 'https://$ip:${app.server.port}'];
                  return Card(
                    child: Column(children: [
                      if (urls.isEmpty)
                        const ListTile(
                            leading: Icon(Icons.wifi_off_rounded), title: Text('No Wi-Fi or Ethernet address found')),
                      for (final u in urls)
                        ListTile(
                          leading: const Icon(Icons.link_rounded),
                          title: SelectableText(u, style: theme.textTheme.titleMedium),
                          trailing: IconButton(
                            tooltip: 'Copy',
                            icon: const Icon(Icons.copy_rounded),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: u));
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Address copied')));
                            },
                          ),
                        ),
                    ]),
                  );
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                child: Text(
                  'The browser will warn that the connection isn\'t private. That\'s because this device uses its own '
                  'certificate instead of one from the internet. The connection is still encrypted. To be sure it\'s '
                  'this device, compare the certificate\'s SHA-256 fingerprint in the browser with this one, then continue:',
                  style: dim,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: FingerprintText(fingerprint: app.identity.fingerprint),
              ),
              const SectionLabel('2 · Enter this code'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 8, 18),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        '${web.code.substring(0, 3)} ${web.code.substring(3)}',
                        style: theme.textTheme.displaySmall?.copyWith(color: Brand.amber, letterSpacing: 4),
                      ),
                    ),
                    TextButton.icon(
                        onPressed: web.newCode, icon: const Icon(Icons.refresh_rounded), label: const Text('New code')),
                  ]),
                ),
              ),
              SectionLabel(
                'Send to browser',
                trailing: TextButton.icon(
                  onPressed: () async {
                    try {
                      final files = await FilePicker.pickFiles();
                      web.addToOutbox([for (final f in files) ?f.path]);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't open the picker: $e")));
                      }
                    }
                  },
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add files'),
                ),
              ),
              Card(
                child: Column(children: [
                  if (web.outbox.isEmpty)
                    const ListTile(
                      leading: Icon(Icons.download_rounded),
                      title: Text('Nothing offered yet'),
                      subtitle: Text('Files you add here can be downloaded by signed-in browsers.'),
                    ),
                  for (final o in web.outbox)
                    ListTile(
                      leading: Icon(fileIcon(o.name)),
                      title: Text(o.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(formatBytes(o.size)),
                      trailing: IconButton(
                          tooltip: 'Stop offering',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => web.removeFromOutbox(o.id)),
                    ),
                ]),
              ),
              const SectionLabel('Signed-in browsers'),
              Card(
                child: Column(children: [
                  if (web.sessions.isEmpty) const ListTile(leading: Icon(Icons.public_off_rounded), title: Text('None yet')),
                  for (final s in web.sessions.values)
                    ListTile(
                      leading: const Icon(Icons.public_rounded),
                      title: Text(s.label),
                      subtitle: Text('${s.address} · active ${timeAgo(s.lastSeen)}'),
                      trailing: TextButton(onPressed: () => web.endSession(s.token), child: const Text('Sign out')),
                    ),
                ]),
              ),
            ],
          ]);
        },
      ),
    );
  }
}

/// Settings › Browser extension (desktop): connect the Chrome/Firefox extension.
class ExtensionPage extends StatelessWidget {
  const ExtensionPage({super.key, required this.app});
  final AppController app;

  static const releases = 'https://github.com/lucerowb/lucero-sync/releases/latest';

  @override
  Widget build(BuildContext context) {
    final api = app.localApi;
    return Scaffold(
      appBar: AppBar(title: const Text('Browser extension')),
      body: api == null
          ? const Center(child: Text('The extension connection could not start on this computer.'))
          : ListenableBuilder(
              listenable: api,
              builder: (context, _) {
                final theme = Theme.of(context);
                final dim = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
                return ListView(padding: const EdgeInsets.all(16), children: [
                  Text(
                    'Right-click a link, image, selection or page in Chrome, Edge, Brave or Firefox and send it to '
                    'any paired device. The extension only talks to this app, on this computer.',
                    style: dim,
                  ),
                  const SectionLabel('1 · Install'),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.extension_rounded),
                      title: const Text('Download the extension'),
                      subtitle: const Text('lucero-sync-chrome.zip or lucero-sync-firefox.zip from the latest release'),
                      trailing: const Icon(Icons.open_in_new_rounded),
                      onTap: () => openLink(releases),
                    ),
                  ),
                  const SectionLabel('2 · Connect'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (api.connectCode == null) ...[
                          Text('Get a code, then enter it in the extension\'s popup.', style: dim),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: api.issueCode,
                            icon: const Icon(Icons.link_rounded),
                            label: const Text('Connect a browser'),
                          ),
                        ] else ...[
                          Text('Enter this code in the extension (valid for 10 minutes):', style: dim),
                          const SizedBox(height: 8),
                          Text('${api.connectCode!.substring(0, 3)} ${api.connectCode!.substring(3)}',
                              style: theme.textTheme.displaySmall?.copyWith(color: Brand.amber, letterSpacing: 4)),
                        ],
                      ]),
                    ),
                  ),
                  const SectionLabel('Connected'),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.verified_user_outlined),
                      title: Text(api.connectedCount == 0
                          ? 'No browsers connected'
                          : '${api.connectedCount} browser${api.connectedCount == 1 ? '' : 's'} connected'),
                      subtitle: Text('Listening on 127.0.0.1:${api.port}, not reachable from the network'),
                      trailing: api.connectedCount == 0
                          ? null
                          : TextButton(onPressed: api.disconnectAll, child: const Text('Disconnect all')),
                    ),
                  ),
                ]);
              },
            ),
    );
  }
}
