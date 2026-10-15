import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../core/models.dart';
import '../../core/platform.dart';
import '../format.dart';
import '../open.dart';
import '../theme.dart';
import '../widgets/common.dart';

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final active = app.shares.active.where((s) => s.isActive).toList();
        return PageScaffold(
          title: 'Activity',
          subtitle: 'Files and text you sent and received.',
          actions: [
            if (app.history.isNotEmpty)
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Clear activity?'),
                      content: const Text('This only clears the list. Received files stay where they are.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
                      ],
                    ),
                  );
                  if (ok == true) await app.clearHistory();
                },
                child: const Text('Clear'),
              ),
          ],
          children: [
            for (final p in app.incoming.values) ...[IncomingProgressCard(progress: p), const SizedBox(height: 10)],
            for (final s in active) ...[
              OutgoingShareCard(share: s, onCancel: () => app.shares.cancel(s)),
              const SizedBox(height: 10),
            ],
            if (app.history.isEmpty && active.isEmpty && app.incoming.isEmpty)
              const EmptyState(
                icon: Icons.swap_vert_rounded,
                title: 'Nothing here yet',
                body: 'Files and text you send or receive will appear here.',
              )
            else if (app.history.isNotEmpty) ...[
              if (Caps.isDesktop || Platform.isAndroid)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: Caps.isDesktop ? () => revealFolder(context, app.storage.receivedRoot.path) : null,
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: Text('Received files: ${app.storage.receivedLabel}', overflow: TextOverflow.ellipsis),
                  ),
                ),
              Card(
                child: Column(children: [
                  for (var i = 0; i < app.history.length; i++) ...[
                    if (i > 0) const Divider(indent: 64),
                    _HistoryTile(record: app.history[i]),
                  ],
                ]),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.record});
  final TransferRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final r = record;
    final incoming = r.direction == TransferDirection.incoming;
    final (statusText, statusColor) = switch (r.status) {
      TransferStatus.done => (incoming ? 'Received' : 'Sent', Brand.online),
      TransferStatus.failed => ('Failed', scheme.error),
      TransferStatus.declined => ('Declined', scheme.onSurfaceVariant),
      TransferStatus.cancelled => ('Cancelled', scheme.onSurfaceVariant),
    };
    final when = timeAgo(DateTime.fromMillisecondsSinceEpoch(r.createdAtMs));
    final who = '${incoming ? 'From' : 'To'} ${r.peerName}';
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(
          r.kind == TransferKind.text ? Icons.notes_rounded : (incoming ? Icons.south_west_rounded : Icons.north_east_rounded),
          color: scheme.primary,
          size: 20,
        ),
      ),
      title: Text(r.kind == TransferKind.text ? _preview(r.detail ?? '') : r.title, overflow: TextOverflow.ellipsis),
      subtitle: Text([who, if (r.size > 0) formatBytes(r.size), when].join(' · '), overflow: TextOverflow.ellipsis),
      trailing: Text(statusText, style: theme.textTheme.labelMedium?.copyWith(color: statusColor)),
      onTap: () => _open(context),
    );
  }

  String _preview(String text) => text.replaceAll('\n', ' ');

  void _open(BuildContext context) {
    final r = record;
    if (r.kind == TransferKind.text) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(r.direction == TransferDirection.incoming ? 'From ${r.peerName}' : 'To ${r.peerName}'),
          content: SizedBox(width: 420, child: SelectableText(r.detail ?? '')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            FilledButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: r.detail ?? ''));
                Navigator.pop(ctx);
              },
              child: const Text('Copy'),
            ),
          ],
        ),
      );
      return;
    }
    if (r.paths.isEmpty) {
      if (r.detail != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.detail!)));
      }
      return;
    }
    if (r.paths.length == 1) {
      openReceived(context, r.paths);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final path in r.paths)
            ListTile(
              leading: Icon(fileIcon(path)),
              title: Text(p.basename(path), overflow: TextOverflow.ellipsis),
              onTap: () => openReceived(ctx, [path]),
            ),
          if (Caps.isMobile)
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('Share or save all'),
              onTap: () => openReceived(ctx, r.paths),
            ),
        ]),
      ),
    );
  }
}
