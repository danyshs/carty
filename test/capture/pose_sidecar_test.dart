// test/capture/pose_sidecar_test.dart
import 'dart:convert';
import 'dart:math' as math;
import 'package:carty/capture.dart';
import 'package:test/test.dart';

void main() {
  group('PoseSample.fromJsonLine', () {
    test('parses a well-formed TRACKING line', () {
      final s = PoseSample.fromJsonLine(
        '{"t":1234,"tx":1.0,"ty":2.0,"tz":3.0,'
        '"qx":0.0,"qy":0.0,"qz":0.0,"qw":1.0,"state":"TRACKING"}');
      expect(s.t, 1234);
      expect(s.tx, 1.0);
      expect(s.tz, 3.0);
      expect(s.qw, 1.0);
      expect(s.state, TrackingState.tracking);
    });

    test('round-trips through toJsonLine (deterministic field order)', () {
      const line = '{"t":7,"tx":0.5,"ty":-0.25,"tz":4.0,'
          '"qx":0.1,"qy":0.2,"qz":0.3,"qw":0.9,"state":"PAUSED"}';
      final reSerialized = PoseSample.fromJsonLine(line).toJsonLine();
      // Re-parse both and compare as maps (key order independent, value exact).
      expect(jsonDecode(reSerialized), jsonDecode(line));
      expect(PoseSample.fromJsonLine(reSerialized).state, TrackingState.paused);
    });

    test('throws FormatException on a missing field', () {
      expect(
        () => PoseSample.fromJsonLine('{"t":1,"tx":0.0}'),
        throwsFormatException,
      );
    });

    test('throws FormatException on non-JSON / truncated line', () {
      expect(() => PoseSample.fromJsonLine('{"t":1,'), throwsFormatException);
      expect(() => PoseSample.fromJsonLine('not json'), throwsFormatException);
    });

    test('throws FormatException on an unknown state', () {
      expect(
        () => PoseSample.fromJsonLine('{"t":1,"tx":0,"ty":0,"tz":0,'
            '"qx":0,"qy":0,"qz":0,"qw":1,"state":"WOBBLY"}'),
        throwsFormatException,
      );
    });
  });

  group('PoseSample.toPoseMatrix', () {
    test('identity quaternion → translation in the 4th column (row-major)', () {
      final s = PoseSample.fromJsonLine('{"t":0,"tx":1.0,"ty":2.0,"tz":3.0,'
          '"qx":0,"qy":0,"qz":0,"qw":1,"state":"TRACKING"}');
      final m = s.toPoseMatrix();
      expect(m.length, 16);
      // Row-major 4x4: rotation is identity, translation at indices 3,7,11.
      expect(m[0], closeTo(1.0, 1e-12));
      expect(m[5], closeTo(1.0, 1e-12));
      expect(m[10], closeTo(1.0, 1e-12));
      expect(m[3], closeTo(1.0, 1e-12)); // tx
      expect(m[7], closeTo(2.0, 1e-12)); // ty
      expect(m[11], closeTo(3.0, 1e-12)); // tz
      expect(m[15], closeTo(1.0, 1e-12));
    });

    test('90° yaw about world-up (Y) rotates +Z forward toward +X', () {
      // Quaternion for +90° about Y: (qx,qy,qz,qw)=(0, sin45, 0, cos45).
      final c = math.cos(math.pi / 4), sn = math.sin(math.pi / 4);
      final s = PoseSample.fromJsonLine('{"t":0,"tx":0,"ty":0,"tz":0,'
          '"qx":0,"qy":$sn,"qz":0,"qw":$c,"state":"TRACKING"}');
      final m = s.toPoseMatrix();
      // Camera forward (cam -Z) maps via rotation; check the rotation block is
      // a proper +90°-about-Y matrix (row-major): m[0]=cos, m[2]=sin, m[8]=-sin.
      expect(m[0], closeTo(0.0, 1e-9));
      expect(m[2], closeTo(1.0, 1e-9));
      expect(m[8], closeTo(-1.0, 1e-9));
      expect(m[5], closeTo(1.0, 1e-9));
    });

    test('normalizes a non-unit quaternion before building rotation', () {
      final s = PoseSample.fromJsonLine('{"t":0,"tx":0,"ty":0,"tz":0,'
          '"qx":0,"qy":0,"qz":0,"qw":2.0,"state":"TRACKING"}'); // |q|=2
      final m = s.toPoseMatrix();
      expect(m[0], closeTo(1.0, 1e-12)); // still identity rotation after norm
      expect(m[5], closeTo(1.0, 1e-12));
      expect(m[10], closeTo(1.0, 1e-12));
    });
  });

  group('DepthBlock.toSensorPoseMatrix', () {
    DepthBlock block({
      double sqx = 0, double sqy = 0, double sqz = 0, double sqw = 1,
      double stx = 0, double sty = 0, double stz = 0,
    }) =>
        DepthBlock(
          depthPath: 'd.dep', confPath: null, dw: 4, dh: 4,
          fx: 2, fy: 2, cx: 1.5, cy: 1.5,
          stx: stx, sty: sty, stz: stz,
          sqx: sqx, sqy: sqy, sqz: sqz, sqw: sqw,
        );

    test('identity quaternion gives identity rotation + translation column', () {
      final m = block(stx: 1, sty: 2, stz: 3).toSensorPoseMatrix();
      expect(m.length, 16);
      // rotation block = identity
      expect(m[0], closeTo(1, 1e-12));
      expect(m[5], closeTo(1, 1e-12));
      expect(m[10], closeTo(1, 1e-12));
      // translation in 4th column
      expect(m[3], closeTo(1, 1e-12));
      expect(m[7], closeTo(2, 1e-12));
      expect(m[11], closeTo(3, 1e-12));
      expect(m[15], closeTo(1, 1e-12));
    });

    test('90 deg yaw about Y maps camera basis correctly (row-major)', () {
      // q = (0, sin45, 0, cos45): R = [[0,0,1],[0,1,0],[-1,0,0]]
      const s = 0.7071067811865476;
      final m = block(sqx: 0, sqy: s, sqz: 0, sqw: s).toSensorPoseMatrix();
      expect(m[0], closeTo(0, 1e-9));
      expect(m[2], closeTo(1, 1e-9));
      expect(m[8], closeTo(-1, 1e-9));
      expect(m[10], closeTo(0, 1e-9));
    });

    test('non-unit quaternion is normalized (no injected scale)', () {
      // (0,0,0,2) -> normalizes to identity rotation, not 2x scale.
      final m = block(sqw: 2).toSensorPoseMatrix();
      expect(m[0], closeTo(1, 1e-12));
      expect(m[5], closeTo(1, 1e-12));
      expect(m[10], closeTo(1, 1e-12));
    });

    test('degenerate (all-zero) quaternion falls back to identity rotation', () {
      final m = block(sqw: 0).toSensorPoseMatrix();
      expect(m[0], closeTo(1, 1e-12));
      expect(m[5], closeTo(1, 1e-12));
      expect(m[10], closeTo(1, 1e-12));
    });
  });
}
