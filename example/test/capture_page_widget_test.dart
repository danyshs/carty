// Host-runnable widget test for CapturePage. Pumps the real page with a
// FAKE CaptureController + a synthetic already-observed heatmap, and asserts:
//   1. the live occupancy heatmap renders (OccupancyHeatmapPainter present);
//   2. the honesty banner text reflects the derived accuracy (HIGH for the
//      seeded healthy capture — the over-claim guard);
//   3. Record → Stop drives the injected controller and surfaces frameCount.
// No device needed — this is the meaningful host verification of the page.
import 'dart:typed_data';

import 'package:carty/capture.dart';
import 'package:carty/render.dart';
import 'package:carty_example/capture_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted CaptureController: records that start/stop were called and returns
/// a fixed result, so the page's record/stop wiring is asserted with no channel.
class _FakeCaptureController implements CaptureController {
  int starts = 0;
  int stops = 0;

  // Display-only controller: no live keyframes (this test exercises the Task-6
  // path with a seeded heatmap, not the live fusion loop).
  @override
  Stream<CaptureKeyframe> get keyframes => const Stream.empty();

  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<CaptureResult> stop() async {
    stops++;
    return const CaptureResult(
      videoPath: '/tmp/cap/video.mp4',
      sidecarPath: '/tmp/cap/sidecar.ndjson',
      frameCount: 42,
    );
  }
}

/// A synthetic heatmap with one observed cell on the mid band, so the painter
/// has evidence to draw (and equality/hashing has a non-empty slice).
OccupancyHeatmap _seedHeatmap() {
  const n = 4, h = 3;
  final cells = Int8List(n * n * h);
  final mid = (h ~/ 2) * n * n;
  cells[mid + 5] = 100; // one observed ground cell
  return OccupancyHeatmap(cells: cells, n: n, h: h);
}

void main() {
  testWidgets('renders heatmap + HIGH banner and drives record/stop',
      (tester) async {
    final fake = _FakeCaptureController();

    await tester.pumpWidget(MaterialApp(
      home: CapturePage(
        controller: fake,
        initialHeatmap: _seedHeatmap(),
      ),
    ));

    // 1. The live heatmap renders.
    final painter = find.byWidgetPredicate((w) =>
        w is CustomPaint && w.painter is OccupancyHeatmapPainter);
    expect(painter, findsOneWidget,
        reason: 'the live occupancy heatmap must render');

    // 2. The honesty banner reflects the derived (HIGH) accuracy.
    expect(find.text('Accuracy: HIGH'), findsOneWidget);

    // 3. Record → controller.start(); Stop → controller.stop() + result shown.
    expect(fake.starts, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Record'));
    await tester.pumpAndSettle();
    expect(fake.starts, 1, reason: 'Record must reach the controller once');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    await tester.pumpAndSettle();
    expect(fake.stops, 1, reason: 'Stop must reach the controller once');
    expect(find.textContaining('frames   42'), findsOneWidget);
  });
}
