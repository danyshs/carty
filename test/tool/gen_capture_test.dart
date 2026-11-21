import 'dart:io';

import 'package:carty/capture.dart';
import 'package:test/test.dart';

import '../../tool/gen_capture.dart';

void main() {
  test('gen_capture writes a replayable sidecar with depth blobs', () {
    final dir = Directory.systemTemp.createTempSync('gen_cap_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final n = generateCapture(dir.path);
    expect(n, greaterThan(0));

    final lines = File('${dir.path}/capture.jsonl').readAsLinesSync();
    expect(lines, isNotEmpty);

    final replay = ReplayHarness.fromLines(lines);
    expect(replay.trackingOnly, isNotEmpty);

    // Every depth block's .dep exists and round-trips to the declared dw×dh.
    for (final s in replay.trackingOnly) {
      final f = loadDepthFrame(dir.path, s);
      expect(f.depth.length, f.dw * f.dh);
    }
  });
}
