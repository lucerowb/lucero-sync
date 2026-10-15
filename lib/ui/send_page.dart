import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../core/models.dart';
import '../core/protocol.dart';
import '../discovery/discovery_service.dart';
import '../sender/sync_engine.dart';
import 'scan_qr_page.dart';

class SendPage extends StatefulWidget {
  const SendPage({super.key});

  @override
  State<SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<SendPage> {
  final _s = AppServices.instance;
  List<PeerInfo> _saved = [];
  final Map<String, DiscoveredPeer> _nearby = {};
  StreamSubscription<DiscoveredPeer>? _browse;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _loadPeers();
    _browse = _s.discovery.browse().listen(_onDiscovered);
  }

  @override
  void dispose() {
    _browse?.cancel();
    super.dispose();
  }

  Future<void> _loadPeers() async {
    final peers = await _s.db.listPeers();
    if (!mounted) return;
    setState(() {
      _saved = peers;
      _selectedId ??= peers.isEmpty ? null : peers.first.deviceId;
    });
  }

  Future<void> _onDiscovered(DiscoveredPeer p) async {
    setState(() {
      if (p.lost) {
        _nearby.remove(p.deviceId);
      } else {
        _nearby[p.deviceId] = p;
      }
    });
    if (p.lost) return;
    // Keep saved peers' addresses fresh when their IP changes.
    final saved = _saved.where((s) => s.deviceId == p.deviceId).firstOrNull;
    if (saved != null && (saved.host != p.host || saved.port != p.port)) {
      await _s.db.upsertPeer(saved.copyWith(host: p.host, port: p.port));
      await _loadPeers();
    }
  }

  PeerInfo? get _selected => _saved.where((p) => p.deviceId == _selectedId).firstOrNull;

  Future<void> _pair(String host, int port, String pin) async {
    try {
      final peer = await _s.client.pair(host, port, pin);
      await _s.db.upsertPeer(peer);
      _selectedId = peer.deviceId;
      await _loadPeers();
      _toast('Paired with ${peer.name}');
    } catch (e) {
      _toast('Pairing failed: $e');
    }
  }

  Future<void> _scanQr() async {
    final peer = await Navigator.of(context).push<PeerInfo>(
      MaterialPageRoute(builder: (_) => const ScanQrPage()),
    );
    if (peer != null) await _pair(peer.host, peer.port, peer.token);
  }

  Future<void> _manualOrPin({DiscoveredPeer? from}) async {
    final host = TextEditingController(text: from?.host ?? '');
    final port = TextEditingController(text: '${from?.port ?? Protocol.defaultPort}');
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(from == null ? 'Add receiver' : 'Pair with ${from.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (from == null) TextField(controller: host, decoration: const InputDecoration(labelText: 'IP address')),
          if (from == null)
            TextField(controller: port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
          TextField(controller: pin, decoration: const InputDecoration(labelText: 'PIN shown on receiver'), keyboardType: TextInputType.number),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pair')),
        ],
      ),
    );
    if (ok == true) {
      await _pair(host.text.trim(), int.tryParse(port.text) ?? Protocol.defaultPort, pin.text.trim());
    }
  }

  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final unpaired = _nearby.values.where((n) => !_saved.any((s) => s.deviceId == n.deviceId)).toList();

    return ListenableBuilder(
      listenable: _s.engine,
      builder: (context, _) {
        final e = _s.engine;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Receivers', style: Theme.of(context).textTheme.titleMedium),
            for (final p in _saved)
              ListTile(
                selected: p.deviceId == _selectedId,
                enabled: !e.isRunning,
                onTap: () => setState(() => _selectedId = p.deviceId),
                leading: Icon(p.deviceId == _selectedId ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                title: Text(p.name),
                subtitle: Text(_nearby.containsKey(p.deviceId) ? 'Online · ready to sync' : 'Not seen on this Wi-Fi yet'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: e.isRunning
                      ? null
                      : () async {
                          await _s.db.deletePeer(p.deviceId);
                          if (_selectedId == p.deviceId) _selectedId = null;
                          await _loadPeers();
                        },
                ),
              ),
            for (final n in unpaired)
              ListTile(
                leading: const Icon(Icons.wifi_tethering),
                title: Text(n.name),
                subtitle: const Text('Found on your Wi-Fi · tap to pair'),
                trailing: const Text('Pair'),
                onTap: () => _manualOrPin(from: n),
              ),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(onPressed: _scanQr, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan QR')),
              OutlinedButton.icon(onPressed: () => _manualOrPin(), icon: const Icon(Icons.edit), label: const Text('Enter IP')),
            ]),
            const Divider(height: 32),
            _ProgressCard(engine: e),
            const SizedBox(height: 12),
            if (e.isRunning)
              OutlinedButton.icon(onPressed: e.cancel, icon: const Icon(Icons.stop), label: const Text('Stop'))
            else
              FilledButton.icon(
                onPressed: _selected == null ? null : () => e.sync(_selected!),
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
              ),
            if (!e.isRunning && e.failedPermanently > 0 && _selected != null)
              TextButton(
                onPressed: () async {
                  await _s.db.retryFailed(_selected!.deviceId);
                  _toast('Failed items re-queued');
                },
                child: Text('Retry ${e.failedPermanently} failed item(s)'),
              ),
          ],
        );
      },
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final e = engine;
    final phase = switch (e.phase) {
      SyncPhase.idle => 'Idle',
      SyncPhase.scanning => 'Scanning library… ${e.scanned}',
      SyncPhase.waitingForPeer => 'Waiting for receiver…',
      SyncPhase.transferring => 'Transferring',
      SyncPhase.done => 'Up to date',
      SyncPhase.cancelled => 'Stopped',
      SyncPhase.error => 'Error',
    };
    final fileProgress = e.currentSize > 0 ? e.currentSent / e.currentSize : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(phase, style: Theme.of(context).textTheme.titleMedium),
          if (e.message != null) Text(e.message!),
          const SizedBox(height: 8),
          Text('Queued: ${e.pending} · Synced all-time: ${e.syncedTotal}'),
          Text('This run → sent ${e.storedThisRun}, skipped ${e.skippedThisRun}, failed ${e.failedThisRun}'),
          if (e.currentFile != null) ...[
            const SizedBox(height: 8),
            Text(e.currentFile!, overflow: TextOverflow.ellipsis),
            LinearProgressIndicator(value: fileProgress),
            Text('${_mb(e.currentSent)} / ${_mb(e.currentSize)} MB'),
          ],
        ]),
      ),
    );
  }

  String _mb(int b) => (b / (1024 * 1024)).toStringAsFixed(1);
}
