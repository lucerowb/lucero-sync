import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Single SQLite database used by both roles. A device that only sends never
/// touches the receiver tables and vice versa.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  static const _version = 1;

  static const _schema = [
    // Small key/value store: device id, PIN, display name.
    '''CREATE TABLE kv (
         key   TEXT PRIMARY KEY,
         value TEXT NOT NULL
       )''',

    // ---- Sender side -------------------------------------------------------

    // Receivers this device has paired with (PIN = token).
    '''CREATE TABLE peers (
         device_id TEXT PRIMARY KEY,
         name      TEXT NOT NULL,
         host      TEXT NOT NULL,
         port      INTEGER NOT NULL,
         token     TEXT NOT NULL,
         last_seen INTEGER
       )''',

    // The "already synced" ledger. Keyed per peer so one phone can back up to
    // several receivers independently. asset_id is the PHAsset localIdentifier
    // (iOS) or MediaStore id (Android) — stable across app launches.
    '''CREATE TABLE synced_assets (
         peer_id    TEXT NOT NULL,
         asset_id   TEXT NOT NULL,
         sha256     TEXT NOT NULL,
         filename   TEXT NOT NULL,
         size       INTEGER NOT NULL,
         created_at INTEGER NOT NULL,
         result     TEXT NOT NULL,        -- stored | skipped (receiver already had it)
         synced_at  INTEGER NOT NULL,
         PRIMARY KEY (peer_id, asset_id)
       )''',
    'CREATE INDEX idx_synced_sha ON synced_assets (peer_id, sha256)',

    // Persistent work queue. Survives app kills, so a sync resumes exactly
    // where it stopped. filename/size/sha256 are filled lazily on first
    // attempt (hashing the whole library up front would take hours).
    '''CREATE TABLE sync_queue (
         peer_id     TEXT NOT NULL,
         asset_id    TEXT NOT NULL,
         created_at  INTEGER NOT NULL,
         filename    TEXT,
         size        INTEGER,
         sha256      TEXT,
         status      TEXT NOT NULL DEFAULT 'pending', -- pending | uploading | failed
         attempts    INTEGER NOT NULL DEFAULT 0,
         last_error  TEXT,
         enqueued_at INTEGER NOT NULL,
         updated_at  INTEGER NOT NULL,
         PRIMARY KEY (peer_id, asset_id)
       )''',
    'CREATE INDEX idx_queue_next ON sync_queue (peer_id, status, attempts, created_at)',

    // ---- Receiver side -----------------------------------------------------

    // Everything committed to the destination folder. Both keys are indexed:
    // sha256 for exact content match, meta_key (filename|created|size) as the
    // metadata fallback from the spec.
    '''CREATE TABLE received_files (
         sha256      TEXT PRIMARY KEY,
         meta_key    TEXT NOT NULL,
         filename    TEXT NOT NULL,
         rel_path    TEXT NOT NULL,
         size        INTEGER NOT NULL,
         created_at  INTEGER NOT NULL,
         sender_id   TEXT NOT NULL,
         received_at INTEGER NOT NULL
       )''',
    'CREATE INDEX idx_received_meta ON received_files (meta_key)',
  ];

  static Future<AppDatabase> open() async {
    final path = p.join(await getDatabasesPath(), 'lucero_sync.db');
    final db = await openDatabase(
      path,
      version: _version,
      onConfigure: (db) => db.rawQuery('PRAGMA journal_mode=WAL'),
      onCreate: (db, _) async {
        for (final stmt in _schema) {
          await db.execute(stmt);
        }
      },
    );
    return AppDatabase._(db);
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  // ---- kv ------------------------------------------------------------------

  Future<String?> getValue(String key) async {
    final rows = await _db.query('kv', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setValue(String key, String value) => _db.insert(
        'kv',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // ---- peers ---------------------------------------------------------------

  Future<void> upsertPeer(PeerInfo peer) =>
      _db.insert('peers', peer.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<PeerInfo>> listPeers() async {
    final rows = await _db.query('peers', orderBy: 'last_seen DESC');
    return rows.map(PeerInfo.fromRow).toList();
  }

  Future<void> deletePeer(String deviceId) =>
      _db.delete('peers', where: 'device_id = ?', whereArgs: [deviceId]);

  // ---- sender: ledger + queue ----------------------------------------------

  Future<Set<String>> syncedAssetIds(String peerId) async {
    final rows = await _db.query(
      'synced_assets',
      columns: ['asset_id'],
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
    return {for (final r in rows) r['asset_id'] as String};
  }

  /// Adds assets to the queue; rows already queued are left untouched so their
  /// attempt count and cached hash survive.
  Future<void> enqueue(String peerId, Iterable<({String assetId, int createdAtMs})> assets) async {
    final now = _now;
    final batch = _db.batch();
    for (final a in assets) {
      batch.insert(
        'sync_queue',
        {
          'peer_id': peerId,
          'asset_id': a.assetId,
          'created_at': a.createdAtMs,
          'enqueued_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// After a crash/kill, anything left "uploading" is really just pending.
  Future<void> resetInterruptedUploads(String peerId) => _db.update(
        'sync_queue',
        {'status': QueueStatus.pending.name},
        where: 'peer_id = ? AND status = ?',
        whereArgs: [peerId, QueueStatus.uploading.name],
      );

  /// Oldest photos first; items that already failed sink to the back.
  Future<QueueItem?> nextQueueItem(String peerId, {required int maxAttempts}) async {
    final rows = await _db.query(
      'sync_queue',
      where: 'peer_id = ? AND status IN (?, ?) AND attempts < ?',
      whereArgs: [peerId, QueueStatus.pending.name, QueueStatus.failed.name, maxAttempts],
      orderBy: 'attempts ASC, created_at ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : QueueItem.fromRow(rows.first);
  }

  Future<void> markUploading(QueueItem item, {String? filename, int? size, String? sha256}) =>
      _db.update(
        'sync_queue',
        {
          'status': QueueStatus.uploading.name,
          if (filename != null) 'filename': filename,
          if (size != null) 'size': size,
          if (sha256 != null) 'sha256': sha256,
          'updated_at': _now,
        },
        where: 'peer_id = ? AND asset_id = ?',
        whereArgs: [item.peerId, item.assetId],
      );

  Future<void> markFailed(QueueItem item, String error, {required bool countAttempt}) =>
      _db.rawUpdate(
        'UPDATE sync_queue SET status = ?, last_error = ?, updated_at = ?, '
        'attempts = attempts + ? WHERE peer_id = ? AND asset_id = ?',
        [QueueStatus.failed.name, error, _now, countAttempt ? 1 : 0, item.peerId, item.assetId],
      );

  Future<void> dropQueueItem(QueueItem item) => _db.delete(
        'sync_queue',
        where: 'peer_id = ? AND asset_id = ?',
        whereArgs: [item.peerId, item.assetId],
      );

  /// Atomically records the asset as synced and removes it from the queue.
  Future<void> markSynced(QueueItem item, FileDescriptor file, String result) =>
      _db.transaction((txn) async {
        await txn.insert(
          'synced_assets',
          {
            'peer_id': item.peerId,
            'asset_id': item.assetId,
            'sha256': file.sha256,
            'filename': file.filename,
            'size': file.size,
            'created_at': file.createdAtMs,
            'result': result,
            'synced_at': _now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.delete(
          'sync_queue',
          where: 'peer_id = ? AND asset_id = ?',
          whereArgs: [item.peerId, item.assetId],
        );
      });

  Future<({int pending, int failed, int synced})> queueStats(String peerId, {required int maxAttempts}) async {
    final pending = Sqflite.firstIntValue(await _db.rawQuery(
          'SELECT COUNT(*) FROM sync_queue WHERE peer_id = ? AND attempts < ?',
          [peerId, maxAttempts],
        )) ??
        0;
    final failed = Sqflite.firstIntValue(await _db.rawQuery(
          'SELECT COUNT(*) FROM sync_queue WHERE peer_id = ? AND attempts >= ?',
          [peerId, maxAttempts],
        )) ??
        0;
    final synced = Sqflite.firstIntValue(await _db.rawQuery(
          'SELECT COUNT(*) FROM synced_assets WHERE peer_id = ?',
          [peerId],
        )) ??
        0;
    return (pending: pending, failed: failed, synced: synced);
  }

  /// Gives permanently-failed items another chance (e.g. after fixing iCloud).
  Future<void> retryFailed(String peerId) => _db.update(
        'sync_queue',
        {'attempts': 0, 'status': QueueStatus.pending.name},
        where: 'peer_id = ?',
        whereArgs: [peerId],
      );

  // ---- receiver ------------------------------------------------------------

  Future<ReceivedFile?> findReceived({required String sha256, required String metaKey}) async {
    final rows = await _db.query(
      'received_files',
      where: 'sha256 = ? OR meta_key = ?',
      whereArgs: [sha256, metaKey],
      limit: 1,
    );
    return rows.isEmpty ? null : ReceivedFile.fromRow(rows.first);
  }

  Future<void> insertReceived(ReceivedFile f) =>
      _db.insert('received_files', f.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteReceived(String sha256) =>
      _db.delete('received_files', where: 'sha256 = ?', whereArgs: [sha256]);

  Future<int> receivedCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM received_files')) ?? 0;
}
