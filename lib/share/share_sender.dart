import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/db.dart';
import '../core/hashing.dart';
import '../core/models.dart';
import '../core/protocol.dart';
import '../net/peer_client.dart';
import '../security/pairing_crypto.dart';

enum ShareState { preparing, waitingForAccept, sending, done, declined, failed, cancelled }

class OutgoingFile {
  OutgoingFile(this.path, this.name, this.size);

  final String path;
  final String name;
  final int size;
  String? sha256;
  int sent = 0;
  bool done = false;
}

/// One outgoing transfer (files or text) to a paired device.
class OutgoingShare extends ChangeNotifier {
  OutgoingShare({required this.peer, required this.files, this.text})
      : id = PairingCrypto.randomHex(16),
        createdAt = DateTime.now();

  final String id;
  final PeerDevice peer;
  final List<OutgoingFile> files;
  final String? text;
  final DateTime createdAt;

  ShareState state = ShareState.preparing;
  String? error;
  bool _cancelled = false;

  int get totalBytes => files.fold(0, (a, f) => a + f.size);
  int get sentBytes => files.fold(0, (a, f) => a + (f.done ? f.size : f.sent));
  double? get fraction => totalBytes == 0 ? null : sentBytes / totalBytes;
  bool get isActive =>
      state == ShareState.preparing || state == ShareState.waitingForAccept || state == ShareState.sending;

  String get title {
    if (text != null) return 'Text';
    return files.length == 1 ? files.first.name : '${files.first.name} and ${files.length - 1} more';
  }

  void _bump() => notifyListeners();

  void _set(ShareState s, {String? err}) {
    state = s;
    error = err;
    notifyListeners();
  }
}

class ShareSender {
  ShareSender(this._db, this._client);

  final AppDatabase _db;
  final PeerClient _client;

  final active = <OutgoingShare>[];
  final _listeners = <VoidCallback>[];

  void addListener(VoidCallback l) => _listeners.add(l);
  void _changed() {
    for (final l in _listeners) {
      l();
    }
  }

  OutgoingShare sendFiles(PeerDevice peer, List<String> paths) {
    final files = [
      for (final path in paths)
        if (File(path).existsSync()) OutgoingFile(path, p.basename(path), File(path).lengthSync()),
    ];
    final share = OutgoingShare(peer: peer, files: files);
    _start(share, () => _runFiles(share));
    return share;
  }

  OutgoingShare sendText(PeerDevice peer, String text) {
    final share = OutgoingShare(peer: peer, files: const [], text: text);
    _start(share, () async {
      share._set(ShareState.sending);
      await _client.shareText(peer, share.id, text);
      share._set(ShareState.done);
    });
    return share;
  }

  void cancel(OutgoingShare share) {
    if (!share.isActive) return;
    share._cancelled = true;
    unawaited(_client.shareCancel(share.peer, share.id));
    share._set(ShareState.cancelled);
  }

  void clearFinished() {
    active.removeWhere((s) => !s.isActive);
    _changed();
  }

  void _start(OutgoingShare share, Future<void> Function() body) {
    active.insert(0, share);
    share.addListener(_changed);
    _changed();
    unawaited(() async {
      try {
        if (share.files.isEmpty && share.text == null) throw Exception('No readable files selected.');
        await body();
      } catch (e) {
        if (share.state != ShareState.cancelled && share.state != ShareState.declined) {
          share._set(ShareState.failed, err: _friendly(e));
        }
      } finally {
        await _db.addTransfer(TransferRecord(
          id: share.id,
          direction: TransferDirection.outgoing,
          kind: share.text != null ? TransferKind.text : TransferKind.files,
          peerId: share.peer.deviceId,
          peerName: share.peer.name,
          title: share.title,
          detail: share.text ?? share.error,
          size: share.totalBytes,
          status: switch (share.state) {
            ShareState.done => TransferStatus.done,
            ShareState.declined => TransferStatus.declined,
            ShareState.cancelled => TransferStatus.cancelled,
            _ => TransferStatus.failed,
          },
          createdAtMs: share.createdAt.millisecondsSinceEpoch,
        ));
        _changed();
      }
    }());
  }

  Future<void> _runFiles(OutgoingShare share) async {
    // 1. Hash (off the UI thread) so the receiver can verify every byte.
    for (final f in share.files) {
      _checkCancel(share);
      f.sha256 = await sha256OfFile(f.path);
    }
    final wire = [
      for (var i = 0; i < share.files.length; i++)
        ShareFile(id: 'f$i', name: share.files[i].name, size: share.files[i].size, sha256: share.files[i].sha256!),
    ];

    // 2. Offer and wait for the other person to accept.
    share._set(ShareState.waitingForAccept);
    var offer = await _client.shareOffer(share.peer, share.id, wire);
    if (!offer.accepted) {
      share._set(ShareState.declined, err: '${share.peer.name} declined.');
      return;
    }

    // 3. Upload each file, resuming after interruptions.
    share._set(ShareState.sending);
    for (var i = 0; i < wire.length; i++) {
      final f = share.files[i];
      var attempts = 0;
      while (!f.done) {
        _checkCancel(share);
        final offset = offer.offsets[wire[i].id] ?? 0;
        if (offset >= f.size && f.size > 0) {
          f.done = true;
          break;
        }
        try {
          final res = await _client.shareUpload(share.peer, share.id, wire[i], File(f.path), offset, onProgress: (n) {
            f.sent = n;
            share._bump();
          });
          if (res.status == Protocol.stored) {
            f.done = true;
          } else if (res.status == Protocol.partial || res.status == Protocol.offsetMismatch) {
            offer.offsets[wire[i].id] = res.offset;
          } else {
            throw ProtocolException('${share.peer.name} rejected ${f.name} (${res.status}).');
          }
        } catch (e) {
          if (!isTransientNetworkError(e) || ++attempts > 6) rethrow;
          await Future<void>.delayed(Duration(seconds: min(2 << attempts, 30)));
          // Re-offer to learn how much the receiver already has.
          offer = await _client.shareOffer(share.peer, share.id, wire);
          if (!offer.accepted) throw ProtocolException('${share.peer.name} cancelled the transfer.');
        }
        share._bump();
      }
    }
    share._set(ShareState.done);
  }

  void _checkCancel(OutgoingShare share) {
    if (share._cancelled) throw _CancelledShare();
  }

  String _friendly(Object e) {
    if (e is TimeoutException) return 'Timed out. Is the other device open and on the same Wi-Fi?';
    if (e is SocketException) return 'Connection lost. Is the other device open and on the same Wi-Fi?';
    return '$e';
  }
}

class _CancelledShare implements Exception {}
