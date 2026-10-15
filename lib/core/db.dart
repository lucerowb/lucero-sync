import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Single SQLite database shared by every role this device plays.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  static const _version = 2;

  static const _schema = [
    // Small key/value store: device id, name and settings.
    '''CREATE TABLE kv (
         key   TEXT PRIMARY KEY,
         value TEXT NOT NULL
       )''',
    ..._peersV2,

    // ---- Backup sender -------------------------------------------------------

    // The "already synced" ledger, per receiving device. asset_id is the
    // PHAsset localIdentifier (iOS/macOS) or MediaStore id (Android).
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

    // Persistent work queue; survives app kills so a backup resumes exactly
    // where it stopped. filename/size/sha256 are filled on first attempt.
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

    // ---- Backup receiver -----------------------------------------------------

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
    ..._transfersV2,
  ];

  // Paired devices. Pairing is mutual and pinned to certificate fingerprints.
  static const _peersV2 = [
    '''CREATE TABLE peers (
         device_id     TEXT PRIMARY KEY,
         name          TEXT NOT NULL,
         platform      TEXT NOT NULL,
         fingerprint   TEXT NOT NULL,
         host          TEXT NOT NULL,
         port          INTEGER NOT NULL,
         token_out     TEXT NOT NULL,     -- we present this to them
         token_in_hash TEXT NOT NULL,     -- hash of what they present to us
         auto_accept   INTEGER NOT NULL DEFAULT 0,
         last_seen     INTEGER
       )''',
    'CREATE INDEX idx_peers_token ON peers (token_in_hash)',
  ];

  // Activity history (shares, texts, backup runs).
  static const _transfersV2 = [
    '''CREATE TABLE transfers (
         id         TEXT PRIMARY KEY,
         direction  TEXT NOT NULL,
         kind       TEXT NOT NULL,
         peer_id    TEXT NOT NULL,
         peer_name  TEXT NOT NULL,
         title      TEXT NOT NULL,
         detail     TEXT,
         size       INTEGER NOT NULL DEFAULT 0,
         status     TEXT NOT NULL,
         paths      TEXT,
         created_at INTEGER NOT NULL
       )''',
    'CREATE INDEX idx_transfers_time ON transfers (created_at)',
  ];

  /// Opens (or creates) the database. [path] is for tests and multi-instance runs.
  static Future<AppDatabase> open({String? path}) async {
    path ??= p.join(await getDatabasesPath(), 'lucero_sync.db');
    final db = await openDatabase(
      path,
      version: _version,
      onConfigure: (db) => db.rawQuery('PRAGMA journal_mode=WAL'),
      onCreate: (db, _) async {
        for (final stmt in _schema) {
          await db.execute(stmt);
        }
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          // v1 pairings used a 6-digit PIN over plain HTTP. They can't be
          // upgraded securely, so devices re-pair. Backup history is kept, so
          // nothing is re-sent or duplicated after the upgrade.
          await db.execute('DROP TABLE IF EXISTS peers');
          await db.delete('kv', where: 'key = ?', whereArgs: ['pin']);
          for (final stmt in [..._peersV2, ..._transfersV2]) {
            await db.execute(stmt);
          }
        }
      },
    );
    return AppDatabase._(db);
  }

  Future<void> close() => _db.close();

  int get _now => DateTime.now().millisecondsSinceEpoch;

  // ---- kv / settings ---------------------------------------------------------

  Future<String?> getValue(String key) async {
    final rows = await _db.query('kv', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setValue(String key, String value) =>
      _db.insert('kv', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> removeValue(String key) => _db.delete('kv', where: 'key = ?', whereArgs: [key]);

  Future<bool> getBool(String key, {required bool fallback}) async {
    final v = await getValue(key);
    return v == null ? fallback : v == '1';
  }

  Future<void> setBool(String key, bool value) => setValue(key, value ? '1' : '0');

  // ---- peers -----------------------------------------------------------------

  Future<void> upsertPeer(PeerDevice peer) =>
      _db.insert('peers', peer.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<PeerDevice>> listPeers() async =>
      (await _db.query('peers', orderBy: 'last_seen DESC')).map(PeerDevice.fromRow).toList();

  Future<PeerDevice?> getPeer(String deviceId) async {
    final rows = await _db.query('peers', where: 'device_id = ?', whereArgs: [deviceId], limit: 1);
    return rows.isEmpty ? null : PeerDevice.fromRow(rows.first);
  }

  /// [tokenHash] is `PairingCrypto.hashToken(presentedToken)`.
  Future<PeerDevice?> peerByTokenHash(String tokenHash) async {
    final rows = await _db.query('peers', where: 'token_in_hash = ?', whereArgs: [tokenHash], limit: 1);
    return rows.isEmpty ? null : PeerDevice.fromRow(rows.first);
  }

  Future<void> deletePeer(String deviceId) async {
    await _db.delete('peers', where: 'device_id = ?', whereArgs: [deviceId]);
    await _db.delete('sync_queue', where: 'peer_id = ?', whereArgs: [deviceId]);
  }

  // ---- backup sender: ledger + queue --------------------------------------------

  Future<Set<String>> syncedAssetIds(String peerId) async {
    final rows = await _db.query('synced_assets', columns: ['asset_id'], where: 'peer_id = ?', whereArgs: [peerId]);
    return {for (final r in rows) r['asset_id'] as String};
  }

  /// Adds assets to the queue; rows already queued keep their attempts and hash.
  Future<void> enqueue(String peerId, Iterable<({String assetId, int createdAtMs})> assets) async {
    final now = _now;
    final batch = _db.batch();
    for (final a in assets) {
      batch.insert(
        'sync_queue',
        {'peer_id': peerId, 'asset_id': a.assetId, 'created_at': a.createdAtMs, 'enqueued_at': now, 'updated_at': now},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// After a crash, anything left "uploading" is really just pending.
  Future<void> resetInterruptedUploads(String peerId) => _db.update(
        'sync_queue',
        {'status': QueueStatus.pending.name},
        where: 'peer_id = ? AND status = ?',
        whereArgs: [peerId, QueueStatus.uploading.name],
      );

  /// Oldest first; items that already failed sink to the back.
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

  Future<void> markUploading(QueueItem item, {String? filename, int? size, String? sha256}) => _db.update(
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

  Future<void> markFailed(QueueItem item, String error, {required bool countAttempt}) => _db.rawUpdate(
        'UPDATE sync_queue SET status = ?, last_error = ?, updated_at = ?, '
        'attempts = attempts + ? WHERE peer_id = ? AND asset_id = ?',
        [QueueStatus.failed.name, error, _now, countAttempt ? 1 : 0, item.peerId, item.assetId],
      );

  Future<void> dropQueueItem(QueueItem item) =>
      _db.delete('sync_queue', where: 'peer_id = ? AND asset_id = ?', whereArgs: [item.peerId, item.assetId]);

  /// Atomically records the asset as synced and removes it from the queue.
  Future<void> markSynced(QueueItem item, FileDescriptor file, String result) => _db.transaction((txn) async {
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
        await txn.delete('sync_queue', where: 'peer_id = ? AND asset_id = ?', whereArgs: [item.peerId, item.assetId]);
      });

  Future<({int pending, int failed, int synced, int? lastSyncedAt})> queueStats(String peerId,
      {required int maxAttempts}) async {
    int count(List<Map<String, Object?>> r) => Sqflite.firstIntValue(r) ?? 0;
    final pending = count(await _db.rawQuery(
        'SELECT COUNT(*) FROM sync_queue WHERE peer_id = ? AND attempts < ?', [peerId, maxAttempts]));
    final failed = count(await _db.rawQuery(
        'SELECT COUNT(*) FROM sync_queue WHERE peer_id = ? AND attempts >= ?', [peerId, maxAttempts]));
    final synced = count(await _db.rawQuery('SELECT COUNT(*) FROM synced_assets WHERE peer_id = ?', [peerId]));
    final last = Sqflite.firstIntValue(
        await _db.rawQuery('SELECT MAX(synced_at) FROM synced_assets WHERE peer_id = ?', [peerId]));
    return (pending: pending, failed: failed, synced: synced, lastSyncedAt: last);
  }

  Future<void> retryFailed(String peerId) => _db.update(
        'sync_queue',
        {'attempts': 0, 'status': QueueStatus.pending.name},
        where: 'peer_id = ?',
        whereArgs: [peerId],
      );

  // ---- backup receiver ----------------------------------------------------------

  Future<ReceivedFile?> findReceived({required String sha256, required String metaKey}) async {
    final rows = await _db.query('received_files',
        where: 'sha256 = ? OR meta_key = ?', whereArgs: [sha256, metaKey], limit: 1);
    return rows.isEmpty ? null : ReceivedFile.fromRow(rows.first);
  }

  Future<void> insertReceived(ReceivedFile f) =>
      _db.insert('received_files', f.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteReceived(String sha256) => _db.delete('received_files', where: 'sha256 = ?', whereArgs: [sha256]);

  Future<int> receivedCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM received_files')) ?? 0;

  // ---- activity -------------------------------------------------------------------

  Future<void> addTransfer(TransferRecord t) =>
      _db.insert('transfers', t.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<TransferRecord>> listTransfers({int limit = 200}) async =>
      (await _db.query('transfers', orderBy: 'created_at DESC', limit: limit)).map(TransferRecord.fromRow).toList();

  Future<void> clearTransfers() => _db.delete('transfers');
}
