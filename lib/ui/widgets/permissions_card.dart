import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../theme.dart';

/// Settings › Permissions: what the app needs from the OS, whether it has it,
/// and a one-tap fix. Re-checks whenever the app returns from the background,
/// so changes made in system Settings show up immediately.
class PermissionsCard extends StatefulWidget {
  const PermissionsCard({super.key, this.onChanged});

  /// Called after a permission changes (e.g. to reload storage folders).
  final Future<void> Function()? onChanged;

  @override
  State<PermissionsCard> createState() => _PermissionsCardState();
}

class _PermissionsCardState extends State<PermissionsCard> with WidgetsBindingObserver {
  List<PermissionItem>? _items;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final before = _items?.map((i) => i.state).toList();
    final items = await Permissions.check();
    if (!mounted) return;
    setState(() => _items = items);
    if (before != null && before.join() != items.map((i) => i.state).join()) await widget.onChanged?.call();
  }

  Future<void> _fix(PermissionItem item) async {
    await Permissions.request(item);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) {
      return const Card(
        child: SizedBox(height: 72, child: Center(child: CircularProgressIndicator.adaptive())),
      );
    }
    if (items.isEmpty) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.verified_user_outlined, color: Brand.online),
          title: const Text('No permissions needed'),
          subtitle: Text(
            Platform.isWindows
                ? 'If other devices can\'t connect, allow Lucero Sync through Windows Firewall when asked, '
                      'and make sure your Wi-Fi is set to a Private network.'
                : 'If other devices can\'t connect, allow incoming connections to Lucero Sync in your firewall.',
          ),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(indent: 72),
            _PermissionTile(item: items[i], onFix: () => _fix(items[i])),
          ],
        ],
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({required this.item, required this.onFix});
  final PermissionItem item;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (item.state) {
      PermState.granted => ('Allowed', Brand.online),
      PermState.limited => ('Limited', Brand.amber),
      PermState.notDetermined => ('Not asked yet', theme.colorScheme.onSurfaceVariant),
      PermState.denied => ('Not allowed', item.required ? theme.colorScheme.error : Brand.amber),
      PermState.unknown => ('Check in Settings', theme.colorScheme.onSurfaceVariant),
    };
    final action = switch (item.state) {
      PermState.granted => null,
      PermState.notDetermined => 'Allow',
      PermState.limited => Platform.isIOS ? 'Select more' : 'Change',
      PermState.denied => item.id == 'files' ? 'Grant' : 'Open Settings',
      PermState.unknown => 'Open Settings',
    };
    // Custom layout rather than ListTile: a trailing button squeezes the
    // title to a single column on phones.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(item.icon, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(item.title, style: theme.textTheme.titleMedium),
                    _StatusChip(label: label, color: color),
                  ],
                ),
                const SizedBox(height: 4),
                Text(item.reason, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                if (action != null) ...[
                  const SizedBox(height: 10),
                  FilledButton.tonal(onPressed: onFix, child: Text(action)),
                ],
              ],
            ),
          ),
          if (action == null) ...[
            const SizedBox(width: 12),
            const Icon(Icons.check_circle_rounded, color: Brand.online),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
    );
  }
}
