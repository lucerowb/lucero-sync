import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models.dart';
import '../../core/platform.dart';
import '../../share/share_sender.dart';
import '../format.dart';
import '../theme.dart';

/// Page scaffold with a large title, used by every top-level section.
class PageScaffold extends StatelessWidget {
  const PageScaffold({super.key, required this.title, this.subtitle, this.actions = const [], required this.children});

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 24, 12, 8),
          sliver: SliverToBoxAdapter(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.headlineMedium),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(subtitle!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ]),
              ),
              ...actions,
            ]),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          sliver: SliverList.list(children: children),
        ),
      ]),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Row(children: [
        Expanded(
          child: Text(text.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        ?trailing,
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.actions = const []});

  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, size: 30, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 20),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: actions),
          ],
        ]),
      ),
    );
  }
}

class DeviceAvatar extends StatelessWidget {
  const DeviceAvatar({super.key, required this.platform, this.name, this.status, this.size = 44});
  final String platform;
  final String? name;
  final PeerStatus? status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = switch (status) {
      PeerStatus.online => Brand.online,
      PeerStatus.identityChanged => scheme.error,
      _ => null,
    };
    return Stack(clipBehavior: Clip.none, children: [
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(size * 0.32)),
        child: Icon(platformIcon(platform, name: name), color: scheme.onSurface, size: size * 0.52),
      ),
      if (dot != null)
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle, border: Border.all(color: scheme.surface, width: 2.5)),
          ),
        ),
    ]);
  }
}

/// A paired device. [onTap] sends the current selection (or opens actions).
class PeerCard extends StatelessWidget {
  const PeerCard({super.key, required this.peer, required this.status, required this.onTap, this.highlight = false, this.menu});

  final PeerDevice peer;
  final PeerStatus status;
  final VoidCallback onTap;
  final bool highlight;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final subtitle = switch (status) {
      PeerStatus.online => 'Online · ${platformLabel(peer.platform)}',
      PeerStatus.offline => 'Not seen on this network · ${platformLabel(peer.platform)}',
      PeerStatus.identityChanged => 'Identity changed — re-pair to trust it',
    };
    return Card(
      color: highlight ? scheme.primary.withValues(alpha: 0.10) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: highlight ? scheme.primary.withValues(alpha: 0.6) : scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(children: [
            DeviceAvatar(platform: peer.platform, name: peer.name, status: status),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(peer.name, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: status == PeerStatus.identityChanged ? scheme.error : scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (peer.autoAccept)
              Tooltip(message: 'Files from this device are accepted automatically', child: Icon(Icons.verified_user_outlined, size: 18, color: scheme.onSurfaceVariant)),
            menu ?? const SizedBox(width: 8),
          ]),
        ),
      ),
    );
  }
}

class NearbyCard extends StatelessWidget {
  const NearbyCard({super.key, required this.device, required this.onPair});
  final NearbyDevice device;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant, style: BorderStyle.solid),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(children: [
          DeviceAvatar(platform: device.platform, name: device.name),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(device.name, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
              Text('Nearby · not paired',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
          FilledButton.tonal(onPressed: onPair, child: const Text('Pair')),
        ]),
      ),
    );
  }
}

/// Progress card for an outgoing share.
class OutgoingShareCard extends StatelessWidget {
  const OutgoingShareCard({super.key, required this.share, required this.onCancel});
  final OutgoingShare share;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: share,
      builder: (context, _) {
        final theme = Theme.of(context);
        final (label, color) = switch (share.state) {
          ShareState.preparing => ('Preparing…', null),
          ShareState.waitingForAccept => ('Waiting for ${share.peer.name} to accept…', null),
          ShareState.sending => ('Sending · ${formatBytes(share.sentBytes)} of ${formatBytes(share.totalBytes)}', null),
          ShareState.done => ('Sent to ${share.peer.name}', Brand.online),
          ShareState.declined => ('Declined by ${share.peer.name}', theme.colorScheme.error),
          ShareState.cancelled => ('Cancelled', theme.colorScheme.onSurfaceVariant),
          ShareState.failed => (share.error ?? 'Failed', theme.colorScheme.error),
        };
        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(share.text != null ? Icons.notes_rounded : Icons.north_east_rounded, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(share.title, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
                if (share.isActive) IconButton(tooltip: 'Cancel', onPressed: onCancel, icon: const Icon(Icons.close_rounded)),
              ]),
              const SizedBox(height: 6),
              if (share.isActive)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: share.state == ShareState.sending ? share.fraction : null,
                    minHeight: 6,
                  ),
                ),
              const SizedBox(height: 6),
              Text(label, style: theme.textTheme.bodySmall?.copyWith(color: color ?? theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
        );
      },
    );
  }
}

class IncomingProgressCard extends StatelessWidget {
  const IncomingProgressCard({super.key, required this.progress});
  final IncomingProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frac = progress.total == 0 ? null : progress.received / progress.total;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.south_west_rounded, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text('Receiving from ${progress.fromName}', style: theme.textTheme.titleSmall)),
          ]),
          const SizedBox(height: 10),
          ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: frac, minHeight: 6)),
          const SizedBox(height: 6),
          Text('${formatBytes(progress.received)} of ${formatBytes(progress.total)}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
