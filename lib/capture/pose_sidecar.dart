/// Pose sidecar model: the on-disk record of ARCore 6-DoF pose per keyframe and
/// the bridge between it and the fusion ABI. It exists so a live capture is a
/// REPLAYABLE artifact: record on device → replay
/// headless → identical fused grid. The line schema is frozen;
/// deleting this module would break both record and
/// the deterministic replay the whole capture test strategy rests on.
library;

import 'dart:convert';
import 'dart:math' as math;

/// ARCore tracking state carried per keyframe. Only TRACKING samples carry a
/// trustworthy pose; PAUSED is recorded so replay/overlay can show the gap
/// honestly rather than interpolating over it.
enum TrackingState {
  tracking,
  paused;

  static TrackingState fromName(String name) {
    switch (name) {
      case 'TRACKING':
        return TrackingState.tracking;
      case 'PAUSED':
        return TrackingState.paused;
      default:
        throw FormatException('unknown tracking state: $name');
    }
  }

  String get wireName => this == TrackingState.tracking ? 'TRACKING' : 'PAUSED';
}

/// The optional per-keyframe depth record. Exists so a replayed capture
/// carries everything depth reprojection needs to reproject depth offline: the raw depth +
/// confidence blob basenames, their native dimensions, the depth-camera pinhole
/// intrinsics (scaled to dw×dh), and — critically — the PHYSICAL-SENSOR pose
/// `s*`. The top-level PoseSample pose is ARCore's displayOrientedPose (chosen so
/// the photo-map replays upright); sensor-native depth must reproject through the
/// sensor pose or it shears (see the depth recording design). Presence of this block IS the
/// schema version — absence means "no depth for this keyframe".
class DepthBlock {
  const DepthBlock({
    required this.depthPath,
    required this.confPath,
    required this.dw,
    required this.dh,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.stx,
    required this.sty,
    required this.stz,
    required this.sqx,
    required this.sqy,
    required this.sqz,
    required this.sqw,
  });

  final String depthPath; // basename of d_<t>.dep, sibling to the sidecar
  final String? confPath; // basename of c_<t>.dep; null if no confidence plane
  final int dw, dh; // native depth resolution (do not hard-code 160×120)
  final double fx, fy, cx, cy; // depth-camera pinhole intrinsics, scaled to dw×dh
  final double stx, sty, stz; // physical-sensor translation (floor-relative)
  final double sqx, sqy, sqz, sqw; // physical-sensor rotation quaternion

  /// Build the 16-element 4×4 ROW-MAJOR camera→world matrix for the PHYSICAL
  /// SENSOR pose (`s*`), the frame the raw depth buffer and its intrinsics live
  /// in. depth reprojection reprojects depth through THIS, not PoseSample's display-oriented pose
  /// (sensor depth through a display pose shears). Mirrors
  /// PoseSample.toPoseMatrix(): the quaternion is normalized first so a drifted
  /// ARCore quaternion can never inject scale/shear; a degenerate quaternion →
  /// identity rotation (honest: no fabricated turn).
  List<double> toSensorPoseMatrix() {
    var x = sqx, y = sqy, z = sqz, w = sqw;
    final n = math.sqrt(x * x + y * y + z * z + w * w);
    if (n == 0 || !n.isFinite) {
      x = 0; y = 0; z = 0; w = 1;
    } else {
      x /= n; y /= n; z /= n; w /= n;
    }
    final xx = x * x, yy = y * y, zz = z * z;
    final xy = x * y, xz = x * z, yz = y * z;
    final wx = w * x, wy = w * y, wz = w * z;
    return <double>[
      1 - 2 * (yy + zz), 2 * (xy - wz),     2 * (xz + wy),     stx,
      2 * (xy + wz),     1 - 2 * (xx + zz), 2 * (yz - wx),     sty,
      2 * (xz - wy),     2 * (yz + wx),     1 - 2 * (xx + yy), stz,
      0,                 0,                 0,                 1,
    ];
  }
}

/// One pose-sidecar keyframe. Immutable; a thin value over the frozen schema.
class PoseSample {
  const PoseSample({
    required this.t,
    required this.tx,
    required this.ty,
    required this.tz,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.qw,
    required this.state,
    this.depth,
  });

  final int t; // timestamp ms (also the stable keyframe_id for accrete)
  final double tx, ty, tz; // world translation (ARCore Y-up)
  final double qx, qy, qz, qw; // world rotation quaternion
  final TrackingState state;
  final DepthBlock? depth; // optional depth recording depth record; null = depth-less keyframe

  /// Parse one newline-delimited JSON keyframe. Any missing/mistyped field or
  /// non-JSON text is DATA corruption → FormatException (the "fail safely"
  /// contract), never a silent default.
  factory PoseSample.fromJsonLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (e) {
      throw FormatException('pose sidecar: not JSON: ${e.message}', line);
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('pose sidecar: line is not a JSON object', line);
    }
    final map = decoded;
    num req(String k) {
      final v = map[k];
      if (v is! num) {
        throw FormatException('pose sidecar: missing/!num field "$k"', line);
      }
      return v;
    }
    final stateRaw = map['state'];
    if (stateRaw is! String) {
      throw FormatException('pose sidecar: missing "state"', line);
    }
    DepthBlock? depth;
    final depthRaw = map['depth'];
    if (depthRaw != null) {
      if (depthRaw is! String) {
        throw FormatException('pose sidecar: "depth" not a string', line);
      }
      // When depth is present, dims + intrinsics + sensor pose are REQUIRED;
      // each missing/non-numeric field is corruption → FormatException.
      num dreq(String k) {
        final v = map[k];
        if (v is! num) {
          throw FormatException(
              'pose sidecar: depth present but missing/!num "$k"', line);
        }
        return v;
      }
      final confRaw = map['conf'];
      if (confRaw != null && confRaw is! String) {
        throw FormatException('pose sidecar: "conf" not a string', line);
      }
      depth = DepthBlock(
        depthPath: depthRaw,
        confPath: confRaw as String?,
        dw: dreq('dw').toInt(),
        dh: dreq('dh').toInt(),
        fx: dreq('fx').toDouble(),
        fy: dreq('fy').toDouble(),
        cx: dreq('cx').toDouble(),
        cy: dreq('cy').toDouble(),
        stx: dreq('stx').toDouble(),
        sty: dreq('sty').toDouble(),
        stz: dreq('stz').toDouble(),
        sqx: dreq('sqx').toDouble(),
        sqy: dreq('sqy').toDouble(),
        sqz: dreq('sqz').toDouble(),
        sqw: dreq('sqw').toDouble(),
      );
    }
    return PoseSample(
      t: req('t').toInt(),
      tx: req('tx').toDouble(),
      ty: req('ty').toDouble(),
      tz: req('tz').toDouble(),
      qx: req('qx').toDouble(),
      qy: req('qy').toDouble(),
      qz: req('qz').toDouble(),
      qw: req('qw').toDouble(),
      state: TrackingState.fromName(stateRaw),
      depth: depth,
    );
  }

  /// Serialize back to the frozen schema (stable field order for golden tests).
  /// The optional depth block's keys are appended after `state` only when present
  /// — a depth-less keyframe is byte-identical to the pre-depth schema.
  String toJsonLine() {
    final m = <String, Object?>{
      't': t,
      'tx': tx,
      'ty': ty,
      'tz': tz,
      'qx': qx,
      'qy': qy,
      'qz': qz,
      'qw': qw,
      'state': state.wireName,
    };
    final d = depth;
    if (d != null) {
      m['depth'] = d.depthPath;
      if (d.confPath != null) m['conf'] = d.confPath;
      m['dw'] = d.dw;
      m['dh'] = d.dh;
      m['fx'] = d.fx;
      m['fy'] = d.fy;
      m['cx'] = d.cx;
      m['cy'] = d.cy;
      m['stx'] = d.stx;
      m['sty'] = d.sty;
      m['stz'] = d.stz;
      m['sqx'] = d.sqx;
      m['sqy'] = d.sqy;
      m['sqz'] = d.sqz;
      m['sqw'] = d.sqw;
    }
    return jsonEncode(m);
  }

  /// Build the 16-element 4×4 ROW-MAJOR camera→world matrix `accrete` expects
  /// (translation in the 4th column). The quaternion is normalized first so a
  /// drifted/non-unit ARCore quaternion can never inject scale/shear into the
  /// rotation block (which would silently mis-scale fusion).
  List<double> toPoseMatrix() {
    var x = qx, y = qy, z = qz, w = qw;
    final n = math.sqrt(x * x + y * y + z * z + w * w);
    if (n == 0 || !n.isFinite) {
      // Degenerate quaternion → identity rotation (honest: no fabricated turn).
      x = 0; y = 0; z = 0; w = 1;
    } else {
      x /= n; y /= n; z /= n; w /= n;
    }
    final xx = x * x, yy = y * y, zz = z * z;
    final xy = x * y, xz = x * z, yz = y * z;
    final wx = w * x, wy = w * y, wz = w * z;
    // Standard quaternion→rotation (right-handed), laid out row-major with the
    // translation column.
    return <double>[
      1 - 2 * (yy + zz), 2 * (xy - wz),     2 * (xz + wy),     tx,
      2 * (xy + wz),     1 - 2 * (xx + zz), 2 * (yz - wx),     ty,
      2 * (xz - wy),     2 * (yz + wx),     1 - 2 * (xx + yy), tz,
      0,                 0,                 0,                 1,
    ];
  }
}
