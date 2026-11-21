// tool/synthetic_capture.dart
//
// The pure-math core of the synthetic capture generator (no file I/O) — the
// thing that makes the end-to-end gate HONEST: it ray-casts depth against the
// scene's true wall geometry using the EXACT camera convention the native
// reprojector inverts (carty_fusion.cpp:557,723), so a synthesized depth value
// replays back through accreteFromDepth onto the wall it came from. Kept I/O-free
// so the convention is unit-testable in isolation; the writer (gen_capture.dart)
// adds disk + sidecar on top. Delete this and the gate would be back to scoring
// a painted-truth stub instead of a real fused grid.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// A wall as a vertical quad: the ground-plane segment A=(x1,z1)→B=(x2,z2) in
/// world metres (world X = `x`, world Z = `z`), extruded in world Y from 0 to
/// `wallTop`. Walls are the only occluders the ray-caster knows about.
class WallSeg {
  const WallSeg(this.x1, this.z1, this.x2, this.z2);
  final double x1, z1, x2, z2;
}

/// A camera placement on the ground plane: position (world X,Z) + heading (yaw
/// about world Y). Height is applied when the 4×4 pose is built.
typedef CamPose = ({double x, double z, double yawRad});

/// The 16-element 4×4 ROW-MAJOR cam→world matrix for a camera at (camX,camY,camZ)
/// looking along its −Z, rotated by [yawRad] about world Y. Laid out IDENTICALLY
/// to [PoseSample.toPoseMatrix] so the quaternion gen_capture emits
/// ((0,sin(θ/2),0,cos(θ/2))) reproduces this exact matrix — the consistency that
/// lets synthetic depth round-trip through the native reprojector unchanged.
List<double> poseMatrixFromYaw(
    double camX, double camY, double camZ, double yawRad) {
  final c = math.cos(yawRad), s = math.sin(yawRad);
  return <double>[
    c, 0, s, camX, //
    0, 1, 0, camY, //
    -s, 0, c, camZ, //
    0, 0, 0, 1, //
  ];
}

/// Per-pixel depth (uint16 millimetres, row-major, length dw*dh; 0 = no wall hit
/// within [maxRange]) for a camera at (camX,camY,camZ)/[yawRad] looking at
/// [walls]. The stored value for a pixel is the ray PARAMETER `s` (×1000) where
/// `cam + s·dWorld` first strikes a wall — because the native reprojector
/// reconstructs `cam + (depth_mm/1000)·dWorld` from the same `dCam`, so `s` is
/// exactly the depth that lands the hit back on its wall. Occlusion is honest:
/// the nearest hit along each ray wins. Bounded by dw*dh*walls.length.
Uint16List raycastDepth({
  required double camX,
  required double camY,
  required double camZ,
  required double yawRad,
  required List<WallSeg> walls,
  required int dw,
  required int dh,
  required double fx,
  required double fy,
  required double cx,
  required double cy,
  required double wallTop,
  required double maxRange,
}) {
  final c = math.cos(yawRad), s = math.sin(yawRad);
  final out = Uint16List(dw * dh);
  for (var v = 0; v < dh; v++) {
    for (var u = 0; u < dw; u++) {
      // Native camera-space ray (carty_fusion.cpp:557): z = -1, v-axis flipped.
      final dCx = (u - cx) / fx;
      final dCy = -((v - cy) / fy);
      const dCz = -1.0;
      // Rotate cam→world by the yaw matrix (translation irrelevant for a dir).
      final dWx = c * dCx + s * dCz;
      final dWy = dCy;
      final dWz = -s * dCx + c * dCz;

      var best = double.infinity;
      for (final w in walls) {
        final ex = w.x2 - w.x1, ez = w.z2 - w.z1;
        // Solve cam_xz + sPar*dW_xz = A + t*(B-A) for (sPar, t).
        final det = -dWx * ez + ex * dWz;
        if (det.abs() < 1e-12) continue; // ray parallel to the wall line
        final rx = w.x1 - camX, rz = w.z1 - camZ;
        final sPar = (-rx * ez + ex * rz) / det;
        final t = (dWx * rz - dWz * rx) / det;
        if (sPar <= 0 || sPar > maxRange) continue;
        if (t < 0 || t > 1) continue; // hit misses the finite segment
        final y = camY + sPar * dWy;
        if (y < 0 || y > wallTop) continue; // above/below the wall quad
        if (sPar < best) best = sPar; // nearest hit wins (occlusion)
      }
      if (best.isFinite) {
        final mm = (best * 1000).round().clamp(1, 65535);
        out[v * dw + u] = mm;
      }
    }
  }
  return out;
}

/// A scripted, continuous walk: sweep the camera through a full turn at each
/// room centre (so every wall is seen) and walk between rooms via the door,
/// facing the direction of travel. Returns ground poses in capture order. Exists
/// so the fused grid comes from realistic motion + occlusion, not a few hand-
/// placed shots — the honesty the gate rests on. Bounded by the room/step counts.
List<CamPose> scriptedWalk({
  required List<({double x, double z})> roomCenters,
  required double doorX,
  required double doorZ,
  int yawSteps = 12,
  int walkSteps = 6,
}) {
  final out = <CamPose>[];
  void sweep(double x, double z) {
    for (var i = 0; i < yawSteps; i++) {
      out.add((x: x, z: z, yawRad: 2 * math.pi * i / yawSteps));
    }
  }

  double heading(double dx, double dz) {
    if (dx == 0 && dz == 0) return 0;
    // Camera forward = (-sinθ, -cosθ); face the travel direction (dx,dz).
    // atan2 is scale-invariant, so no normalization is needed.
    return math.atan2(-dx, -dz);
  }

  void walk(({double x, double z}) a, ({double x, double z}) b) {
    final yaw = heading(b.x - a.x, b.z - a.z);
    for (var i = 1; i <= walkSteps; i++) {
      final t = i / walkSteps;
      out.add((x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t, yawRad: yaw));
    }
  }

  final door = (x: doorX, z: doorZ);
  sweep(roomCenters[0].x, roomCenters[0].z);
  walk(roomCenters[0], door);
  walk(door, roomCenters[1]);
  sweep(roomCenters[1].x, roomCenters[1].z);
  return out;
}
