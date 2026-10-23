import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../format.dart';
import '../open.dart';
import '../pages/transfer_page.dart';
import '../pairing.dart';

/// Shows the controller's pending prompts (pairing requests, file offers,
/// received text) one at a time, as dialogs above whatever page is open.
class PromptHost extends StatefulWidget {
  const PromptHost({super.key, required this.app, required this.navigatorKey, required this.child});

  final AppController app;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<PromptHost> createState() => _PromptHostState();
}

class _PromptHostState extends State<PromptHost> {
  AppPrompt? _showing;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_check);
  }

  @override
  void dispose() {
    widget.app.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (_showing != null || widget.app.prompts.isEmpty) return;
    final prompt = widget.app.prompts.first;
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    _showing = prompt;
    // Close the dialog if the prompt is resolved elsewhere (e.g. sender gave up).
    prompt.result.then((_) {
      if (_showing == prompt && widget.navigatorKey.currentState?.canPop() == true) {
        widget.navigatorKey.currentState!.pop();
      }
    });
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => switch (prompt) {
        PairingRequest() => PairingRequestDialog(request: prompt),
        ShareRequest() => _ShareRequestDialog(request: prompt),
        TextReceived() => _TextDialog(prompt: prompt),
        AirDropRequest() => _AirDropDialog(request: prompt),
      },
    ).whenComplete(() {
      prompt.answer(false); // no-op if already answered
      _showing = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
      if (prompt is ShareRequest) prompt.result.then((ok) => ok ? _openIncoming(prompt.prompt.offerId) : null);
    });
  }

  /// After Accept, show the file-by-file progress (the server registers the
  /// transfer just after it learns the answer).
  void _openIncoming(String offerId) {
    final app = widget.app;
    void open() {
      final p = app.incoming[offerId];
      if (p == null) return;
      app.removeListener(open);
      widget.navigatorKey.currentState
          ?.push(MaterialPageRoute<void>(builder: (_) => TransferPage.incoming(app: app, incoming: p)));
    }

    app.addListener(open);
    open();
    // Small transfers can finish before they're ever registered here.
    Future<void>.delayed(const Duration(seconds: 10), () => app.removeListener(open));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ShareRequestDialog extends StatefulWidget {
  const _ShareRequestDialog({required this.request});
  final ShareRequest request;

  @override
  State<_ShareRequestDialog> createState() => _ShareRequestDialogState();
}

class _ShareRequestDialogState extends State<_ShareRequestDialog> {
  @override
  Widget build(BuildContext context) {
    final p = widget.request.prompt;
    final theme = Theme.of(context);
    final shown = p.files.take(5).toList();
    return AlertDialog(
      icon: const Icon(Icons.move_to_inbox_rounded, size: 36),
      title: Text('${p.from.name} wants to send you '
          '${p.files.length == 1 ? 'a file' : '${p.files.length} files'}'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final f in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(fileIcon(f.name), size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis)),
                Text(formatBytes(f.size), style: theme.textTheme.bodySmall),
              ]),
            ),
          if (p.files.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('and ${p.files.length - shown.length} more', style: theme.textTheme.bodySmall),
            ),
          const Divider(height: 24),
          Text('Total ${formatBytes(p.totalBytes)}', style: theme.textTheme.bodyMedium),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: widget.request.alwaysAccept,
            onChanged: (v) => setState(() => widget.request.alwaysAccept = v ?? false),
            title: Text('Always accept from ${p.from.name}'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => widget.request.answer(false), child: const Text('Decline')),
        FilledButton(onPressed: () => widget.request.answer(true), child: const Text('Accept')),
      ],
    );
  }
}

class _AirDropDialog extends StatelessWidget {
  const _AirDropDialog({required this.request});
  final AirDropRequest request;

  @override
  Widget build(BuildContext context) {
    final a = request.ask;
    final theme = Theme.of(context);
    final shown = a.items.take(5).toList();
    return AlertDialog(
      icon: const Icon(Icons.wifi_tethering_rounded, size: 36),
      title: Text('${a.sender} wants to AirDrop you '
          '${a.items.length == 1 ? 'something' : '${a.items.length} items'}'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final name in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(fileIcon(name), size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
              ]),
            ),
          if (a.items.length > shown.length)
            Text('and ${a.items.length - shown.length} more', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Text(
            'Anyone nearby can send while AirDrop is on, so accept only what you expect.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => request.answer(false), child: const Text('Decline')),
        FilledButton(onPressed: () => request.answer(true), child: const Text('Accept')),
      ],
    );
  }
}

class _TextDialog extends StatelessWidget {
  const _TextDialog({required this.prompt});
  final TextReceived prompt;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(prompt.text.trim());
    final isLink = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && !prompt.text.trim().contains(' ');
    return AlertDialog(
      icon: const Icon(Icons.notes_rounded, size: 32),
      title: Text('Text from ${prompt.from.name}'),
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(child: SelectableText(prompt.text)),
        ),
      ),
      actions: [
        TextButton(onPressed: () => prompt.answer(true), child: const Text('Close')),
        if (isLink)
          TextButton(
            onPressed: () {
              openLink(prompt.text.trim());
              prompt.answer(true);
            },
            child: const Text('Open link'),
          ),
        FilledButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: prompt.text));
            prompt.answer(true);
          },
          child: const Text('Copy'),
        ),
      ],
    );
  }
}
