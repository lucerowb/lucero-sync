import 'core/db.dart';
import 'core/identity.dart';
import 'discovery/discovery_service.dart';
import 'receiver/receiver_server.dart';
import 'sender/library_scanner.dart';
import 'sender/sync_engine.dart';
import 'sender/transfer_client.dart';

/// Wires the app together once at startup. Every device has both roles.
class AppServices {
  AppServices._(this.db, this.identity, this.discovery, this.client, this.engine, this.receiver);

  static late final AppServices instance;

  final AppDatabase db;
  final DeviceIdentity identity;
  final DiscoveryService discovery;
  final TransferClient client;
  final SyncEngine engine;
  final ReceiverServer receiver;

  static Future<void> init() async {
    final db = await AppDatabase.open();
    final identity = await DeviceIdentity.load(db);
    final discovery = DiscoveryService(identity);
    final client = TransferClient(identity);
    final engine = SyncEngine(db, LibraryScanner(), client, discovery);
    final receiver = ReceiverServer(db, identity);
    instance = AppServices._(db, identity, discovery, client, engine, receiver);
  }
}
