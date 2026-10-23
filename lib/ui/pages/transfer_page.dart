import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models.dart';
import '../../core/platform.dart';
import '../../share/linux_airdrop.dart';
import '../../share/share_sender.dart';
import '../format.dart';
import '../open.dart';
import '../system_share.dart';
import '../theme.dart';

/// One transfer, file by file: overall progress, speed, time left, and the
/// state of every file. Works for both directions, and stays open with the
/// outcome after the transfer ends.
class TransferPage extends StatelessWidget {
  const TransferPage.outgoing({super.key, required this.app, required OutgoingShare this.share}) : incoming = null;
  const TransferPage.incoming({super.key, required this.app, required IncomingProgress this.incoming}) : share = null;

  final AppController app;
  final OutgoingShare? share;
  final IncomingProgress? incoming;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Incoming progress is reported through the controller.
      listenable: share ?? app,
      builder: (context, _) {
        final s = share;
        final i = incoming;
        final rows = s != null
            ? [for (final f in s.files) _Row(f.name, f.size, f.done ? f.size : f.sent)]
            : [for (final f in i!.files) _Row(f.name, f.size, i.fileBytes[f.id] ?? 0)];
        final total = rows.fold(0, (a, r) => a + r.size);
        final moved = rows.fold(0, (a, r) => a + r.moved.clamp(0, r.size));
        final rate = s?.rate ?? i!.rate;

        final (status, color, active) = s != null
            ? switch (s.state) {
                ShareState.preparing => ('Preparing…', null, true),
                ShareState.waitingForAccept => ('Waiting for ${s.peer.name} to accept…', null, true),
                ShareState.sending => ('Sending to ${s.peer.name}', null, true),
                ShareState.done => ('Sent to ${s.peer.name}', Brand.online, false),
                ShareState.declined => ('${s.peer.name} declined', Theme.of(context).colorScheme.error, false),
                ShareState.cancelled => ('Cancelled', null, false),
                ShareState.failed => (s.error ?? 'Failed', Theme.of(context).colorScheme.error, false),
              }
            : switch (i!.status) {
                null when i.stalled => ('Paused · waiting for ${i.fromName}', Brand.amber, true),
                null => ('Receiving from ${i.fromName}', null, true),
                TransferStatus.done => ('Received from ${i.fromName}', Brand.online, false),
                TransferStatus.cancelled => ('${i.fromName} cancelled', null, false),
                _ => ('Stopped', Theme.of(context).colorScheme.error, false),
              };
        final speed = rate.bytesPerSecond;
        final left = rate.timeLeft(total - moved);
        final theme = Theme.of(context);

        return Scaffold(
          appBar: AppBar(title: Text(s?.title ?? i!.title, overflow: TextOverflow.ellipsis)),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(status, style: theme.textTheme.titleMedium?.copyWith(color: color)),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: total == 0 || (active && moved == 0) ? null : (active ? moved / total : 1),
                          minHeight: 8,
                          color: active ? null : color,
                        ),
                      ),
                      const SizedBox(height: 10),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        child: Wrap(
                          spacing: 18,
                          runSpacing: 4,
                          children: [
                            Text('${formatBytes(moved)} of ${formatBytes(total)}'),
                            Text('${rows.where((r) => r.moved >= r.size).length} of ${rows.length} files'),
                            if (active && speed != null) Text('${formatBytes(speed.round())}/s'),
                            if (active && left != null) Text('${_duration(left)} left'),
                          ],
                        ),
                      ),
                      if (s != null && active) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () => app.shares.cancel(s),
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Cancel transfer'),
                        ),
                      ],
                      if (i != null && i.status == TransferStatus.done && i.paths.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          FilledButton.tonalIcon(
                            onPressed: () => openReceived(context, i.paths),
                            icon: const Icon(Icons.folder_open_rounded),
                            label: const Text('Show files'),
                          ),
                          // On phones "Show files" already opens the share sheet.
                          if (Caps.isDesktop)
                            FutureBuilder(
                              future: LinuxAirDrop.detect(),
                              builder: (context, tool) => switch (systemShareLabel(linuxAirDrop: tool.data != null)) {
                                final label? => OutlinedButton.icon(
                                    onPressed: () => shareElsewhere(context, paths: i.paths),
                                    icon: const Icon(Icons.wifi_tethering_rounded),
                                    label: Text(label),
                                  ),
                                null => const SizedBox.shrink(),
                              },
                            ),
                        ]),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    for (var n = 0; n < rows.length; n++) ...[
                      if (n > 0) const Divider(indent: 56, height: 1),
                      _FileTile(row: rows[n], active: active),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _duration(Duration d) => d.inHours > 0
      ? '${d.inHours} h ${d.inMinutes % 60} min'
      : d.inMinutes > 0
      ? '${d.inMinutes} min ${d.inSeconds % 60} s'
      : '${d.inSeconds} s';
}

class _Row {
  const _Row(this.name, this.size, this.moved);
  final String name;
  final int size;
  final int moved;
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.row, required this.active});
  final _Row row;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = row.moved >= row.size;
    final started = row.moved > 0;
    final name = row.name.split('/').last;
    final folder = row.name.contains('/') ? row.name.substring(0, row.name.lastIndexOf('/')) : null;
    return ListTile(
      leading: Icon(fileIcon(name), color: theme.colorScheme.onSurfaceVariant),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (folder != null) Text(folder, overflow: TextOverflow.ellipsis),
          Text(
            done
                ? formatBytes(row.size)
                : started
                ? '${formatBytes(row.moved)} of ${formatBytes(row.size)}'
                : active
                ? 'Waiting · ${formatBytes(row.size)}'
                : 'Not sent · ${formatBytes(row.size)}',
          ),
          if (started && !done) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: row.size == 0 ? null : row.moved / row.size, minHeight: 3),
          ],
        ],
      ),
      trailing: done
          ? const Icon(Icons.check_circle_rounded, color: Brand.online)
          : started && active
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
    );
  }
}
