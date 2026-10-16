import 'dart:convert';

import 'protocol.dart';

/// A device we've paired with. Pairing is mutual: each side can send to the
/// other, pins the other's certificate fingerprint, and holds a token for it.
class PeerDevice {
  const PeerDevice({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.fingerprint,
    required this.host,
    required this.port,
    required this.tokenOut,
    required this.tokenInHash,
    this.autoAccept = false,
  });

  final String deviceId;
  final String name;
  final String platform;

  /// SHA-256 of the peer's certificate; connections are pinned to it.
  final String fingerprint;
  final String host;
  final int port;

  /// Bearer token we present when calling the peer.
  final String tokenOut;

  /// Hash of the token the peer presents when calling us.
  final String tokenInHash;

  /// Accept files from this device without asking.
  final bool autoAccept;

  Uri uri(String path) => Uri(scheme: 'https', host: host, port: port, path: path);

  PeerDevice copyWith({String? name, String? host, int? port, bool? autoAccept, String? platform}) => PeerDevice(
        deviceId: deviceId,
        name: name ?? this.name,
        platform: platform ?? this.platform,
        fingerprint: fingerprint,
        host: host ?? this.host,
        port: port ?? this.port,
        tokenOut: tokenOut,
        tokenInHash: tokenInHash,
        autoAccept: autoAccept ?? this.autoAccept,
      );

  Map<String, Object?> toRow() => {
        'device_id': deviceId,
        'name': name,
        'platform': platform,
        'fingerprint': fingerprint,
        'host': host,
        'port': port,
        'token_out': tokenOut,
        'token_in_hash': tokenInHash,
        'auto_accept': autoAccept ? 1 : 0,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
      };

  factory PeerDevice.fromRow(Map<String, Object?> r) => PeerDevice(
        deviceId: r['device_id'] as String,
        name: r['name'] as String,
        platform: r['platform'] as String,
        fingerprint: r['fingerprint'] as String,
        host: r['host'] as String,
        port: r['port'] as int,
        tokenOut: r['token_out'] as String,
        tokenInHash: r['token_in_hash'] as String,
        autoAccept: (r['auto_accept'] as int) == 1,
      );
}

/// A device seen on the network via mDNS (paired or not).
class NearbyDevice {
  const NearbyDevice({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.fingerprint,
    required this.host,
    required this.port,
  });

  final String deviceId;
  final String name;
  final String platform;
  final String fingerprint;
  final String host;
  final int port;
}

/// Contents of the pairing QR code.
class PairingPayload {
  const PairingPayload({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.secret,
  });

  static const _app = 'lucerosync';

  final String deviceId;
  final String name;
  final String platform;
  final String host;
  final int port;
  final String fingerprint;

  /// One-time secret proving the scanner saw this screen.
  final String secret;

  String encode() => jsonEncode({
        'app': _app,
        'v': Protocol.version,
        'id': deviceId,
        'name': name,
        'os': platform,
        'host': host,
        'port': port,
        'fp': fingerprint,
        's': secret,
      });

  static PairingPayload? decode(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['app'] != _app || m['v'] != Protocol.version) return null;
      return PairingPayload(
        deviceId: m['id'] as String,
        name: m['name'] as String,
        platform: m['os'] as String,
        host: m['host'] as String,
        port: m['port'] as int,
        fingerprint: m['fp'] as String,
        secret: m['s'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Identity of one file on the wire. `sha256` is the primary key; `metaKey`
/// (filename + creation date + size) is a secondary dedup key for backups.
class FileDescriptor {
  const FileDescriptor({
    required this.sha256,
    required this.filename,
    required this.size,
    required this.createdAtMs,
  });

  final String sha256;
  final String filename;
  final int size;
  final int createdAtMs;

  String get metaKey => buildMetaKey(filename, createdAtMs, size);

  static String buildMetaKey(String filename, int createdAtMs, int size) =>
      '${filename.toLowerCase()}|$createdAtMs|$size';

  Map<String, Object?> toJson() => {'sha256': sha256, 'metaKey': metaKey, 'size': size};
}

enum RemoteFileState { exists, partial, missing }

class FileCheck {
  const FileCheck(this.sha256, this.state, this.offset);

  final String sha256;
  final RemoteFileState state;
  final int offset;

  factory FileCheck.fromJson(Map<String, dynamic> m) => FileCheck(
        m['sha256'] as String,
        RemoteFileState.values.byName(m['state'] as String),
        (m['offset'] as int?) ?? 0,
      );

  Map<String, Object?> toJson() => {'sha256': sha256, 'state': state.name, 'offset': offset};
}

class UploadResult {
  const UploadResult(this.httpStatus, this.status, {this.offset = 0, this.message, this.path});

  final int httpStatus;
  final String status;
  final int offset;
  final String? message;
  final String? path;

  factory UploadResult.fromJson(int httpStatus, Map<String, dynamic> m) => UploadResult(
        httpStatus,
        (m['status'] as String?) ?? 'unknown',
        offset: (m['offset'] as int?) ?? 0,
        message: m['message'] as String?,
        path: m['path'] as String?,
      );
}

enum QueueStatus { pending, uploading, failed }

/// One row of the sender's persistent backup queue.
class QueueItem {
  const QueueItem({
    required this.peerId,
    required this.assetId,
    required this.createdAtMs,
    required this.status,
    required this.attempts,
    this.filename,
    this.size,
    this.sha256,
    this.lastError,
  });

  final String peerId;
  final String assetId;
  final int createdAtMs;
  final QueueStatus status;
  final int attempts;
  final String? filename;
  final int? size;
  final String? sha256;
  final String? lastError;

  factory QueueItem.fromRow(Map<String, Object?> r) => QueueItem(
        peerId: r['peer_id'] as String,
        assetId: r['asset_id'] as String,
        createdAtMs: r['created_at'] as int,
        status: QueueStatus.values.byName(r['status'] as String),
        attempts: r['attempts'] as int,
        filename: r['filename'] as String?,
        size: r['size'] as int?,
        sha256: r['sha256'] as String?,
        lastError: r['last_error'] as String?,
      );
}

/// A backup file the receiver has committed to disk.
class ReceivedFile {
  const ReceivedFile({
    required this.sha256,
    required this.metaKey,
    required this.filename,
    required this.relPath,
    required this.size,
    required this.createdAtMs,
    required this.senderId,
  });

  final String sha256;
  final String metaKey;
  final String filename;
  final String relPath;
  final int size;
  final int createdAtMs;
  final String senderId;

  Map<String, Object?> toRow() => {
        'sha256': sha256,
        'meta_key': metaKey,
        'filename': filename,
        'rel_path': relPath,
        'size': size,
        'created_at': createdAtMs,
        'sender_id': senderId,
        'received_at': DateTime.now().millisecondsSinceEpoch,
      };

  factory ReceivedFile.fromRow(Map<String, Object?> r) => ReceivedFile(
        sha256: r['sha256'] as String,
        metaKey: r['meta_key'] as String,
        filename: r['filename'] as String,
        relPath: r['rel_path'] as String,
        size: r['size'] as int,
        createdAtMs: r['created_at'] as int,
        senderId: r['sender_id'] as String,
      );
}

/// A file inside a share offer.
class ShareFile {
  const ShareFile({required this.id, required this.name, required this.size, required this.sha256});

  final String id;
  final String name;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'size': size, 'sha256': sha256};

  factory ShareFile.fromJson(Map<String, dynamic> m) => ShareFile(
        id: m['id'] as String,
        name: m['name'] as String,
        size: m['size'] as int,
        sha256: (m['sha256'] as String).toLowerCase(),
      );
}

enum TransferDirection { incoming, outgoing }

enum TransferKind { files, text, backup }

enum TransferStatus { done, failed, declined, cancelled }

/// One line in the Activity history.
class TransferRecord {
  const TransferRecord({
    required this.id,
    required this.direction,
    required this.kind,
    required this.peerId,
    required this.peerName,
    required this.title,
    required this.status,
    required this.createdAtMs,
    this.detail,
    this.size = 0,
    this.paths = const [],
  });

  final String id;
  final TransferDirection direction;
  final TransferKind kind;
  final String peerId;
  final String peerName;
  final String title;

  /// Received text, or an error message.
  final String? detail;
  final int size;
  final TransferStatus status;
  final int createdAtMs;

  /// Absolute paths of received files (incoming file transfers only).
  final List<String> paths;

  Map<String, Object?> toRow() => {
        'id': id,
        'direction': direction.name,
        'kind': kind.name,
        'peer_id': peerId,
        'peer_name': peerName,
        'title': title,
        'detail': detail,
        'size': size,
        'status': status.name,
        'paths': jsonEncode(paths),
        'created_at': createdAtMs,
      };

  factory TransferRecord.fromRow(Map<String, Object?> r) => TransferRecord(
        id: r['id'] as String,
        direction: TransferDirection.values.byName(r['direction'] as String),
        kind: TransferKind.values.byName(r['kind'] as String),
        peerId: r['peer_id'] as String,
        peerName: r['peer_name'] as String,
        title: r['title'] as String,
        detail: r['detail'] as String?,
        size: r['size'] as int,
        status: TransferStatus.values.byName(r['status'] as String),
        paths: (jsonDecode((r['paths'] as String?) ?? '[]') as List).cast<String>(),
        createdAtMs: r['created_at'] as int,
      );
}

/// Where a backup run is, as reported by the sender over `/v2/backup/status`.
enum BackupRunState { scanning, waiting, running, done, cancelled, error }

class BackupRunStatus {
  const BackupRunStatus({
    required this.runId,
    required this.state,
    required this.done,
    required this.total,
    this.file,
    this.message,
  });

  final String runId;
  final BackupRunState state;

  /// Library items finished this run (stored, already there, or failed).
  final int done;
  final int total;
  final String? file;
  final String? message;

  bool get finished => state == BackupRunState.done || state == BackupRunState.cancelled || state == BackupRunState.error;

  Map<String, Object?> toJson() => {
        'run': runId,
        'state': state.name,
        'done': done,
        'total': total,
        if (file != null) 'file': file,
        if (message != null) 'message': message,
      };

  static BackupRunStatus? tryParse(Map<String, dynamic> m) {
    final run = m['run'];
    final state = BackupRunState.values.where((s) => s.name == m['state']).firstOrNull;
    final done = m['done'];
    final total = m['total'];
    if (run is! String || !RegExp(r'^[0-9a-f]{8,64}$').hasMatch(run) || state == null) return null;
    if (done is! int || total is! int || done < 0 || total < 0) return null;
    String? clip(Object? v) => v is String ? (v.length > 200 ? v.substring(0, 200) : v) : null;
    return BackupRunStatus(
        runId: run, state: state, done: done, total: total, file: clip(m['file']), message: clip(m['message']));
  }
}

/// "report.pdf", "report.pdf and 2 more", or "Trip · 40 files" when
/// everything is inside one sent folder.
String transferTitle(List<String> names) {
  if (names.isEmpty) return 'Files';
  final tops = names.map((n) => n.split('/').first).toSet();
  if (tops.length == 1 && names.first.contains('/')) {
    return '${tops.first} · ${names.length} file${names.length == 1 ? '' : 's'}';
  }
  final first = names.first.split('/').last;
  return names.length == 1 ? first : '$first and ${names.length - 1} more';
}
