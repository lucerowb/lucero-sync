import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'pages/activity_page.dart';
import 'pages/backup_page.dart';
import 'pages/settings_page.dart';
import 'pages/share_page.dart';

/// Adaptive navigation: bottom bar on phones, rail on tablets, extended rail
/// (sidebar) on desktop-width windows.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.app});
  final AppController app;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;

  static const _destinations = [
    (Icons.ios_share_outlined, Icons.ios_share_rounded, 'Share'),
    (Icons.backup_outlined, Icons.backup_rounded, 'Backup'),
    (Icons.swap_vert_rounded, Icons.swap_vert_rounded, 'Activity'),
    (Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Networks change while an app is in the background; re-announce on return.
    if (state == AppLifecycleState.resumed) widget.app.refreshNetwork();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final pages = [
      SharePage(app: app),
      BackupPage(app: app),
      ActivityPage(app: app),
      SettingsPage(app: app),
    ];
    final width = MediaQuery.sizeOf(context).width;
    final body = IndexedStack(index: _index, children: pages);

    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final badge = app.incoming.length + app.shares.active.where((s) => s.isActive).length;
        Widget icon(int i, {bool selected = false}) {
          final d = _destinations[i];
          final child = Icon(selected ? d.$2 : d.$1);
          return i == 2 && badge > 0 ? Badge(label: Text('$badge'), child: child) : child;
        }

        if (width < 640) {
          return Scaffold(
            body: body,
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (var i = 0; i < _destinations.length; i++)
                  NavigationDestination(icon: icon(i), selectedIcon: icon(i, selected: true), label: _destinations[i].$3),
              ],
            ),
          );
        }

        final extended = width >= 1100;
        return Scaffold(
          body: Row(children: [
            NavigationRail(
              extended: extended,
              minExtendedWidth: 220,
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.fromLTRB(8, 20, 8, 20),
                child: extended
                    ? const Row(children: [_Logo(), SizedBox(width: 10), _Wordmark()])
                    : const _Logo(),
              ),
              destinations: [
                for (var i = 0; i < _destinations.length; i++)
                  NavigationRailDestination(
                    icon: icon(i),
                    selectedIcon: icon(i, selected: true),
                    label: Text(_destinations[i].$3),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Center(
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1240), child: body),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset('assets/icon/icon.png', width: 40, height: 40, fit: BoxFit.cover),
      );
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) =>
      Text('Lucero Sync', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800));
}
