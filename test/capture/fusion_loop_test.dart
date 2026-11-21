// Headless replay→fuse integration tests for [FusionLoop] (lib/capture/fusion_loop.dart).
// These pin the determinism contract — same sidecar in → identical grid hash —
// and the idempotency contract — re-feeding the same keyframe ids changes nothing.
// They run on the host build of the native bridge:
//   cmake -S native -B native/build -G Ninja && cmake --build native/build
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:carty/capture.dart';
import 'package:carty/carty.dart';
import 'package:test/test.dart';

// Loads the host unit-test build of the bridge (see test/world_grid_test.dart
// for the established pattern/path).
Carty _hostCarty() {
  final lib = File('native/build/libcarty_bridge.so');
  if (!lib.existsSync()) {
    throw StateError('host bridge .so not built — run cmake --build native/build');
  }
  return Carty.fromLibrary(DynamicLibrary.open(lib.absolute.path));
}

// A tiny synthetic top-down observation: a uniformly "observed" ortho map made
// by ortho-projecting a constant frame. Deterministic given fixed dims.
CartyOrthoMapHandle _stubObservation(Carty carty) {
  const w = 64, h = 64, ch = 4;
  final frame = carty.allocFrame(width: w, height: h, channels: ch);
  frame.bytes.fillRange(0, frame.bytes.length, 200); // non-zero → observed floor
  final ortho = carty.orthoProject(frame, width: w, height: h, channels: ch);
  frame.dispose();
  return ortho;
}

const _line1 = '{"t":1,"tx":0,"ty":1.6,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,"state":"TRACKING"}';
const _line2 = '{"t":2,"tx":0.3,"ty":1.6,"tz":0.3,"qx":0,"qy":0,"qz":0,"qw":1,"state":"TRACKING"}';

void main() {
  late Carty carty;
  setUpAll(() => carty = _hostCarty());

  test('replay → accrete tallies statuses and yields a grid hash', () {
    final replay = ReplayHarness.fromLines([_line1, _line2]);
    final grid = carty.createWorldGrid(n: 256, h: 16, resM: 0.05, bandM: 0.25);
    final result = FusionLoop(carty).run(
      replay: replay,
      grid: grid,
      observe: (_) => _stubObservation(carty),
    );
    expect(result.stats.accreted, greaterThan(0));
    expect(result.gridSha256, hasLength(64));
    grid.dispose();
  });

  test('replay is DETERMINISTIC: same sidecar → identical grid hash', () {
    final replay = ReplayHarness.fromLines([_line1, _line2]);
    String runOnce() {
      final grid = carty.createWorldGrid(n: 256, h: 16);
      final r = FusionLoop(carty)
          .run(replay: replay, grid: grid, observe: (_) => _stubObservation(carty));
      grid.dispose();
      return r.gridSha256;
    }
    expect(runOnce(), equals(runOnce()));
  });

  test('re-feeding the same keyframe ids is idempotent (duplicate no-op)', () {
    final replay = ReplayHarness.fromLines([_line1, _line2]);
    final grid = carty.createWorldGrid(n: 256, h: 16);
    final loop = FusionLoop(carty);
    final first = loop.run(
        replay: replay, grid: grid, observe: (_) => _stubObservation(carty));
    final second = loop.run(
        replay: replay, grid: grid, observe: (_) => _stubObservation(carty));
    expect(second.stats.duplicate, replay.trackingOnly.length);
    expect(second.gridSha256, equals(first.gridSha256)); // grid untouched
    grid.dispose();
  });

  // ── runFromFrames tests ─────────────────────────────────────────
  //
  // These use a camera looking STRAIGHT DOWN (90° pitch around X-axis, so every
  // ray intersects the ground plane at a finite nearby distance).  With the
  // sidecar poses below the camera sits at Y=1.6 m and the ground hit lands
  // ~±0.1 m from the camera — well inside a 256-cell / 5 cm grid.
  //
  // sidecar lines with downward-looking quaternion: 90° pitch around +X with
  // qw<0 so the back column's Y component is +1 (camera -Z maps to world -Y).
  // Verified: dwy=-1, ground hit s=1.6 m, gx=gy=128 (centered in 256-cell grid).
  const downLine1 =
      '{"t":1,"tx":0,"ty":1.6,"tz":0,"qx":0.7071,"qy":0,"qz":0,"qw":-0.7071,"state":"TRACKING"}';
  const downLine2 =
      '{"t":2,"tx":0.3,"ty":1.6,"tz":0.3,"qx":0.7071,"qy":0,"qz":0,"qw":-0.7071,"state":"TRACKING"}';

  CartyFrameBuffer constantFrame(PoseSample ignored) {
    final f = carty.allocFrame(width: 64, height: 64, channels: 4);
    f.bytes.fillRange(0, f.bytes.length, 200);
    return f;
  }

  test('runFromFrames is deterministic: same sidecar+frames → identical grid hash', () {
    String runOnce() {
      final replay = ReplayHarness.fromLines([downLine1, downLine2]);
      final grid = carty.createWorldGrid(n: 256, h: 16);
      final r = FusionLoop(carty).runFromFrames(
        replay: replay,
        grid: grid,
        frames: constantFrame,
        intrinsics: [500, 500, 32, 32],
        width: 64,
        height: 64,
        channels: 4,
      );
      // Guard against a vacuous pass: two empty grids would also hash-equal, so
      // prove this run actually folded observations (geometry lands on-grid)
      // before trusting the determinism comparison.
      expect(r.stats.accreted, greaterThan(0));
      grid.dispose();
      return r.gridSha256;
    }

    expect(runOnce(), equals(runOnce()));
  });

  test('runFromFrames re-feeding same keyframe ids is idempotent (duplicate no-op)', () {
    final replay = ReplayHarness.fromLines([downLine1, downLine2]);
    final grid = carty.createWorldGrid(n: 256, h: 16);
    final loop = FusionLoop(carty);
    final first = loop.runFromFrames(
      replay: replay,
      grid: grid,
      frames: constantFrame,
      intrinsics: [500, 500, 32, 32],
      width: 64,
      height: 64,
      channels: 4,
    );
    // First run must have accreted (proves the geometry lands on-grid).
    expect(first.stats.accreted, greaterThan(0));
    final second = loop.runFromFrames(
      replay: replay,
      grid: grid,
      frames: constantFrame,
      intrinsics: [500, 500, 32, 32],
      width: 64,
      height: 64,
      channels: 4,
    );
    expect(second.stats.duplicate, replay.trackingOnly.length);
    expect(second.gridSha256, equals(first.gridSha256)); // grid untouched
    grid.dispose();
  });

  test('runFromDepth folds a TRACKING depth keyframe and reports a SHA-256', () {
    final dir = Directory.systemTemp.createTempSync('e2e_depth_loop_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/d_5.dep').writeAsBytesSync(
        Uint16List.fromList([1000, 1000, 1000, 1000]).buffer.asUint8List());
    final replay = ReplayHarness.fromLines([
      '{"t":5,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
          '"state":"TRACKING","depth":"d_5.dep","dw":2,"dh":2,'
          '"fx":40,"fy":40,"cx":1,"cy":1,'
          '"stx":0,"sty":0,"stz":0,"sqx":0,"sqy":0,"sqz":0,"sqw":1}'
    ]);
    final grid = carty.createWorldGrid(n: 96, h: 16, resM: 0.1, bandM: 0.25);
    addTearDown(grid.dispose);
    final res = FusionLoop(carty)
        .runFromDepth(replay: replay, grid: grid, sidecarDir: dir.path);
    expect(res.stats.accreted, 1);
    expect(res.gridSha256, isNotEmpty);
  });

  test('runFromDepth skips depth-less and PAUSED keyframes', () {
    final dir = Directory.systemTemp.createTempSync('e2e_depth_skip_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final replay = ReplayHarness.fromLines([
      // depth-less TRACKING frame → skipped (no depth block)
      '{"t":1,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,"state":"TRACKING"}',
      // PAUSED frame (even if it carried depth, trackingOnly drops it)
      '{"t":2,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,"state":"PAUSED"}',
    ]);
    final grid = carty.createWorldGrid(n: 96, h: 16, resM: 0.1, bandM: 0.25);
    addTearDown(grid.dispose);
    final res = FusionLoop(carty)
        .runFromDepth(replay: replay, grid: grid, sidecarDir: dir.path);
    expect(res.stats.accreted, 0);
  });
}
