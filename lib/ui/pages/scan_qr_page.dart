import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/models.dart';

/// Pops with the [PairingPayload] read from another device's pairing QR code.
class ScanQrPage extends StatefulWidget {
  const ScanQrPage({super.key});

  @override
  State<ScanQrPage> createState() => _ScanQrPageState();
}

class _ScanQrPageState extends State<ScanQrPage> {
  bool _done = false;
  String? _hint;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: Stack(children: [
        MobileScanner(
          onDetect: (capture) {
            if (_done) return;
            for (final code in capture.barcodes) {
              final raw = code.rawValue;
              final payload = raw == null ? null : PairingPayload.decode(raw);
              if (payload != null) {
                _done = true;
                Navigator.of(context).pop(payload);
                return;
              }
              if (raw != null && raw.contains('lucerosync')) {
                setState(() => _hint = 'That code is from an older version. Update Lucero Sync on both devices.');
              }
            }
          },
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(16)),
            child: Text(
              _hint ?? 'Point the camera at the code shown under "Pair a new device" on the other device.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ]),
    );
  }
}
