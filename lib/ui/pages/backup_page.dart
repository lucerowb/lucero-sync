import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../backup/backup_engine.dart';
import '../../core/platform.dart';
import '../format.dart';
import '../open.dart';
import '../widgets/common.dart';

class BackupPage extends StatelessWidget {
  const BackupPage({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.backup, app.server]),
      builder: (context, _) => PageScaffold(
        title: 'Photo backup',
        subtitle: Caps.hasPhotoLibrary
            ? 'Copies your photo library to another device. Only new photos are sent.'
            : 'This computer can store backups from your phones.',
        children: [
          if (Caps.hasPhotoLibrary) ..._sender(context) else _receiverInfo(context),
          if (Caps.hasPhotoLibrary && app.server.totalReceived > 0) ...[
            const SectionLabel('Backups stored on this device'),
            _receiverInfo(context),
          ],
        ],
      ),
    );
  }

  List<Widget> _sender(BuildContext context) {
    final theme = Theme.of(context);
    final b = app.backup;
    final target = app.backupTarget;
    if (app.peers.isEmpty) {
      return [
        const EmptyState(
          icon: Icons.backup_outlined,
          title: 'Pair a device to back up to',
          body: 'Go to Share and pair the phone or computer that should keep your photos. '
              'It needs Lucero Sync open on the same Wi-Fi.',
        ),
      ];
    }
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            Text('Back up to', style: theme.textTheme.titleSmall),
            const SizedBox(width: 16),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: target?.deviceId,
                  hint: const Text('Choose a device'),
                  items: [
                    for (final p in app.peers)
                      DropdownMenuItem(
                        value: p.deviceId,
                        child: Row(children: [
                          Icon(platformIcon(p.platform), size: 18),
                          const SizedBox(width: 10),
                          Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                        ]),
                      ),
                  ],
                  onChanged: b.isRunning ? null : app.setBackupTarget,
                ),
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      if (target != null) _StatusCard(app: app),
      const SizedBox(height: 16),
      if (target != null)
        Row(children: [
          Expanded(
            child: b.isRunning
                ? OutlinedButton.icon(onPressed: b.cancel, icon: const Icon(Icons.stop_rounded), label: const Text('Stop'))
                : FilledButton.icon(
                    onPressed: app.runBackup,
                    icon: const Icon(Icons.backup_rounded),
                    label: const Text('Back up now'),
                  ),
          ),
          if (!b.isRunning && b.failedPermanently > 0) ...[
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () async {
                await app.db.retryFailed(target.deviceId);
                await app.backup.loadStats(target.deviceId);
              },
              child: Text('Retry ${b.failedPermanently} failed'),
            ),
          ],
        ]),
      const SectionLabel('Options'),
      Card(
        child: Column(children: [
          SwitchListTile(
            title: const Text('Include videos'),
            subtitle: const Text('Live Photos always include their motion clip'),
            value: app.includeVideos,
            onChanged: b.isRunning ? null : app.setIncludeVideos,
          ),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('Keep the app open while backing up'),
            subtitle: Text(Platform.isIOS
                ? 'iOS pauses apps in the background. The screen stays on during a backup; plug your phone in for large libraries.'
                : 'The screen stays on during a backup. Interrupted backups resume where they stopped.'),
          ),
        ]),
      ),
    ];
  }

  Widget _receiverInfo(BuildContext context) {
    final theme = Theme.of(context);
    final s = app.storage;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('${app.server.totalReceived}', style: theme.textTheme.headlineMedium),
            const SizedBox(width: 10),
            Expanded(child: Text('photos and videos stored here', style: theme.textTheme.bodyMedium)),
          ]),
          const SizedBox(height: 8),
          Text('Saved in ${s.backupsLabel}, sorted by year and month.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (!Caps.hasPhotoLibrary) ...[
            const SizedBox(height: 14),
            Text(
              'To back up a phone here: open Lucero Sync on the phone, pair it with "${app.identity.name}", '
              'then choose this computer under Photo backup.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
          if (Caps.isDesktop) ...[
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => revealFolder(context, s.backupsRoot.path),
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('Open backup folder'),
            ),
          ],
        ]),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final b = app.backup;
    final (headline, detail) = switch (b.phase) {
      BackupPhase.idle => (
          b.pending > 0 ? '${b.pending} waiting' : 'Ready',
          b.lastSyncedAt == null ? 'Not backed up yet' : 'Last backup ${timeAgo(DateTime.fromMillisecondsSinceEpoch(b.lastSyncedAt!))}'
        ),
      BackupPhase.scanning => ('Checking library…', '${b.scanned} items checked'),
      BackupPhase.waitingForPeer => ('Waiting for device', b.message ?? ''),
      BackupPhase.transferring => ('${b.pending} to go', 'Backing up to ${app.backupTarget?.name}'),
      BackupPhase.done => ('Up to date', b.message ?? 'Everything is backed up'),
      BackupPhase.cancelled => ('Paused', b.message ?? ''),
      BackupPhase.error => ('Stopped', b.message ?? 'Something went wrong'),
    };
    final ring = b.isRunning ? b.fraction : (b.phase == BackupPhase.done ? 1.0 : null);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Row(children: [
            SizedBox(
              width: 76,
              height: 76,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: b.isRunning ? ring : (ring ?? 0),
                    strokeWidth: 7,
                    backgroundColor: scheme.surfaceContainerHighest,
                    strokeCap: StrokeCap.round,
                  ),
                ),
                Icon(
                  b.phase == BackupPhase.done
                      ? Icons.check_rounded
                      : b.phase == BackupPhase.error
                          ? Icons.priority_high_rounded
                          : Icons.photo_library_outlined,
                  color: b.phase == BackupPhase.error ? scheme.error : scheme.primary,
                  size: 30,
                ),
              ]),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(headline, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(detail,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: b.phase == BackupPhase.error ? scheme.error : scheme.onSurfaceVariant)),
              ]),
            ),
          ]),
          if (b.currentFile != null) ...[
            const SizedBox(height: 18),
            Row(children: [
              Icon(fileIcon(b.currentFile!), size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(b.currentFile!, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
              Text(
                b.currentSize > 0 ? '${formatBytes(b.currentSent)} / ${formatBytes(b.currentSize)}' : '',
                style: theme.textTheme.bodySmall,
              ),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: b.currentSize > 0 ? b.currentSent / b.currentSize : null,
                minHeight: 5,
              ),
            ),
          ],
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 12),
          Row(children: [
            _Stat(label: 'Backed up', value: '${b.syncedTotal}'),
            _Stat(label: 'Sent now', value: '${b.storedThisRun}'),
            _Stat(label: 'Skipped', value: '${b.skippedThisRun}'),
            _Stat(label: 'Failed', value: '${b.failedThisRun + b.failedPermanently}'),
          ]),
        ]),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(children: [
        Text(value, style: theme.textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
