import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An AirDrop receiver that `owly browse` found (an iPhone, iPad or Mac).
class OwlyReceiver {
  const OwlyReceiver(this.id, this.name);

  /// Its service ID, what `owly send --to` takes.
  final String id;
  final String name;
}

/// AirDrop on Linux through owly (github.com/t4t5/owly), when it's installed.
/// owly runs AWDL on the Wi-Fi card; we only drive its CLI.
class Owly {
  Owly({this.executable = 'owly'});

  final String executable;
  Process? _radio;

  static bool? _installed;

  /// Whether `owly` is on the PATH. Linux only; cached.
  static Future<bool> installed() async {
    if (!Platform.isLinux) return false;
    try {
      return _installed ??= (await Process.run('which', ['owly'])).exitCode == 0;
    } catch (_) {
      return _installed = false;
    }
  }

  /// Takes the radio from owlyd for [hold], so browse and send have an
  /// awdl0 to use. A radio someone else already holds is fine too.
  Future<void> radioUp({Duration hold = const Duration(minutes: 3)}) async {
    if (_radio != null) return;
    final p = await Process.start(executable, ['radio', 'up', '--for', '${hold.inSeconds}']);
    _radio = p;
    unawaited(p.exitCode.then((_) => _radio = null));
    p.stdout.drain<void>();
    // It prints "<iface> is up" once the link exists; give up waiting after 15 s.
    await p.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.contains(' is up') || l.startsWith('owly:'), orElse: () => '')
        .timeout(const Duration(seconds: 15), onTimeout: () => '');
  }

  /// Gives the radio back, which also restores Wi-Fi in exclusive mode.
  void radioDown() {
    _radio?.kill(ProcessSignal.sigterm);
    _radio = null;
  }

  Future<List<OwlyReceiver>> browse({int seconds = 6}) async {
    final r = await Process.run(executable, ['browse', '--seconds', '$seconds']);
    if (r.exitCode != 0) throw OwlyException(_lastLine(r.stderr as String) ?? 'owly browse failed');
    return parseOwlyBrowse(r.stdout as String);
  }

  /// Sends [paths] (and [urls] as links) and returns once the receiver
  /// answered: null when delivered, otherwise why not.
  Future<String?> send(OwlyReceiver to, {List<String> paths = const [], List<String> urls = const []}) async {
    final r = await Process.run(executable, [
      'send',
      '--to',
      to.id,
      for (final u in urls) ...['--url', u],
      ...paths,
    ]);
    final out = _lastLine(r.stdout as String);
    if (out == 'delivered') return null;
    if (out == 'declined') return '${to.name} declined.';
    if (out != null && out.startsWith('failed: ')) return out.substring(8);
    return _lastLine(r.stderr as String) ?? 'owly send failed (${r.exitCode}).';
  }

  static String? _lastLine(String s) {
    final lines = s.trim().split('\n').where((l) => l.trim().isNotEmpty);
    return lines.isEmpty ? null : lines.last.trim().replaceFirst(RegExp(r'^owly: '), '');
  }
}

class OwlyException implements Exception {
  OwlyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `owly browse` prints `<id padded to 14> "<name, Rust-escaped>" (<addr>)`.
List<OwlyReceiver> parseOwlyBrowse(String stdout) {
  final line = RegExp(r'^(\S+)\s+"((?:[^"\\]|\\.)*)"\s+\(');
  final seen = <String>{};
  return [
    for (final l in const LineSplitter().convert(stdout))
      if (line.firstMatch(l.trim()) case final m? when seen.add(m[1]!))
        OwlyReceiver(m[1]!, m[2]!.replaceAllMapped(RegExp(r'\\(.)'), (e) => e[1] == 'n' ? ' ' : e[1]!)),
  ];
}
