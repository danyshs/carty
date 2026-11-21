// Host-runnable widget test for CapturePage's LIVE loop. Injects a real
// host-built Carty LiveFusionController + a fake CaptureController whose keyframe
// stream we drive by hand, then asserts that a streamed TRACKING keyframe folds
// into the live heatmap and flips the honesty banner to HIGH — the live wiring,
// proven with NO device. Runs against the host bridge .so:
//   cmake -S native -B native/build -G Ninja && cmake --build native/build
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:carty/capture.dart';
import 'package:carty/carty.dart';
import 'package:carty_example/capture_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Carty _hostCarty() {
  final lib = File('../native/build/libcarty_bridge.so');
  if (!lib.existsSync()) {
    throw StateError(
        'host bridge .so missing — run cmake --build native/build from repo root');
  }
  return Carty.fromLibrary(DynamicLibrary.open(lib.absolute.path));
}

/// A CaptureController whose keyframe stream the test drives directly.
class _StreamFakeController implements CaptureController {
  final StreamController<CaptureKeyframe> _kf =
      StreamController<CaptureKeyframe>.broadcast();

  @override
  Stream<CaptureKeyframe> get keyframes => _kf.stream;

  @override
  Future<void> start() async {}

  @override
  Future<CaptureResult> stop() async => const CaptureResult(
        videoPath: '/tmp/cap/video.mp4',
        sidecarPath: '/tmp/cap/sidecar.ndjson',
        frameCount: 1,
      );

  void emit(CaptureKeyframe kf) => _kf.add(kf);
  void close() => _kf.close();
}

CaptureKeyframe _down(int t) {
  final img = Uint8List(64 * 64 * 4)..fillRange(0, 64 * 64 * 4, 200);
  final pose = PoseSample.fromJsonLine(
      '{"t":$t,"tx":0,"ty":1.6,"tz":0,"qx":0.7071,"qy":0,"qz":0,"qw":-0.7071,'
      '"state":"TRACKING"}');
  return CaptureKeyframe(
    pose: pose,
    image: img,
    width: 64,
    height: 64,
    channels: 4,
    intrinsics: const [500, 500, 32, 32],
  );
}

void main() {
  testWidgets('a streamed TRACKING keyframe fills the live heatmap + HIGH banner',
      (tester) async {
    final carty = _hostCarty();
    final live = LiveFusionController(carty, n: 256, h: 16);
    final fake = _StreamFakeController();

    await tester.pumpWidget(MaterialApp(
      home: CapturePage(controller: fake, liveFusion: live),
    ));

    await tester.tap(find.widgetWithText(FilledButton, 'Record'));
    await tester.pumpAndSettle();
    expect(live.heatmap.value.observedCount, 0, reason: 'honest empty before data');

    fake.emit(_down(1));
    await tester.pumpAndSettle();

    expect(live.stats.accreted, greaterThan(0));
    expect(live.heatmap.value.observedCount, greaterThan(0));
    expect(find.text('Accuracy: HIGH'), findsOneWidget);

    fake.close();
    live.dispose();
  });
}
