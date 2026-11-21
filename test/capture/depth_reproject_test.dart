// depth reprojection depth-reprojection FFI surface + offline-replay determinism. Mirrors the
// native primary fixture (test_depth_reproject.cpp): u=1,v=1,Z=2000 in a 4x4
// buffer, identity sensor pose, K={2,2,1.5,1.5}, grid 8x8x8 @0.5 -> exactly one
// folded cell. The .so must be built first (cmake --build native/build).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:carty/capture/pose_sidecar.dart';
import 'package:carty/capture/replay.dart';
import 'package:carty/carty.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final soPath = File('native/build/libcarty_bridge.so').absolute.path;
  late Carty carty;

  setUpAll(() {
    expect(
      File(soPath).existsSync(),
      isTrue,
      reason: 'Build the host bridge first: cmake --build native/build ($soPath)',
    );
    carty = Carty.fromLibrary(DynamicLibrary.open(soPath));
  });

  Uint16List primaryDepth() {
    final d = Uint16List(16);
    d[1 * 4 + 1] = 2000;
    return d;
  }

  const identity = <double>[
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, //
  ];

  test('accreteFromDepth folds a known pixel and reports OK', () {
    final grid = carty.createWorldGrid(n: 8, h: 8, resM: 0.5, bandM: 0.5);
    addTearDown(grid.dispose);
    final status = grid.accreteFromDepth(
      depth: primaryDepth(),
      dw: 4,
      dh: 4,
      intrinsics: const [2, 2, 1.5, 1.5],
      pose: identity,
      keyframeId: 1,
    );
    expect(status, CartyFuseStatus.ok);
    var nonZero = 0;
    for (final c in grid.cells) {
      if (c != 0) nonZero++;
    }
    expect(nonZero, 1, reason: 'exactly one cell folded');
  });

  test('re-feeding the same keyframeId is a duplicate no-op', () {
    final grid = carty.createWorldGrid(n: 8, h: 8, resM: 0.5, bandM: 0.5);
    addTearDown(grid.dispose);
    grid.accreteFromDepth(
        depth: primaryDepth(), dw: 4, dh: 4,
        intrinsics: const [2, 2, 1.5, 1.5], pose: identity, keyframeId: 5);
    final dup = grid.accreteFromDepth(
        depth: primaryDepth(), dw: 4, dh: 4,
        intrinsics: const [2, 2, 1.5, 1.5], pose: identity, keyframeId: 5);
    expect(dup, CartyFuseStatus.duplicate);
  });

  test('an all-zero depth buffer reports out of bounds (no fold)', () {
    final grid = carty.createWorldGrid(n: 8, h: 8, resM: 0.5, bandM: 0.5);
    addTearDown(grid.dispose);
    final status = grid.accreteFromDepth(
      depth: Uint16List(16),
      dw: 4,
      dh: 4,
      intrinsics: const [2, 2, 1.5, 1.5],
      pose: identity,
      keyframeId: 1,
    );
    expect(status, CartyFuseStatus.outOfBounds);
  });

  test('intrinsics length != 4 throws ArgumentError', () {
    final grid = carty.createWorldGrid(n: 8, h: 8, resM: 0.5, bandM: 0.5);
    addTearDown(grid.dispose);
    expect(
      () => grid.accreteFromDepth(
        depth: primaryDepth(), dw: 4, dh: 4,
        intrinsics: const [2, 2, 1.5], pose: identity, keyframeId: 1),
      throwsArgumentError,
    );
  });

  test('depth length != dw*dh throws ArgumentError', () {
    final grid = carty.createWorldGrid(n: 8, h: 8, resM: 0.5, bandM: 0.5);
    addTearDown(grid.dispose);
    expect(
      () => grid.accreteFromDepth(
        depth: Uint16List(15), dw: 4, dh: 4,
        intrinsics: const [2, 2, 1.5, 1.5], pose: identity, keyframeId: 1),
      throwsArgumentError,
    );
  });

  test('replaying the same depth twice yields an identical grid hash', () {
    final dir = Directory.systemTemp.createTempSync('d2_replay');
    addTearDown(() => dir.deleteSync(recursive: true));
    // One depth-bearing keyframe: u=1,v=1,Z=2000 in a 4x4 buffer.
    final depth = Uint16List(16)..[1 * 4 + 1] = 2000;
    File('${dir.path}/d_1.dep').writeAsBytesSync(depth.buffer.asUint8List());
    final sample = PoseSample(
      t: 1, tx: 0, ty: 0, tz: 0, qx: 0, qy: 0, qz: 0, qw: 1,
      state: TrackingState.tracking,
      depth: const DepthBlock(
        depthPath: 'd_1.dep', confPath: null, dw: 4, dh: 4,
        fx: 2, fy: 2, cx: 1.5, cy: 1.5,
        stx: 0, sty: 0, stz: 0, sqx: 0, sqy: 0, sqz: 0, sqw: 1),
    );

    String fuseOnce() {
      final grid = carty.createWorldGrid(n: 8, h: 8, resM: 0.5, bandM: 0.5);
      try {
        final frame = loadDepthFrame(dir.path, sample);
        grid.accreteFromDepth(
          depth: frame.depth,
          dw: frame.dw,
          dh: frame.dh,
          conf: frame.confidence,
          intrinsics: [
            sample.depth!.fx, sample.depth!.fy,
            sample.depth!.cx, sample.depth!.cy,
          ],
          pose: sample.depth!.toSensorPoseMatrix(),
          keyframeId: sample.t,
        );
        return sha256.convert(grid.cells).toString();
      } finally {
        grid.dispose();
      }
    }

    expect(fuseOnce(), equals(fuseOnce()));
  });
}
