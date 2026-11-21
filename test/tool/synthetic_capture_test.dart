import 'package:test/test.dart';

import '../../tool/synthetic_capture.dart';

void main() {
  test('raycast: a wall straight ahead at 2 m reads ~2000 mm at the centre', () {
    // Camera at (0,1,0) looking along -Z (yaw 0). Wall is a ground segment at
    // world Z=-2 spanning x in [-1,1]. dWz = -1 for yaw 0, so s solves
    // 0 + s*(-1) = -2 → s = 2 → 2000 mm, independent of the pixel's tilt.
    final walls = [const WallSeg(-1, -2, 1, -2)];
    final depth = raycastDepth(
        camX: 0,
        camY: 1.0,
        camZ: 0,
        yawRad: 0,
        walls: walls,
        dw: 3,
        dh: 3,
        fx: 3,
        fy: 3,
        cx: 1.5,
        cy: 1.5,
        wallTop: 2.5,
        maxRange: 10);
    expect(depth[1 * 3 + 1], closeTo(2000, 60));
  });

  test('raycast: occlusion — the nearer wall wins on a shared ray', () {
    // Straight forward ray (cx=cy=0, single pixel): both walls are hit; the near
    // one (2 m) must win over the far one (5 m).
    final walls = [
      const WallSeg(-1, -2, 1, -2), // near
      const WallSeg(-1, -5, 1, -5), // far, directly behind
    ];
    final depth = raycastDepth(
        camX: 0,
        camY: 1.0,
        camZ: 0,
        yawRad: 0,
        walls: walls,
        dw: 1,
        dh: 1,
        fx: 1,
        fy: 1,
        cx: 0,
        cy: 0,
        wallTop: 5,
        maxRange: 20);
    expect(depth[0], closeTo(2000, 60));
  });

  test('raycast: no hit within range → 0 (a hole)', () {
    final walls = [const WallSeg(-1, -2, 1, -2)];
    // Looking the other way (yaw π) — the wall is behind the camera.
    final depth = raycastDepth(
        camX: 0,
        camY: 1.0,
        camZ: 0,
        yawRad: 3.14159265,
        walls: walls,
        dw: 1,
        dh: 1,
        fx: 1,
        fy: 1,
        cx: 0,
        cy: 0,
        wallTop: 5,
        maxRange: 20);
    expect(depth[0], 0);
  });

  test('scriptedWalk produces a continuous multi-pose path through the door', () {
    final poses = scriptedWalk(
      roomCenters: [(x: 1.5, z: 3), (x: 4.0, z: 3)],
      doorX: 2.5,
      doorZ: 3,
    );
    // two full sweeps + two walk legs → well over a single leg's worth.
    expect(poses.length, greaterThan(12));
    // a door-crossing pose exists (x between the room centres at z≈3).
    expect(poses.any((p) => p.x > 2 && p.x < 3 && (p.z - 3).abs() < 0.01), isTrue);
  });

  test('poseMatrixFromYaw matches the yaw-quaternion rotation layout', () {
    // yaw 90°: forward should become world (-1,0,0); the matrix's columns encode
    // the camera basis. Spot-check the rotation block for θ=π/2.
    final m = poseMatrixFromYaw(7, 1.4, -3, 1.5707963267948966);
    expect(m[0], closeTo(0, 1e-9)); // cosθ
    expect(m[2], closeTo(1, 1e-9)); // sinθ
    expect(m[8], closeTo(-1, 1e-9)); // -sinθ
    expect(m[10], closeTo(0, 1e-9)); // cosθ
    expect(m[3], 7); // translation X
    expect(m[7], 1.4); // translation Y
    expect(m[11], -3); // translation Z
  });
}
