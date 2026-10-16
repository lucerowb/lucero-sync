import '../core/models.dart';

/// A backup another device is running *into* this one, as seen by the receiver.
class IncomingBackup {
  IncomingBackup(this.peerId, this.fromName);

  final String peerId;
  String fromName;
  String? runId;
  BackupRunState state = BackupRunState.running;

  /// Library items finished / total, from the sender's status reports.
  int done = 0;
  int total = 0;
  int storedHere = 0;

  /// The file arriving right now.
  String? file;
  int fileReceived = 0;
  int fileSize = 0;

  DateTime updatedAt = DateTime.now();

  bool get finished =>
      state == BackupRunState.done || state == BackupRunState.cancelled || state == BackupRunState.error;

  /// No word from the sender for a while: it was probably closed or lost Wi-Fi.
  bool get stalled => !finished && DateTime.now().difference(updatedAt) > const Duration(seconds: 30);

  double? get fraction {
    if (total == 0) return null;
    final partial = fileSize > 0 ? (fileReceived / fileSize).clamp(0.0, 1.0) : 0.0;
    return ((done + partial) / total).clamp(0.0, 1.0);
  }
}

enum LiveDirection { sending, receiving }

/// One line of "what's happening right now", for compact surfaces: the nav
/// badge, the macOS menu bar, the iOS Live Activity and the web page.
class LiveItem {
  const LiveItem({
    required this.id,
    required this.direction,
    required this.backup,
    required this.peerName,
    required this.title,
    required this.status,
    this.fraction,
  });

  final String id;
  final LiveDirection direction;
  final bool backup;
  final String peerName;
  final String title;
  final String status;
  final double? fraction;

  Map<String, Object?> toJson() => {
        'id': id,
        'direction': direction.name,
        'backup': backup,
        'peer': peerName,
        'title': title,
        'status': status,
        'fraction': fraction,
      };
}

/// Everything in flight, summarised.
class LiveSummary {
  const LiveSummary(this.items);

  final List<LiveItem> items;

  bool get isEmpty => items.isEmpty;
  int get count => items.length;

  /// Mean progress of the items that know theirs.
  double? get fraction {
    final known = items.map((i) => i.fraction).whereType<double>().toList();
    if (known.isEmpty) return null;
    return known.reduce((a, b) => a + b) / known.length;
  }

  String get headline {
    if (items.isEmpty) return 'Nothing in progress';
    if (items.length == 1) {
      final i = items.first;
      final verb = i.direction == LiveDirection.sending ? 'to' : 'from';
      return '${i.backup ? 'Backup' : i.title} $verb ${i.peerName}';
    }
    final sending = items.where((i) => i.direction == LiveDirection.sending).length;
    final receiving = items.length - sending;
    final text = [if (sending > 0) 'sending $sending', if (receiving > 0) 'receiving $receiving'].join(', ');
    return '${text[0].toUpperCase()}${text.substring(1)}';
  }

  String get detail => items.length == 1 ? items.first.status : '${items.length} transfers';

  Map<String, Object?> toJson() => {
        'count': count,
        'fraction': fraction,
        'headline': headline,
        'detail': detail,
        'items': [for (final i in items) i.toJson()],
      };
}

/// Transfer speed, smoothed so the number doesn't jitter, and time left.
class RateMeter {
  DateTime? _at;
  int _bytes = 0;
  double? _rate;

  /// Call with the running total of bytes moved.
  void add(int totalBytes) {
    final now = DateTime.now();
    final at = _at;
    if (at == null || totalBytes < _bytes) {
      _at = now;
      _bytes = totalBytes;
      return;
    }
    final ms = now.difference(at).inMilliseconds;
    if (ms < 500) return;
    final sample = (totalBytes - _bytes) * 1000 / ms;
    _rate = _rate == null ? sample : _rate! * 0.7 + sample * 0.3;
    _at = now;
    _bytes = totalBytes;
  }

  /// Bytes per second, or null before there's a measurement.
  double? get bytesPerSecond => _rate;

  Duration? timeLeft(int remainingBytes) {
    final r = _rate;
    if (r == null || r < 1) return null;
    return Duration(seconds: (remainingBytes / r).ceil());
  }
}
