import 'dart:convert';

import 'protocol.dart';

/// A paired receiver, as stored on the sender.
class PeerInfo {
  const PeerInfo({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
    required this.token,
  });

  final String deviceId;
  final String name;
  final String host;
  final int port;
  final String token;

  Uri uri(String path) => Uri(scheme: 'http', host: host, port: port, path: path);

  PeerInfo copyWith({String? host, int? port, String? name}) => PeerInfo(
        deviceId: deviceId,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        token: token,
      );

  Map<String, Object?> toRow() => {
        'device_id': deviceId,
        'name': name,
        'host': host,
        'port': port,
        'token': token,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
      };

  factory PeerInfo.fromRow(Map<String, Object?> r) => PeerInfo(
        deviceId: r['device_id'] as String,
        name: r['name'] as String,
        host: r['host'] as String,
        port: r['port'] as int,
        token: r['token'] as String,
      );
}

/// QR code contents shown by the receiver.
class PairingPayload {
  static const _app = 'lucerosync';

  static String encode({
    required String deviceId,
    required String name,
    required String host,
    required int port,
    required String pin,
  }) =>
      jsonEncode({
        'app': _app,
        'v': Protocol.version,
        'id': deviceId,
        'name': name,
        'host': host,
        'port': port,
        'pin': pin,
      });

  static PeerInfo? decode(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['app'] != _app) return null;
      return PeerInfo(
        deviceId: m['id'] as String,
        name: m['name'] as String,
        host: m['host'] as String,
        port: m['port'] as int,
        token: m['pin'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Identity of one file on the wire. `sha256` is the primary key; `metaKey`
/// (filename + creation date + size) is a secondary key so the receiver can
/// also catch the same photo arriving from a different sender/library.
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
  const UploadResult(this.httpStatus, this.status, {this.offset = 0, this.message});

  final int httpStatus;
  final String status;
  final int offset;
  final String? message;

  factory UploadResult.fromJson(int httpStatus, Map<String, dynamic> m) => UploadResult(
        httpStatus,
        (m['status'] as String?) ?? 'unknown',
        offset: (m['offset'] as int?) ?? 0,
        message: m['message'] as String?,
      );
}

enum QueueStatus { pending, uploading, failed }

/// One row of the sender's persistent sync queue.
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

/// A file the receiver has committed to disk.
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
