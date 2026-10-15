import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_services.dart';
import '../core/identity.dart';
import '../core/models.dart';
import '../receiver/receiver_storage.dart';

class ReceivePage extends StatefulWidget {
  const ReceivePage({super.key});

  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> {
  final _s = AppServices.instance;
  String? _ip;
  bool _allFilesAccess = true;
  int _receivedTotal = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ip = await localIpv4();
    final access = !Platform.isAndroid || await ReceiverStorage.hasAllFilesAccess();
    final count = await _s.db.receivedCount();
    if (!mounted) return;
    setState(() {
      _ip = ip;
      _allFilesAccess = access;
      _receivedTotal = count;
    });
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      if (_s.receiver.isRunning) {
        await _s.discovery.stopAdvertising();
        await _s.receiver.stop();
        await WakelockPlus.disable();
      } else {
        await _s.receiver.start();
        await _s.discovery.startAdvertising(port: _s.receiver.port!);
        await WakelockPlus.enable(); // keep the server alive while screen is on
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestAllFiles() async {
    await Permission.manageExternalStorage.request();
    await _refresh();
    if (_s.receiver.isRunning) {
      // Re-open storage so it switches to the public Pictures folder.
      await _s.receiver.stop();
      await _s.receiver.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _s.receiver,
      builder: (context, _) {
        final r = _s.receiver;
        final running = r.isRunning;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_allFilesAccess)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_off),
                  title: const Text('Save to Pictures/LuceroSync'),
                  subtitle: const Text('Grant "All files access" so backups appear in your Gallery.'),
                  trailing: TextButton(onPressed: _requestAllFiles, child: const Text('Grant')),
                ),
              ),
            FilledButton.icon(
              onPressed: _busy ? null : _toggle,
              icon: Icon(running ? Icons.stop : Icons.play_arrow),
              label: Text(running ? 'Stop receiving' : 'Start receiving'),
            ),
            const SizedBox(height: 16),
            if (running && _ip != null) ...[
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(
                    data: PairingPayload.encode(
                      deviceId: _s.identity.deviceId,
                      name: _s.identity.name,
                      host: _ip!,
                      port: r.port!,
                      pin: _s.identity.pin,
                    ),
                    size: 220,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(child: Text('$_ip : ${r.port}', style: Theme.of(context).textTheme.titleMedium)),
              Center(
                child: Text('PIN ${_s.identity.pin}', style: Theme.of(context).textTheme.headlineSmall),
              ),
            ],
            if (running && _ip == null) const Text('Not on Wi-Fi? No local IPv4 address found.'),
            const SizedBox(height: 16),
            Text('Stored this session: ${r.storedThisSession} · skipped: ${r.skippedThisSession}'),
            Text('Total received: $_receivedTotal'),
            if (r.storage != null) Text('Folder: ${r.storage!.root.path}', style: Theme.of(context).textTheme.bodySmall),
            const Divider(height: 32),
            for (final line in r.log.take(50))
              Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        );
      },
    );
  }
}
