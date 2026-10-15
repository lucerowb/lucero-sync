import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/app_controller.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'ui/widgets/prompt_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux) {
    // sqflite has no native plugin there; use the FFI build of SQLite.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const LuceroSyncApp());
}

class LuceroSyncApp extends StatefulWidget {
  const LuceroSyncApp({super.key});

  @override
  State<LuceroSyncApp> createState() => _LuceroSyncAppState();
}

class _LuceroSyncAppState extends State<LuceroSyncApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late Future<AppController> _boot = AppController.boot();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lucero Sync',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: FutureBuilder<AppController>(
        future: _boot,
        builder: (context, snap) {
          if (snap.hasError) {
            return _BootError(
              error: snap.error!,
              onRetry: () => setState(() => _boot = AppController.boot()),
            );
          }
          final app = snap.data;
          if (app == null) return const _Splash();
          return PromptHost(app: app, navigatorKey: _navigatorKey, child: AppShell(app: app));
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Image.asset('assets/icon/icon.png', width: 96, height: 96),
            const SizedBox(height: 24),
            const SizedBox(width: 120, child: LinearProgressIndicator()),
            const SizedBox(height: 12),
            Text('Preparing secure identity…', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
}

class _BootError extends StatelessWidget {
  const _BootError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.error_outline_rounded, size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              const Text('Lucero Sync could not start', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SelectableText('$error', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ]),
          ),
        ),
      );
}
