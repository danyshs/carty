// tool/gen_capture.dart
//
// The WRITER that turns the I/O-free synthetic-capture math (synthetic_capture.dart)
// into a COMMITTED, replayable fixture for `box_two_room`: a scripted walk over the
// scene's true wall geometry, ray-cast into per-keyframe depth blobs + a pose sidecar
// that round-trips through the real fuse→vectorize pipeline. Exists so the benchmark gate
// scores a REAL fused grid instead of the painted-truth `vectorized.geojson` stub
// (#7). Re-run `dart run tool/gen_capture.dart` to regenerate the fixture in place;
// the output is deterministic (a fixed walk + fixed geometry), so the committed bytes
// are a golden. Delete this and the gate has no honest input.
//
// Wall geometry is derived from `box_two_room` truth (truth_mapgraph.json): the two
// room rectangles [1..2]×[1..5] and [3..5]×[1..5] as wall loops, with a door GAP cut
// into the two facing walls around the truth door at (2.5,3). Truth `x→world X`,
// truth `y→world Z` (the grid's ground axes), so vectorized rooms land back on the
// truth polygons the F1 scorer matches by absolute IoU.
library;

import 'dart:io';
import 'dart:math' as math;

// Import the sidecar model DIRECTLY (not the capture.dart barrel): the barrel
// transitively pulls in the FFI bindings, which crash the FFI transformer under
// `dart run` (this is a standalone tool, not a flutter-test). The writer only
// needs the frozen pose/depth schema.
import 'package:carty/capture/pose_sidecar.dart';

import 'synthetic_capture.dart';

/// Default fixture dir — overridable by argv[0] so the test can write to a temp dir.
const String _defaultDir = 'test/fixtures/benchmark/box_two_room';

// Depth camera: small enough that the O(dw*dh*walls) raycast is instant, large
// enough (with fx=fy≈40) to resolve the 1 m room features.
const int _dw = 64, _dh = 48;
const double _fx = 40, _fy = 40, _cx = _dw / 2, _cy = _dh / 2;
const double _camHeight = 1.4; // eye-height; below wallTop so walls occlude
const double _wallTop = 2.5;
const double _maxRange = 12;

/// `box_two_room` walls in TRUTH world coords (x→X, y→Z), as vertical quads.
///
/// ONE outer boundary enclosing [1,5]×[1,5] plus a SINGLE interior partition wall
/// at x=2.5 with a door-width gap at the truth door (2.5,3). This matches
/// truth_occupancy (an outer box + a partition), and — critically — keeps both
/// rooms ENCLOSED: the vectorizer finds rooms as flood-fill components that don't
/// touch the grid border, so any opening in the outer ring leaks the fill out and
/// yields ZERO rooms. The partition splits the interior into x∈[1,2.5] and
/// x∈[2.5,5], whose bounding boxes match truth rooms [1,2]/[3,5] within the
/// absolute IoU≥0.5 the F1 scorer demands. A two-disjoint-
/// rectangle model instead leaves an open corridor that leaks — do not reintroduce.
List<WallSeg> boxTwoRoomWalls() {
  // Narrow door gap (≈1 grid cell at res 0.1 m): the vectorizer's segmentation
  // seals doorways ≤1 cell so the two rooms become SEPARATE components, while
  // detect_doors still reads the original floor label at the gap to emit one door
  // at (2.5,3). A wider gap leaves the rooms 4-connected → one merged room, no door.
  const gapLo = 2.95, gapHi = 3.05; // door gap in Z, centred on the door at z=3
  return const <WallSeg>[
    // Outer boundary of [1,5]×[1,5].
    WallSeg(1, 1, 1, 5), // left wall x=1
    WallSeg(5, 1, 5, 5), // right wall x=5
    WallSeg(1, 1, 5, 1), // near wall z=1
    WallSeg(1, 5, 5, 5), // far wall z=5
    // Interior partition at x=2.5, split by the door gap at z≈3.
    WallSeg(2.5, 1, 2.5, gapLo), // partition below the door
    WallSeg(2.5, gapHi, 2.5, 5), // partition above the door
  ];
}

/// Yaw-about-world-Y quaternion `(0, sin(θ/2), 0, cos(θ/2))` — the rotation that
/// reproduces [poseMatrixFromYaw] when PoseSample/DepthBlock rebuild the 4×4 from
/// the quaternion (verified against toSensorPoseMatrix's layout). Returned as the
/// 4 components (qx,qy,qz,qw); the consistency is what lets the synthetic depth
/// replay unchanged through the native reprojector.
({double qx, double qy, double qz, double qw}) quatFromYaw(double yawRad) {
  return (qx: 0, qy: math.sin(yawRad / 2), qz: 0, qw: math.cos(yawRad / 2));
}

void main(List<String> args) {
  final dir = args.isNotEmpty ? args.first : _defaultDir;
  final n = generateCapture(dir);
  // ignore: avoid_print
  print('gen_capture: wrote $n keyframes to $dir');
}

/// Writes the committed fixture into [dir] and returns the keyframe count.
/// Pulled out of [main] so tests call it directly: shelling out to `dart run`
/// from inside a flutter-test isolate DEADLOCKS on the pub package-config lock
/// the parent already holds.
int generateCapture(String dir) {
  Directory(dir).createSync(recursive: true);

  final walls = boxTwoRoomWalls();
  final poses = scriptedWalk(
    roomCenters: const [(x: 1.5, z: 3), (x: 4.0, z: 3)],
    doorX: 2.5,
    doorZ: 3,
  );

  final lines = <String>[];
  for (var i = 0; i < poses.length; i++) {
    final p = poses[i];
    final t = i * 100; // ms; also the stable keyframe_id
    final depth = raycastDepth(
      camX: p.x,
      camY: _camHeight,
      camZ: p.z,
      yawRad: p.yawRad,
      walls: walls,
      dw: _dw,
      dh: _dh,
      fx: _fx,
      fy: _fy,
      cx: _cx,
      cy: _cy,
      wallTop: _wallTop,
      maxRange: _maxRange,
    );

    final depthName = 'd_$t.dep';
    File('$dir/$depthName').writeAsBytesSync(
        depth.buffer.asUint8List(depth.offsetInBytes, depth.lengthInBytes),
        flush: true);

    final q = quatFromYaw(p.yawRad);
    final sample = PoseSample(
      t: t,
      tx: p.x,
      ty: _camHeight,
      tz: p.z,
      qx: q.qx,
      qy: q.qy,
      qz: q.qz,
      qw: q.qw,
      state: TrackingState.tracking,
      // Sensor pose == display pose: the synthetic rig has no offset.
      depth: DepthBlock(
        depthPath: depthName,
        confPath: null,
        dw: _dw,
        dh: _dh,
        fx: _fx,
        fy: _fy,
        cx: _cx,
        cy: _cy,
        stx: p.x,
        sty: _camHeight,
        stz: p.z,
        sqx: q.qx,
        sqy: q.qy,
        sqz: q.qz,
        sqw: q.qw,
      ),
    );
    lines.add(sample.toJsonLine());
  }

  File('$dir/capture.jsonl').writeAsStringSync('${lines.join('\n')}\n',
      flush: true);
  return poses.length;
}
