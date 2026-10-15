import 'package:flutter/material.dart';

import 'app_services.dart';
import 'ui/receive_page.dart';
import 'ui/send_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppServices.init();
  runApp(const LuceroSyncApp());
}

class LuceroSyncApp extends StatelessWidget {
  const LuceroSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lucero Sync',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Lucero Sync · ${AppServices.instance.identity.name}')),
      body: IndexedStack(index: _tab, children: const [SendPage(), ReceivePage()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.upload), label: 'Send'),
          NavigationDestination(icon: Icon(Icons.download), label: 'Receive'),
        ],
      ),
    );
  }
}
