import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lucero_sync/share/owly.dart';

void main() {
  test('parses owly browse output, unescaping names', () {
    final r = parseOwlyBrowse('a1b2c3d4e5f6   "Jane\'s iPhone" (fe80::1%awdl0)\n'
        'ffeeddccbbaa   "Say \\"hi\\" Mac" (fe80::2%awdl0)\n'
        'a1b2c3d4e5f6   "Jane\'s iPhone" (fe80::1%awdl0)\n'
        'not a receiver line\n');
    expect(r.map((e) => e.id), ['a1b2c3d4e5f6', 'ffeeddccbbaa']);
    expect(r.map((e) => e.name), ["Jane's iPhone", 'Say "hi" Mac']);
  });

  test('drives the owly CLI: radio, browse, send outcomes', () async {
    final dir = await Directory.systemTemp.createTemp('owly');
    final fake = File('${dir.path}/owly')
      ..writeAsStringSync(r'''#!/bin/sh
echo "$@" >> "$(dirname "$0")/calls"
case "$1" in
  radio) echo "awdl0 is up: fe80::9%awdl0 (aa:bb)" >&2; sleep 30 ;;
  browse) echo 'a1b2c3d4e5f6   "Jane'"'"'s iPhone" (fe80::1%awdl0)' ;;
  send) case "$3" in
          ok) echo delivered ;;
          no) echo declined ;;
          *) echo "failed: timed out" ;;
        esac ;;
esac
''');
    await Process.run('chmod', ['+x', fake.path]);
    final owly = Owly(executable: fake.path);

    await owly.radioUp(hold: const Duration(seconds: 60));
    final found = await owly.browse(seconds: 1);
    expect(found.single.name, "Jane's iPhone");
    expect(await owly.send(const OwlyReceiver('ok', 'A'), paths: ['/tmp/x.jpg'], urls: ['https://e.com']), isNull);
    expect(await owly.send(const OwlyReceiver('no', 'Jane')), 'Jane declined.');
    expect(await owly.send(const OwlyReceiver('zz', 'B')), 'timed out');
    owly.radioDown();

    final calls = File('${dir.path}/calls').readAsLinesSync();
    expect(calls.first, 'radio up --for 60');
    expect(calls, contains('send --to ok --url https://e.com /tmp/x.jpg'));
    await dir.delete(recursive: true);
  });
}
