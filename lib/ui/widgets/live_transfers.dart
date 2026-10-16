import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../backup/backup_engine.dart';
import '../../core/models.dart';
import '../format.dart';
import '../theme.dart';
import '../pages/transfer_page.dart';
import 'common.dart';

/// "In progress": every transfer in either direction, on both devices.
///
/// The sender sees its own progress; the receiver sees the same transfer from
/// its side (shares from byte counts, backups from the sender's status reports
/// plus the bytes of the file arriving). Renders nothing when idle.
class LiveTransfersSection extends StatelessWidget {
  const LiveTransfersSection({
    super.key,
    required this.app,
    this.label = 'In progress',
    this.includeBackupOut = true,
    this.backupsOnly = false,
  });
  final AppController app;
  final String label;
  final bool backupsOnly;

  /// The Backup page already shows the outgoing backup in detail.
  final bool includeBackupOut;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.backup]),
      builder: (context, _) {
        final outShares = app.shares.active.where((s) => s.isActive).toList();
        final inBackups = app.incomingBackups.values.toList();
        final backupOut = includeBackupOut && app.backup.isRunning;
        final cards = <Widget>[
          if (backupOut) _BackupOutCard(app: app),
          for (final b in inBackups) _BackupInCard(backup: b),
          if (!backupsOnly)
            for (final p in app.incoming.values)
              IncomingProgressCard(
                progress: p,
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => TransferPage.incoming(app: app, incoming: p))),
              ),
          if (!backupsOnly)
            for (final s in outShares)
              OutgoingShareCard(
                share: s,
                onCancel: () => app.shares.cancel(s),
                onTap: s.text != null
                    ? null
                    : () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => TransferPage.outgoing(app: app, share: s))),
              ),
        ];
        if (cards.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionLabel(label),
          for (var i = 0; i < cards.length; i++) ...[if (i > 0) const SizedBox(height: 10), cards[i]],
        ]);
      },
    );
  }
}

class _BackupOutCard extends StatelessWidget {
  const _BackupOutCard({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final b = app.backup;
    final target = app.backupTarget?.name ?? 'device';
    final done = b.storedThisRun + b.skippedThisRun + b.failedThisRun;
    final status = switch (b.phase) {
      BackupPhase.scanning => 'Scanning your library · ${b.scanned} found',
      BackupPhase.waitingForPeer => 'Waiting for $target to come online…',
      _ => '$done of ${done + b.pending}${b.currentFile != null ? ' · ${b.currentFile}' : ''}',
    };
    return _ProgressCard(
      icon: Icons.cloud_upload_outlined,
      title: 'Backing up photos to $target',
      status: status,
      fraction: b.phase == BackupPhase.transferring ? b.fraction : null,
      action: IconButton(tooltip: 'Stop backup', onPressed: b.cancel, icon: const Icon(Icons.stop_rounded)),
    );
  }
}

class _BackupInCard extends StatelessWidget {
  const _BackupInCard({required this.backup});
  final IncomingBackup backup;

  @override
  Widget build(BuildContext context) {
    final b = backup;
    final theme = Theme.of(context);
    final (status, color) = switch (b.state) {
      _ when b.stalled => ('Paused · waiting for ${b.fromName}', Brand.amber),
      BackupRunState.done => ('Backup complete · ${b.total} item${b.total == 1 ? '' : 's'} checked', Brand.online),
      BackupRunState.cancelled => ('Stopped on ${b.fromName}', theme.colorScheme.onSurfaceVariant),
      BackupRunState.error => ('Stopped with an error on ${b.fromName}', theme.colorScheme.error),
      BackupRunState.scanning => ('${b.fromName} is scanning its library…', null),
      BackupRunState.waiting => ('${b.fromName} is reconnecting…', null),
      BackupRunState.running => (
          [
            if (b.total > 0) '${b.done} of ${b.total}',
            if (b.file != null)
              b.fileSize > 0 ? '${b.file} · ${formatBytes(b.fileReceived)} of ${formatBytes(b.fileSize)}' : b.file!,
          ].join(' · '),
          null
        ),
    };
    return _ProgressCard(
      icon: Icons.cloud_download_outlined,
      title: 'Receiving photo backup from ${b.fromName}',
      status: status.isEmpty ? 'Receiving…' : status,
      statusColor: color,
      fraction: b.finished ? null : b.fraction,
      indeterminate: !b.finished && !b.stalled && b.fraction == null,
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.icon,
    required this.title,
    required this.status,
    this.fraction,
    this.statusColor,
    this.action,
    this.indeterminate = true,
  });
  final IconData icon;
  final String title;
  final String status;
  final double? fraction;
  final Color? statusColor;
  final Widget? action;
  final bool indeterminate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showBar = fraction != null || indeterminate;
    return Card(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, action == null ? 16 : 10, action == null ? 16 : 8, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
            ?action,
          ]),
          if (showBar) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: fraction, minHeight: 6),
            ),
          ],
          const SizedBox(height: 6),
          Text(status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: statusColor ?? theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
