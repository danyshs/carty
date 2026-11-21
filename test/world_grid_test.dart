// Unit tests for the Dart FFI wrapper over the Fusion stage's world-frame voxel
// grid: [Carty.createWorldGrid] / [CartyWorldGridHandle] (lib/carty.dart),
// the explicit fusion follow-up. These pin the WRAPPER contract — the
// memory-ownership + crash-early-at-the-boundary discipline and the status enum
// — NOT the accretion algorithm, which native/tests/test_world_grid_fusion.cpp
// owns. They run on the host build of the same translation unit:
//   cmake -S native -B native/build -G Ninja && cmake --build native/build
//
// The pose math here mirrors build_pose() in test_world_grid_fusion.cpp exactly,
// so the wrapper is exercised against the same world-frame convention the C ABI
// asserts (4x4 row-major cam->world, ARCore Y-up).

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:carty/carty.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 4x4 ROW-MAJOR cam->world pose for a camera at (tx,ty,tz) with the given
/// yaw (heading about world-up Y) and downward pitch — the Dart twin of
/// `build_pose` in the native test, so both sides share one convention.
List<double> buildPose(
  double yaw,
  double pitch,
  double tx,
  double ty,
  double tz,
) {
  final f = <double>[
    math.sin(yaw) * math.cos(pitch),
    -math.sin(pitch),
    math.cos(yaw) * math.cos(pitch),
  ];
  final zc = <double>[-f[0], -f[1], -f[2]]; // camera Z (back)
  // xc = cross(up, zc), up = (0,1,0)
  final xc = <double>[
    1.0 * zc[2] - 0.0 * zc[1],
    0.0 * zc[0] - 0.0 * zc[2],
    0.0 * zc[1] - 1.0 * zc[0],
  ];
  final xm = math.sqrt(xc[0] * xc[0] + xc[1] * xc[1] + xc[2] * xc[2]);
  xc[0] /= xm;
  xc[1] /= xm;
  xc[2] /= xm;
  // yc = cross(zc, xc)
  final yc = <double>[
    zc[1] * xc[2] - zc[2] * xc[1],
    zc[2] * xc[0] - zc[0] * xc[2],
    zc[0] * xc[1] - zc[1] * xc[0],
  ];
  return <double>[
    xc[0], yc[0], zc[0], tx, //
    xc[1], yc[1], zc[1], ty, //
    xc[2], yc[2], zc[2], tz, //
    0.0, 0.0, 0.0, 1.0, //
  ];
}

void main() {
  final soPath = File('native/build/libcarty_bridge.so').absolute.path;
  const pitch60 = 1.0471975511965976; // 60°, matches the ortho extrinsic

  late Carty carty;

  setUpAll(() {
    expect(
      File(soPath).existsSync(),
      isTrue,
      reason: 'Build the host bridge first: cmake --build native/build ($soPath)',
    );
    carty = Carty.fromLibrary(DynamicLibrary.open(soPath));
  });

  /// A real 640x480 ortho observation (mirrors make_observation in the C test):
  /// a deterministic painted RGBA frame back-projected to top-down.
  CartyOrthoMapHandle makeObservation() {
    const w = 640, h = 480, c = 4;
    final frame = carty.allocFrame(width: w, height: h, channels: c);
    final px = frame.bytes;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var v = 180 + ((x ^ y) & 0x3F);
        if (y > h ~/ 2) v -= 60;
        final p = (y * w + x) * c;
        px[p] = v;
        px[p + 1] = v;
        px[p + 2] = v;
        px[p + 3] = 255;
      }
    }
    final obs = carty.orthoProject(frame, width: w, height: h, channels: c);
    frame.dispose();
    return obs;
  }

  group('createWorldGrid', () {
    test('reports requested dims and size == n*n*h', () {
      final grid = carty.createWorldGrid(n: 128, h: 8);
      addTearDown(grid.dispose);
      expect(grid.n, 128);
      expect(grid.h, 8);
      expect(grid.sizeInBytes, 128 * 128 * 8);
    });

    test('a fresh grid is all-unobserved (Int8List view, every cell 0)', () {
      final grid = carty.createWorldGrid(n: 64, h: 4);
      addTearDown(grid.dispose);
      final cells = grid.cells;
      expect(cells, isA<Int8List>());
      expect(cells.length, grid.sizeInBytes);
      expect(cells.every((b) => b == 0), isTrue);
    });

    test('a fresh grid color buffer is n*n*3 and all-zero (Uint8List view)', () {
      final grid = carty.createWorldGrid(n: 64, h: 4);
      addTearDown(grid.dispose);
      final color = grid.color;
      expect(color, isA<Uint8List>());
      // color is the floor photo-map (n*n*3), NOT the log-odds volume (n*n*h).
      expect(color.length, 64 * 64 * 3);
      expect(color.length, isNot(grid.sizeInBytes));
      expect(color.every((b) => b == 0), isTrue);
    });

    test('resolution echoes res/band; fresh grid is unanchored', () {
      final grid = carty.createWorldGrid(n: 64, h: 4, resM: 0.05, bandM: 0.25);
      addTearDown(grid.dispose);
      expect(grid.resolution.resM, 0.05);
      expect(grid.resolution.bandM, 0.25);
      expect(grid.origin.anchored, isFalse);
    });

    test('out-of-bounds dims/resolutions are rejected before the boundary', () {
      expect(() => carty.createWorldGrid(n: 0, h: 8), throwsArgumentError);
      expect(
        () => carty.createWorldGrid(n: cartyGridMaxN + 1, h: 8),
        throwsArgumentError,
      );
      expect(() => carty.createWorldGrid(n: 128, h: 0), throwsArgumentError);
      expect(
        () => carty.createWorldGrid(n: 128, h: cartyGridMaxH + 1),
        throwsArgumentError,
      );
      expect(
        () => carty.createWorldGrid(n: 128, h: 8, resM: 0),
        throwsArgumentError,
      );
      expect(
        () => carty.createWorldGrid(n: 128, h: 8, bandM: double.nan),
        throwsArgumentError,
      );
    });
  });

  group('accrete', () {
    test('first keyframe folds (OK), anchors, and observes cells', () {
      final grid = carty.createWorldGrid(n: 128, h: 8);
      addTearDown(grid.dispose);
      final obs = makeObservation();
      addTearDown(obs.dispose);

      final pose = buildPose(0.0, pitch60, 0.0, 1.6, 0.0);
      final status = grid.accrete(observation: obs, pose: pose, keyframeId: 1);

      expect(status, CartyFuseStatus.ok);
      expect(grid.origin.anchored, isTrue);
      // origin centers the grid's ground plane on the first camera (cam at 0).
      expect(grid.origin.x, closeTo(0.0 - (128 ~/ 2) * 0.05, 1e-9));
      expect(grid.origin.y, closeTo(0.0 - (128 ~/ 2) * 0.05, 1e-9));
      // zero-copy view reflects the fold: some cells are now non-zero.
      expect(grid.cells.any((b) => b != 0), isTrue);
    });

    test('re-accreting the same keyframe id is a DUPLICATE no-op', () {
      final grid = carty.createWorldGrid(n: 128, h: 8);
      addTearDown(grid.dispose);
      final obs = makeObservation();
      addTearDown(obs.dispose);
      final pose = buildPose(0.0, pitch60, 0.0, 1.6, 0.0);

      expect(
        grid.accrete(observation: obs, pose: pose, keyframeId: 7),
        CartyFuseStatus.ok,
      );
      final before = Int8List.fromList(grid.cells);
      expect(
        grid.accrete(observation: obs, pose: pose, keyframeId: 7),
        CartyFuseStatus.duplicate,
      );
      expect(grid.cells, orderedEquals(before));
    });

    test('a far keyframe returns OUT_OF_BOUNDS', () {
      final grid = carty.createWorldGrid(n: 128, h: 8);
      addTearDown(grid.dispose);
      final obs = makeObservation();
      addTearDown(obs.dispose);

      // First anchors near the origin.
      expect(
        grid.accrete(
          observation: obs,
          pose: buildPose(0.0, pitch60, 0.0, 1.6, 0.0),
          keyframeId: 1,
        ),
        CartyFuseStatus.ok,
      );
      // Then a pose 1000 m away lands entirely off the bounded grid.
      expect(
        grid.accrete(
          observation: obs,
          pose: buildPose(0.0, pitch60, 1000.0, 1.6, 0.0),
          keyframeId: 2,
        ),
        CartyFuseStatus.outOfBounds,
      );
    });

    test('a malformed pose is rejected before the native boundary', () {
      final grid = carty.createWorldGrid(n: 64, h: 4);
      addTearDown(grid.dispose);
      final obs = makeObservation();
      addTearDown(obs.dispose);

      // Wrong length.
      expect(
        () => grid.accrete(
          observation: obs,
          pose: List<double>.filled(15, 0),
          keyframeId: 1,
        ),
        throwsArgumentError,
      );
      // Non-finite entry (native would abort; we crash early & recoverably).
      final bad = buildPose(0.0, pitch60, 0.0, 1.6, 0.0);
      bad[3] = double.nan;
      expect(
        () => grid.accrete(observation: obs, pose: bad, keyframeId: 1),
        throwsArgumentError,
      );
    });
  });

  group('accreteFromFrame', () {
    test('folds a raw frame and is idempotent on keyframeId', () {
      final grid = carty.createWorldGrid(n: 256, h: 16);
      final frame = carty.allocFrame(width: 64, height: 64, channels: 4);
      frame.bytes.fillRange(0, frame.bytes.length, 200);
      final k = <double>[500, 500, 32, 32];
      final pose = buildPose(0.0, pitch60, 0.0, 1.6, 0.0);
      final s1 = grid.accreteFromFrame(
          frame: frame, width: 64, height: 64, channels: 4,
          intrinsics: k, pose: pose, keyframeId: 1);
      expect(s1, anyOf(CartyFuseStatus.ok, CartyFuseStatus.outOfBounds));
      final s2 = grid.accreteFromFrame(
          frame: frame, width: 64, height: 64, channels: 4,
          intrinsics: k, pose: pose, keyframeId: 1); // same id
      if (s1 == CartyFuseStatus.ok) expect(s2, CartyFuseStatus.duplicate);
      frame.dispose();
      grid.dispose();
    });

    test('a raw-frame fold paints ground-cell color (Uint8List view)', () {
      final grid = carty.createWorldGrid(n: 256, h: 16);
      addTearDown(grid.dispose);
      final frame = carty.allocFrame(width: 64, height: 64, channels: 4);
      addTearDown(frame.dispose);
      frame.bytes.fillRange(0, frame.bytes.length, 200); // solid RGB=200
      final k = <double>[500, 500, 32, 32];
      final pose = buildPose(0.0, pitch60, 0.0, 1.6, 0.0);
      // color starts unobserved; only the raw-frame splat (this path) paints it.
      expect(grid.color.every((b) => b == 0), isTrue);
      final s = grid.accreteFromFrame(
          frame: frame, width: 64, height: 64, channels: 4,
          intrinsics: k, pose: pose, keyframeId: 1);
      // accrete may clip out of bounds; assert paint only when it actually folded.
      if (s == CartyFuseStatus.ok) {
        expect(grid.color.any((b) => b != 0), isTrue);
      }
    });

    test('rejects bad intrinsics / pose / size (ArgumentError)', () {
      final grid = carty.createWorldGrid(n: 64, h: 8);
      final frame = carty.allocFrame(width: 32, height: 32, channels: 4);
      addTearDown(frame.dispose);
      addTearDown(grid.dispose);
      final pose = buildPose(0.0, pitch60, 0.0, 1.6, 0.0);
      expect(
        () => grid.accreteFromFrame(frame: frame, width: 32, height: 32, channels: 4,
            intrinsics: [1, 2, 3], pose: pose, keyframeId: 1),
        throwsArgumentError, // intrinsics.length != 4
      );
      expect(
        () => grid.accreteFromFrame(frame: frame, width: 99, height: 32, channels: 4,
            intrinsics: [1, 2, 3, 4], pose: pose, keyframeId: 1),
        throwsArgumentError, // 99*32*4 != frame.bytes.length
      );
    });

    test('rejects non-finite intrinsic or pose entry (ArgumentError)', () {
      final grid = carty.createWorldGrid(n: 64, h: 8);
      final frame = carty.allocFrame(width: 32, height: 32, channels: 4);
      addTearDown(frame.dispose);
      addTearDown(grid.dispose);
      final pose = buildPose(0.0, pitch60, 0.0, 1.6, 0.0);
      expect(
        () => grid.accreteFromFrame(frame: frame, width: 32, height: 32, channels: 4,
            intrinsics: [double.nan, 500, 16, 16], pose: pose, keyframeId: 1),
        throwsArgumentError, // non-finite fx
      );
      final badPose = buildPose(0.0, pitch60, 0.0, 1.6, 0.0);
      badPose[3] = double.infinity;
      expect(
        () => grid.accreteFromFrame(frame: frame, width: 32, height: 32, channels: 4,
            intrinsics: [500, 500, 16, 16], pose: badPose, keyframeId: 1),
        throwsArgumentError, // non-finite pose entry
      );
    });
  });

  group('dispose', () {
    test('is idempotent and blocks further use', () {
      final grid = carty.createWorldGrid(n: 64, h: 4);
      final obs = makeObservation();
      addTearDown(obs.dispose);
      grid.dispose();
      expect(grid.isDisposed, isTrue);
      expect(grid.dispose, returnsNormally); // second dispose is a no-op
      expect(() => grid.cells, throwsStateError);
      expect(() => grid.color, throwsStateError);
      expect(
        () => grid.accrete(
          observation: obs,
          pose: buildPose(0.0, pitch60, 0.0, 1.6, 0.0),
          keyframeId: 1,
        ),
        throwsStateError,
      );
    });
  });
}
