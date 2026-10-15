import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/models.dart';

/// Pops with a [PeerInfo] decoded from the receiver's pairing QR.
class ScanQrPage extends StatefulWidget {
  const ScanQrPage({super.key});

  @override
  State<ScanQrPage> createState() => _ScanQrPageState();
}

class _ScanQrPageState extends State<ScanQrPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan receiver QR')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final code in capture.barcodes) {
            final peer = code.rawValue == null ? null : PairingPayload.decode(code.rawValue!);
            if (peer != null) {
              _done = true;
              Navigator.of(context).pop(peer);
              return;
            }
          }
        },
      ),
    );
  }
}
