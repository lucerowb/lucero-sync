import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/app_controller.dart';
import '../core/models.dart';
import '../core/platform.dart';
import '../core/protocol.dart';
import '../net/peer_client.dart';
import '../security/tls_identity.dart';
import 'format.dart';
import 'pages/scan_qr_page.dart';
import 'theme.dart';

/// Pair with a device at [host]:[port]. Returns the new peer, or null if the
/// user cancelled or pairing failed (an error is shown).
Future<PeerDevice?> pairWith(
  BuildContext context,
  AppController app, {
  required String host,
  required int port,
  String? name,
  String? expectFp,
  String? qrSecret,
}) {
  return showDialog<PeerDevice>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PairingDialog(app: app, host: host, port: port, name: name, expectFp: expectFp, qrSecret: qrSecret),
  );
}

Future<void> scanAndPair(BuildContext context, AppController app) async {
  final payload = await Navigator.of(context).push<PairingPayload>(MaterialPageRoute(builder: (_) => const ScanQrPage()));
  if (payload == null || !context.mounted) return;
  final peer = await pairWith(context, app,
      host: payload.host,
      port: payload.port,
      name: payload.name,
      expectFp: payload.fingerprint,
      qrSecret: payload.secret);
  if (peer != null && context.mounted) _paired(context, peer);
}

Future<void> pairByAddress(BuildContext context, AppController app) async {
  final host = TextEditingController();
  final port = TextEditingController(text: '${Protocol.defaultPort}');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Add device by address'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Use this if the device doesn\'t appear automatically. The address is shown under '
            'Settings › Connection help on the other device.'),
        const SizedBox(height: 16),
        TextField(
          controller: host,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'IP address', hintText: '192.168.1.20'),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        TextField(controller: port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Connect')),
      ],
    ),
  );
  if (ok != true || !context.mounted || host.text.trim().isEmpty) return;
  final peer = await pairWith(context, app,
      host: host.text.trim(), port: int.tryParse(port.text.trim()) ?? Protocol.defaultPort);
  if (peer != null && context.mounted) _paired(context, peer);
}

Future<void> pairNearby(BuildContext context, AppController app, NearbyDevice d) async {
  final peer = await pairWith(context, app, host: d.host, port: d.port, name: d.name, expectFp: d.fingerprint);
  if (peer != null && context.mounted) _paired(context, peer);
}

void _paired(BuildContext context, PeerDevice peer) => ScaffoldMessenger.of(context)
    .showSnackBar(SnackBar(content: Text('Paired with ${peer.name}. You can now send files both ways.')));

enum _Step { connecting, compare, waiting, done, failed }

class _PairingDialog extends StatefulWidget {
  const _PairingDialog({
    required this.app,
    required this.host,
    required this.port,
    this.name,
    this.expectFp,
    this.qrSecret,
  });

  final AppController app;
  final String host;
  final int port;
  final String? name;
  final String? expectFp;
  final String? qrSecret;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  _Step step = _Step.connecting;
  OutgoingPairing? pairing;
  String? error;
  bool userConfirmed = false;
  bool remoteApproved = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final p = await widget.app.beginPairing(widget.host, widget.port,
          expectFp: widget.expectFp, qrSecret: widget.qrSecret);
      pairing = p;
      if (p.viaQr) {
        // The QR code already proved who the other device is.
        await p.waitForApproval();
        userConfirmed = remoteApproved = true;
        await _finish();
        return;
      }
      setState(() => step = _Step.compare);
      await p.waitForApproval();
      remoteApproved = true;
      if (userConfirmed) await _finish();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _onCodesMatch() async {
    setState(() {
      userConfirmed = true;
      step = _Step.waiting;
    });
    if (remoteApproved) await _finish();
  }

  Future<void> _finish() async {
    try {
      final peer = await widget.app.finishPairing(pairing!);
      if (mounted) Navigator.pop(context, peer);
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      step = _Step.failed;
      error = e is IdentityMismatchException
          ? 'This device presented a different identity than expected, so the connection was stopped. '
              'If it was reinstalled, that is normal: remove it and pair again. Otherwise, someone may be '
              'impersonating it.'
          : e is PairingDeclinedException
              ? e.toString()
              : "Couldn't reach ${widget.name ?? widget.host}. Make sure Lucero Sync is open on it and both "
                  'devices are on the same Wi-Fi.';
    });
  }

  Future<void> _cancel() async {
    await pairing?.cancel();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = pairing?.remote.name ?? widget.name ?? widget.host;
    return AlertDialog(
      title: Text(step == _Step.failed ? 'Pairing failed' : 'Pair with $name'),
      content: SizedBox(
        width: 380,
        child: switch (step) {
          _Step.connecting || _Step.done => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Row(children: [
                SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                SizedBox(width: 16),
                Expanded(child: Text('Connecting securely…')),
              ]),
            ),
          _Step.compare || _Step.waiting => Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Check that $name shows the same code:', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 20),
              _CodeDisplay(code: pairing!.code),
              const SizedBox(height: 20),
              Text(
                step == _Step.waiting
                    ? (remoteApproved ? 'Finishing…' : 'Now tap Accept on $name.')
                    : 'Only continue if the codes match exactly. If they don\'t, someone may be intercepting the connection.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ]),
          _Step.failed => Text(error ?? 'Something went wrong.'),
        },
      ),
      actions: switch (step) {
        _Step.compare => [
            TextButton(onPressed: _cancel, child: const Text("Codes don't match")),
            FilledButton(onPressed: _onCodesMatch, child: const Text('Codes match')),
          ],
        _Step.failed => [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
        _ => [TextButton(onPressed: _cancel, child: const Text('Cancel'))],
      },
    );
  }
}

class _CodeDisplay extends StatelessWidget {
  const _CodeDisplay({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
      ),
      child: Text(
        code,
        style: TextStyle(
          fontSize: 40,
          fontWeight: FontWeight.w800,
          letterSpacing: 6,
          color: scheme.primary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Receiver side: someone wants to pair. Shown by the prompt host.
class PairingRequestDialog extends StatelessWidget {
  const PairingRequestDialog({super.key, required this.request});
  final PairingRequest request;

  @override
  Widget build(BuildContext context) {
    final p = request.prompt;
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(platformIcon(p.platform), size: 36),
      title: Text('Pair with ${p.name}?'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Make sure ${p.name} shows this same code:', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          _CodeDisplay(code: p.code),
          const SizedBox(height: 20),
          Text(
            'Paired devices can send you files and back up photos to this device.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => request.answer(false), child: const Text("Codes don't match")),
        FilledButton(onPressed: () => request.answer(true), child: const Text('Accept')),
      ],
    );
  }
}

/// This device's pairing QR code (one-time secret + pinned fingerprint).
Future<void> showMyQr(BuildContext context, AppController app) => showDialog<void>(
      context: context,
      builder: (_) => _MyQrDialog(app: app),
    );

class _MyQrDialog extends StatefulWidget {
  const _MyQrDialog({required this.app});
  final AppController app;

  @override
  State<_MyQrDialog> createState() => _MyQrDialogState();
}

class _MyQrDialogState extends State<_MyQrDialog> {
  PairingPayload? payload;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    widget.app.removeListener(_refresh);
    super.dispose();
  }

  /// Regenerates after the code is used, so the next device gets a fresh one.
  Future<void> _refresh() async {
    final p = await widget.app.pairingPayload();
    if (!mounted) return;
    if (p?.secret != payload?.secret || loading) {
      setState(() {
        payload = p;
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = widget.app;
    return AlertDialog(
      title: const Text('Pair a new device'),
      content: SizedBox(
        width: 340,
        child: loading
            ? const SizedBox(height: 280, child: Center(child: CircularProgressIndicator()))
            : payload == null
                ? Text(app.receiving
                    ? 'No Wi-Fi address found. Connect to Wi-Fi and try again.'
                    : 'Turn on Receiving first, so the other device can reach this one.')
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      Caps.isDesktop
                          ? 'On your phone, open Lucero Sync › Share › Scan QR.'
                          : 'On the other device, open Lucero Sync and tap Scan QR.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                      child: QrImageView(
                        data: payload!.encode(),
                        size: 240,
                        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Brand.ink),
                        dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Brand.ink),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(app.identity.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text('${payload!.host} : ${payload!.port}', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Text(
                      'This code works once and expires after 10 minutes.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}

/// Fingerprint row with copy action, for settings and device details.
class FingerprintText extends StatelessWidget {
  const FingerprintText({super.key, required this.fingerprint});
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Clipboard.setData(ClipboardData(text: fingerprint));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fingerprint copied')));
      },
      child: Text(
        formatFingerprint(fingerprint, groups: 16),
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.5),
      ),
    );
  }
}
