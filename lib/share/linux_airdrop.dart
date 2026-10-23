import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// An AirDrop receiver nearby (an iPhone, iPad or Mac).
class AirDropPeer {
  const AirDropPeer(this.id, this.name);

  /// What the tool's `--to` takes.
  final String id;
  final String name;
}

/// Someone nearby wants to AirDrop us something.
class AirDropAsk {
  const AirDropAsk(this.sender, this.items);
  final String sender;

  /// File names, or links.
  final List<String> items;
}

/// AirDrop on Linux through an installed command-line tool: owly
/// (github.com/t4t5/owly), or else a4e (github.com/benitbuhner/airdrop-for-everything).
/// Both speak Apple's protocol over AWDL; we only drive their CLIs.
abstract class LinuxAirDrop {
  LinuxAirDrop(this.executable);

  final String executable;

  /// "owly" or "a4e", for the UI.
  String get tool;

  /// Whether links can be sent as links (otherwise they go as a .txt file).
  bool get sendsLinks;

  static LinuxAirDrop? _found;
  static bool _looked = false;

  /// The installed tool, preferring owly. Linux only; cached.
  static Future<LinuxAirDrop?> detect() async {
    if (!Platform.isLinux || _looked) return _found;
    _looked = true;
    for (final (name, make) in [('owly', Owly.new), ('a4e', A4e.new)]) {
      try {
        if ((await Process.run('which', [name])).exitCode == 0) return _found = make(name);
      } catch (_) {}
    }
    return null;
  }

  /// Gets the Wi-Fi card ready for [hold] (owly hands it to AWDL).
  Future<void> prepare({Duration hold = const Duration(minutes: 3)}) async {}

  /// Gives the card back.
  void release() {}

  Future<List<AirDropPeer>> browse();

  /// Null once delivered, otherwise why not.
  Future<String?> send(AirDropPeer to, {List<String> paths = const [], List<String> urls = const []});

  /// Visible to everyone nearby for [duration]. Each request goes to [ask]
  /// (no answer in time declines); saved files to [onFiles], links to [onLinks].
  Future<AirDropListener> receive({
    required String dir,
    required Duration duration,
    required Future<bool> Function(AirDropAsk ask) ask,
    required void Function(String sender, List<String> paths) onFiles,
    required void Function(String sender, List<String> links) onLinks,
  });

  static String? lastLine(String s) {
    final lines = s.trim().split('\n').where((l) => l.trim().isNotEmpty);
    return lines.isEmpty ? null : lines.last.trim();
  }
}

/// A running receiver; [stop] ends it early.
class AirDropListener {
  AirDropListener(this._process, this._cleanup) {
    done = _process.exitCode.then((_) => _cleanup());
  }

  final Process _process;
  final void Function() _cleanup;
  late final Future<void> done;

  void stop() {
    _process.kill(ProcessSignal.sigterm);
    _cleanup();
  }
}

/// Runs a receiver process: answers its terminal prompt from [ask] and
/// reports what arrived. [parseAsk] reads a request out of stderr up to the
/// prompt; [parseOut] turns a stdout line into files or links.
Future<AirDropListener> _listen(
  Process proc, {
  required RegExp prompt,
  required AirDropAsk Function(String stderrBeforePrompt) parseAsk,
  required ({List<String> files, List<String> links})? Function(String line) parseOut,
  required Future<bool> Function(AirDropAsk ask) ask,
  required void Function(String sender, List<String> paths) onFiles,
  required void Function(String sender, List<String> links) onLinks,
  required void Function() cleanup,
}) async {
  var buffer = '';
  var sender = 'Someone nearby';
  // The prompt has no newline, so read stderr as it comes rather than by line.
  proc.stderr.transform(utf8.decoder).listen((chunk) async {
    buffer += chunk;
    final m = prompt.firstMatch(buffer);
    if (m == null) return;
    final request = parseAsk(buffer.substring(0, m.start));
    buffer = buffer.substring(m.end);
    sender = request.sender;
    // Both tools give up on their own after about 15 s.
    final ok = await ask(request).timeout(const Duration(seconds: 13), onTimeout: () => false);
    proc.stdin.writeln(ok ? 'y' : 'n');
  });
  proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final got = parseOut(line);
    if (got == null) return;
    if (got.files.isNotEmpty) onFiles(sender, got.files);
    if (got.links.isNotEmpty) onLinks(sender, got.links);
  });
  return AirDropListener(proc, cleanup);
}

/// Rust `{:?}` strings: `"Jane\'s \"Mac\""`.
String _unquote(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (e) => e[1] == 'n' ? ' ' : e[1]!);
const _quoted = r'"((?:[^"\\]|\\.)*)"';

class Owly extends LinuxAirDrop {
  Owly([super.executable = 'owly']);

  Process? _radio;

  @override
  String get tool => 'owly';
  @override
  bool get sendsLinks => true;

  /// Takes the radio from owlyd (`owly radio up`) so there's an awdl0 to
  /// use. If someone else already holds it, that's fine too.
  @override
  Future<void> prepare({Duration hold = const Duration(minutes: 3)}) async {
    if (_radio != null) return;
    final proc = await Process.start(executable, ['radio', 'up', '--for', '${hold.inSeconds}']);
    _radio = proc;
    unawaited(proc.exitCode.then((_) => _radio = null));
    proc.stdout.drain<void>();
    await proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.contains(' is up') || l.startsWith('owly:'), orElse: () => '')
        .timeout(const Duration(seconds: 15), onTimeout: () => '');
  }

  /// Also restores Wi-Fi when owly had to turn it off.
  @override
  void release() {
    _radio?.kill(ProcessSignal.sigterm);
    _radio = null;
  }

  @override
  Future<List<AirDropPeer>> browse({int seconds = 6}) async {
    final r = await Process.run(executable, ['browse', '--seconds', '$seconds']);
    if (r.exitCode != 0) throw Exception(_why(r.stderr as String) ?? 'owly browse failed');
    return parseOwlyBrowse(r.stdout as String);
  }

  @override
  Future<String?> send(AirDropPeer to, {List<String> paths = const [], List<String> urls = const []}) async {
    final r = await Process.run(executable, [
      'send',
      '--to',
      to.id,
      for (final u in urls) ...['--url', u],
      ...paths,
    ]);
    final out = LinuxAirDrop.lastLine(r.stdout as String);
    if (out == 'delivered') return null;
    if (out == 'declined') return '${to.name} declined.';
    if (out != null && out.startsWith('failed: ')) return out.substring(8);
    return _why(r.stderr as String) ?? 'owly send failed (${r.exitCode}).';
  }

  @override
  Future<AirDropListener> receive({
    required String dir,
    required Duration duration,
    required Future<bool> Function(AirDropAsk ask) ask,
    required void Function(String sender, List<String> paths) onFiles,
    required void Function(String sender, List<String> links) onLinks,
  }) async {
    await prepare(hold: duration);
    final proc = await Process.start(executable, ['receive', '--dir', dir]);
    final timer = Timer(duration, () => proc.kill(ProcessSignal.sigterm));
    return _listen(
      proc,
      prompt: RegExp(r'accept\? \[y/N\] ?'),
      parseAsk: parseOwlyAsk,
      // Saved files print as plain paths, links as quoted strings.
      parseOut: (l) => l.startsWith('"')
          ? (files: const <String>[], links: [_unquote(l.substring(1, l.length - 1))])
          : l.startsWith('/')
              ? (files: [l], links: const <String>[])
              : null,
      ask: ask,
      onFiles: onFiles,
      onLinks: onLinks,
      cleanup: () {
        timer.cancel();
        release();
      },
    );
  }

  static String? _why(String stderr) => LinuxAirDrop.lastLine(stderr)?.replaceFirst(RegExp(r'^owly: '), '');
}

class A4e extends LinuxAirDrop {
  A4e([super.executable = 'a4e']);

  @override
  String get tool => 'a4e';
  @override
  bool get sendsLinks => false;

  @override
  Future<List<AirDropPeer>> browse({int seconds = 6}) async {
    final r = await Process.run(executable, ['peers', '--timeout', '$seconds']);
    if (r.exitCode != 0) throw Exception(LinuxAirDrop.lastLine(r.stderr as String) ?? 'a4e peers failed');
    return parseA4ePeers(r.stdout as String);
  }

  @override
  Future<String?> send(AirDropPeer to, {List<String> paths = const [], List<String> urls = const []}) async {
    final r = await Process.run(executable, ['send', '--to', to.id, '--timeout', '30', ...paths]);
    return switch (r.exitCode) {
      0 => null,
      2 => "Couldn't find ${to.name} any more.",
      3 => '${to.name} declined.',
      _ => LinuxAirDrop.lastLine(r.stderr as String) ?? 'a4e send failed (${r.exitCode}).',
    };
  }

  @override
  Future<AirDropListener> receive({
    required String dir,
    required Duration duration,
    required Future<bool> Function(AirDropAsk ask) ask,
    required void Function(String sender, List<String> paths) onFiles,
    required void Function(String sender, List<String> links) onLinks,
  }) async {
    final proc = await Process.start(
        executable, ['receive', '--outdir', dir, '--ask', '--duration', '${duration.inSeconds}']);
    return _listen(
      proc,
      prompt: RegExp(r'Accept\? \[Y/n\] ?'),
      parseAsk: parseA4eAsk,
      parseOut: (l) {
        final m = RegExp(r'^received: (.*) \([0-9a-f]+\)$').firstMatch(l);
        if (m == null) return null;
        // shortcut: a4e joins names with ", ", so a name containing ", " is
        // only found if it exists whole; upgrade if a4e prints paths.
        final whole = p.join(dir, m[1]!);
        final files = File(whole).existsSync()
            ? [whole]
            : [for (final n in m[1]!.split(', ')) if (File(p.join(dir, n)).existsSync()) p.join(dir, n)];
        return (files: files, links: const <String>[]);
      },
      ask: ask,
      onFiles: onFiles,
      onLinks: onLinks,
      cleanup: () {},
    );
  }
}

/// `owly browse`: `<id padded to 14> "<name>" (<addr>)`.
List<AirDropPeer> parseOwlyBrowse(String stdout) {
  final line = RegExp('^(\\S+)\\s+$_quoted\\s+\\(');
  final seen = <String>{};
  return [
    for (final l in const LineSplitter().convert(stdout))
      if (line.firstMatch(l.trim()) case final m? when seen.add(m[1]!)) AirDropPeer(m[1]!, _unquote(m[2]!)),
  ];
}

/// `a4e peers`: `<id>  <name>  [<addr>]:<port>`.
List<AirDropPeer> parseA4ePeers(String stdout) {
  final line = RegExp(r'^(\S+)  (.+)  \[.*\]:\d+$');
  final seen = <String>{};
  return [
    for (final l in const LineSplitter().convert(stdout))
      if (line.firstMatch(l.trim()) case final m? when seen.add(m[1]!)) AirDropPeer(m[1]!, m[2]!),
  ];
}

/// owly's request, before `accept? [y/N]`:
/// `"Jane's iPhone" ("iPhone15,2") wants to send:` then `  "IMG.HEIC" public.heic 123 bytes` lines.
AirDropAsk parseOwlyAsk(String text) {
  final at = text.lastIndexOf('wants to send:');
  final head = text.substring(0, at < 0 ? 0 : at);
  final sender = RegExp('$_quoted \\(').allMatches(head).lastOrNull?[1];
  final items = [
    for (final l in const LineSplitter().convert(at < 0 ? '' : text.substring(at)))
      if (RegExp('^\\s+$_quoted').firstMatch(l) case final m?) _unquote(m[1]!),
  ];
  return AirDropAsk(sender == null ? 'Someone nearby' : _unquote(sender), items);
}

/// a4e's request: `AirDrop: Jane's iPhone wants to send a.jpg, b.jpg. ` (before `Accept? [Y/n]`).
AirDropAsk parseA4eAsk(String text) {
  final m = RegExp(r'AirDrop: (.*) wants to send (.*)\.\s*$', dotAll: true).firstMatch(text);
  if (m == null) return const AirDropAsk('Someone nearby', []);
  return AirDropAsk(m[1]!.trim(), m[2]!.split(', '));
}
