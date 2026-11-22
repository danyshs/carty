import 'dart:ffi';
import 'dart:io';

import 'package:carty/benchmark.dart';
import 'package:carty/benchmark/grid_occupancy.dart';
import 'package:carty/capture.dart';
import 'package:carty/carty.dart';
import 'package:test/test.dart';

/// The HONEST end-to-end gate: a committed synthetic capture of `box_two_room`
/// replays through the REAL native fuse→vectorize pipeline and is scored against
/// truth, replacing the painted `vectorized.geojson` stub (#7). A green gate proves
/// the pipeline is wired correctly and the geometry survives record→replay→fuse→
/// vectorize; it does NOT prove real-world robustness — the depth is clean ray-cast
/// (no sensor/VIO noise), so the device-walk rung remains.
void main() {
  late Carty carty;
  setUpAll(() {
    final so = File('native/build/libcarty_bridge.so').absolute.path;
    carty = Carty.fromLibrary(DynamicLibrary.open(so));
  });

  test('box_two_room: real replay→fuse→vectorize scores above floors', () {
    const dir = 'test/fixtures/benchmark/box_two_room';
    final scene = loadScene(dir);
    final replay = ReplayHarness.fromLines(
        File('$dir/capture.jsonl').readAsLinesSync());

    // Grid sized to the ~6×6 m scene, not a complexity workaround: carty_vectorize
    // is now ~O(n·n) (the exterior re-flood that made it O(n⁴) is fixed — default
    // n=1024 vectorizes in ~100 ms), so n is chosen purely for scene scale.
    // n=96 @ 0.1 m/cell covers 9.6 m.
    final grid = carty.createWorldGrid(n: 96, h: 16, resM: 0.1, bandM: 0.25);
    addTearDown(grid.dispose);

    FusionLoop(carty).runFromDepth(replay: replay, grid: grid, sidecarDir: dir);

    final iou = occupancyIou(occupancyFromGrid(grid), scene.truthOccupancy);
    final pred = scoredGraphFromGeoJson(grid.vectorize());
    final f1 = roomDoorF1(pred, scene.truthMapGraph).f1;

    // Print the honest numbers so the ratchet step can read them.
    stdout.writeln('E2E box_two_room iou=$iou f1=$f1');
    expect(iou, greaterThanOrEqualTo(scene.iouFloor));
    expect(f1, greaterThanOrEqualTo(scene.f1Floor));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
