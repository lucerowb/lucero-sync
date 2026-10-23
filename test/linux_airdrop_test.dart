import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lucero_sync/share/linux_airdrop.dart';

Future<String> fakeTool(Directory dir, String name, String script) async {
  final f = File('${dir.path}/$name')..writeAsStringSync('#!/bin/sh\necho "\$@" >> "\$(dirname "\$0")/calls"\n$script');
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('airdrop'));
  tearDown(() => dir.delete(recursive: true));
  List<String> calls() => File('${dir.path}/calls').readAsLinesSync();

  test('parses both tools\' peer lists and requests', () {
    final owly = parseOwlyBrowse('a1b2c3d4e5f6   "Jane\'s iPhone" (fe80::1%awdl0)\n'
        'ffeeddccbbaa   "Say \\"hi\\" Mac" (fe80::2%awdl0)\n'
        'a1b2c3d4e5f6   "Jane\'s iPhone" (fe80::1%awdl0)\nnoise\n');
    expect(owly.map((e) => e.name), ["Jane's iPhone", 'Say "hi" Mac']);

    final a4e = parseA4ePeers('0a1b2c3d4e5f  Jane\'s  iPhone  [fe80::1]:8770\nno receiver\n');
    expect(a4e.single.id, '0a1b2c3d4e5f');
    expect(a4e.single.name, "Jane's  iPhone");

    final ask = parseOwlyAsk('seen by fe80::1\n"Jane\'s iPhone" ("iPhone15,2") wants to send:\n'
        '  "IMG 1.HEIC" public.heic 123 bytes\n  "b.mov" public.movie\n');
    expect(ask.sender, "Jane's iPhone");
    expect(ask.items, ['IMG 1.HEIC', 'b.mov']);

    final a = parseA4eAsk('AirDrop: Jane\'s iPhone wants to send a.jpg, b.jpg. ');
    expect(a.sender, "Jane's iPhone");
    expect(a.items, ['a.jpg', 'b.jpg']);
  });

  test('owly: radio, browse, send outcomes', () async {
    final owly = Owly(await fakeTool(dir, 'owly', r'''
case "$1" in
  radio) echo "awdl0 is up: fe80::9%awdl0 (aa:bb)" >&2; sleep 30 ;;
  browse) echo 'a1b2c3d4e5f6   "Jane'"'"'s iPhone" (fe80::1%awdl0)' ;;
  send) case "$3" in ok) echo delivered ;; no) echo declined ;; *) echo "failed: timed out" ;; esac ;;
esac
'''));
    await owly.prepare(hold: const Duration(seconds: 60));
    expect((await owly.browse(seconds: 1)).single.name, "Jane's iPhone");
    expect(await owly.send(const AirDropPeer('ok', 'A'), paths: ['/tmp/x.jpg'], urls: ['https://e.com']), isNull);
    expect(await owly.send(const AirDropPeer('no', 'Jane')), 'Jane declined.');
    expect(await owly.send(const AirDropPeer('zz', 'B')), 'timed out');
    owly.release();
    expect(calls().first, 'radio up --for 60');
    expect(calls(), contains('send --to ok --url https://e.com /tmp/x.jpg'));
  });

  test('a4e: browse and send exit codes', () async {
    final a4e = A4e(await fakeTool(dir, 'a4e', r'''
case "$1" in
  peers) echo "0a1b2c3d4e5f  Jane  [fe80::1]:8770" ;;
  send) case "$3" in ok) echo "sent: x.jpg" ;; no) echo declined >&2; exit 3 ;; *) echo "no receiver found in 30s" >&2; exit 2 ;; esac ;;
esac
'''));
    expect((await a4e.browse(seconds: 1)).single.id, '0a1b2c3d4e5f');
    expect(await a4e.send(const AirDropPeer('ok', 'A'), paths: ['/tmp/x.jpg']), isNull);
    expect(await a4e.send(const AirDropPeer('no', 'Jane')), 'Jane declined.');
    expect(await a4e.send(const AirDropPeer('gone', 'B')), "Couldn't find B any more.");
  });

  for (final (tool, script) in [
    (
      'owly',
      r'''
case "$1" in
  radio) echo "awdl0 is up" >&2; sleep 30 ;;
  receive)
    for n in 1 2; do
      printf '"Jane'"'"'s iPhone" ("iPhone15,2") wants to send:\n  "IMG.HEIC" public.heic 5 bytes\naccept? [y/N] ' >&2
      read answer
      if [ "$answer" = y ]; then echo hi > "$3/IMG.HEIC"; echo "$3/IMG.HEIC"; echo '"https://example.com/x"'; fi
    done
    sleep 30 ;;
esac
'''
    ),
    (
      'a4e',
      r'''
case "$1" in
  receive)
    for n in 1 2; do
      printf "AirDrop: Jane's iPhone wants to send IMG.HEIC. Accept? [Y/n] " >&2
      read answer
      if [ "$answer" = y ]; then echo hi > "$3/IMG.HEIC"; echo "received: IMG.HEIC (0123abcd)"; fi
    done
    sleep 30 ;;
esac
'''
    ),
  ]) {
    test('$tool: receiving asks, then reports saved files and links', () async {
      final exe = await fakeTool(dir, tool, script);
      final airdrop = tool == 'owly' ? Owly(exe) : A4e(exe);
      final asks = <AirDropAsk>[];
      final files = <String>[], links = <String>[];
      final listener = await airdrop.receive(
        dir: dir.path,
        duration: const Duration(minutes: 1),
        // Accept the first request, decline the second.
        ask: (a) async => (asks..add(a)).length == 1,
        onFiles: (from, paths) {
          expect(from, "Jane's iPhone");
          files.addAll(paths);
        },
        onLinks: (from, l) => links.addAll(l),
      );
      while (asks.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      listener.stop();

      expect(asks.first.sender, "Jane's iPhone");
      expect(asks.first.items, ['IMG.HEIC']);
      expect(files, ['${dir.path}/IMG.HEIC']);
      expect(links, tool == 'owly' ? ['https://example.com/x'] : isEmpty);
    });
  }
}
