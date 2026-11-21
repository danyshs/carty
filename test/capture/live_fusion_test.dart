// Host tests for [LiveFusionController] (lib/capture/live_fusion.dart) — the
// streaming sibling of FusionLoop.runFromFrames. They pin the live-loop contract
// the on-device CapturePage relies on, WITHOUT a device: a fake stream of
// CaptureKeyframes is folded into a persistent grid, the heatmap fills, the
// honesty banner tracks ARCore health, PAUSED frames never accrete (no smear),
// and re-fed keyframe ids are idempotent.
//
// Runs on the host build of the native bridge:
//   cmake -S native -B native/build -G Ninja && cmake --build native/build
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:carty/capture.dart';
import 'package:carty/carty.dart';
import 'package:test/test.dart';

Carty _hostCarty() {
  final lib = File('native/build/libcarty_bridge.so');
  if (!lib.existsSync()) {
    throw StateError('host bridge .so not built — run cmake --build native/build');
  }
  return Carty.fromLibrary(DynamicLibrary.open(lib.absolute.path));
}

// A camera looking STRAIGHT DOWN (90° pitch about +X, qw<0) so every ray hits
// the ground plane ~0.1 m from the camera — well inside a 256-cell / 5 cm grid.
// Same convention established for runFromFrames (see fusion_loop_test).
PoseSample _down(int t, {double tx = 0, double tz = 0}) => PoseSample.fromJsonLine(
      '{"t":$t,"tx":$tx,"ty":1.6,"tz":$tz,'
      '"qx":0.7071,"qy":0,"qz":0,"qw":-0.7071,"state":"TRACKING"}');

PoseSample _paused(int t) => PoseSample.fromJsonLine(
    '{"t":$t,"tx":0,"ty":1.6,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,"state":"PAUSED"}');

CaptureKeyframe _kf(PoseSample pose) {
  final img = Uint8List(64 * 64 * 4)..fillRange(0, 64 * 64 * 4, 200);
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
  late Carty carty;
  setUpAll(() => carty = _hostCarty());

  test('starts honest-empty, then a TRACKING keyframe fills the heatmap', () {
    final c = LiveFusionController(carty, n: 256, h: 16);
    expect(c.heatmap.value.observedCount, 0); // no fabricated geometry
    c.onKeyframe(_kf(_down(1)));
    expect(c.stats.accreted, greaterThan(0));
    expect(c.heatmap.value.observedCount, greaterThan(0));
    c.dispose();
  });

  test('accuracy is HIGH on healthy ARCore tracking, DEGRADED on PAUSED', () {
    final c = LiveFusionController(carty, n: 256, h: 16);
    c.onKeyframe(_kf(_down(1)));
    expect(c.accuracy.value, AccuracyLevel.high);
    c.onKeyframe(_kf(_paused(2)));
    expect(c.accuracy.value, AccuracyLevel.degraded);
    c.dispose();
  });

  test('PAUSED keyframes never accrete (no smear)', () {
    final c = LiveFusionController(carty, n: 256, h: 16);
    c.onKeyframe(_kf(_paused(1)));
    expect(c.stats.accreted, 0);
    expect(c.heatmap.value.observedCount, 0);
    c.dispose();
  });

  test('re-feeding the same keyframe id is idempotent (duplicate no-op)', () {
    final c = LiveFusionController(carty, n: 256, h: 16);
    c.onKeyframe(_kf(_down(1)));
    final observed = c.heatmap.value.observedCount;
    c.onKeyframe(_kf(_down(1))); // same t
    expect(c.stats.duplicate, greaterThan(0));
    expect(c.heatmap.value.observedCount, observed); // grid untouched
    c.dispose();
  });

  test('snapshot carries the color photo-map and a camera marker at the anchor',
      () {
    final c = LiveFusionController(carty, n: 256, h: 16);
    // Honest empty start: no pose yet → no marker, no fabricated position.
    expect(c.heatmap.value.camera, isNull);
    c.onKeyframe(_kf(_down(1)));
    final hm = c.heatmap.value;
    // The floor photo-map view is plumbed through (n*n*3).
    expect(hm.color, isNotNull);
    expect(hm.color!.length, 256 * 256 * 3);
    // Grid anchors centered on the first camera (cam at world origin) so the
    // "you are here" cell lands at ~n/2.
    expect(hm.camera, isNotNull);
    expect(hm.camera!.gx, closeTo(128, 2));
    expect(hm.camera!.gy, closeTo(128, 2));
    c.dispose();
  });

  test('standing still throttles by translation (no forward-bias smear)', () {
    // Camera planted: first frame always folds, but later NEW keyframes that
    // have not moved past the gate must NOT re-fold the same forward patch —
    // that smear is the documented device-walk failure (HISTORY 2026-06-23).
    final c = LiveFusionController(carty, n: 256, h: 16, minTranslationM: 0.05);
    c.onKeyframe(_kf(_down(1)));
    expect(c.stats.accreted, 1);
    c.onKeyframe(_kf(_down(2))); // new id, same position → throttled
    c.onKeyframe(_kf(_down(3))); // still planted → throttled
    expect(c.stats.accreted, 1); // grid never re-folded
    expect(c.throttledByTranslation, 2);
    c.dispose();
  });

  test('moving past the translation gate folds the next keyframe', () {
    final c = LiveFusionController(carty, n: 256, h: 16, minTranslationM: 0.05);
    c.onKeyframe(_kf(_down(1)));
    c.onKeyframe(_kf(_down(2, tx: 0.02))); // 2 cm < gate → throttled
    expect(c.stats.accreted, 1);
    c.onKeyframe(_kf(_down(3, tx: 0.5))); // 50 cm ≥ gate → folds
    expect(c.stats.accreted, 2);
    expect(c.throttledByTranslation, 1);
    c.dispose();
  });

  test('re-fed duplicate id is a duplicate, not a translation throttle', () {
    // The gate must not preempt native idempotency: a re-delivered keyframe id
    // (ARCore redelivery) is a DUPLICATE even though the camera has not moved.
    final c = LiveFusionController(carty, n: 256, h: 16, minTranslationM: 0.05);
    c.onKeyframe(_kf(_down(1)));
    c.onKeyframe(_kf(_down(1))); // same id, same pose
    expect(c.stats.duplicate, greaterThan(0));
    expect(c.throttledByTranslation, 0);
    c.dispose();
  });

  test('heatmap snapshots are independent: a new observation notifies', () {
    final c = LiveFusionController(carty, n: 256, h: 16);
    final seen = <int>[];
    c.heatmap.addListener(() => seen.add(c.heatmap.value.observedCount));
    c.onKeyframe(_kf(_down(1)));
    c.onKeyframe(_kf(_down(2, tx: 0.5))); // a DIFFERENT cell column
    expect(seen, isNotEmpty);
    expect(seen.last, greaterThan(0));
    c.dispose();
  });
}
