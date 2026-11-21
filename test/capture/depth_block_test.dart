import 'dart:convert';
import 'package:carty/capture.dart';
import 'package:test/test.dart';

// A full depth-bearing line: display-oriented top-level pose + depth block
// carrying paths, dims, scaled intrinsics, and the SENSOR pose (s*).
const _withDepth =
    '{"t":123,"tx":1.0,"ty":2.0,"tz":3.0,"qx":0.0,"qy":0.0,"qz":0.0,"qw":1.0,'
    '"state":"TRACKING","depth":"d_123.dep","conf":"c_123.dep","dw":160,"dh":120,'
    '"fx":120.5,"fy":120.5,"cx":80.0,"cy":60.0,'
    '"stx":1.1,"sty":2.2,"stz":3.3,"sqx":0.0,"sqy":0.0,"sqz":0.0,"sqw":1.0}';

void main() {
  group('PoseSample depth block', () {
    test('parses a line WITH the depth block (all fields incl sensor pose)', () {
      final s = PoseSample.fromJsonLine(_withDepth);
      expect(s.t, 123);
      expect(s.tx, 1.0); // top-level pose untouched
      final d = s.depth;
      expect(d, isNotNull);
      expect(d!.depthPath, 'd_123.dep');
      expect(d.confPath, 'c_123.dep');
      expect(d.dw, 160);
      expect(d.dh, 120);
      expect(d.fx, 120.5);
      expect(d.cy, 60.0);
      expect(d.stx, 1.1);
      expect(d.sqw, 1.0);
    });

    test('parses a line WITHOUT a depth block (backward-compat for fixtures)', () {
      final s = PoseSample.fromJsonLine(
        '{"t":1,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
        '"state":"TRACKING"}');
      expect(s.depth, isNull);
    });

    test('depth present but conf absent → depth parses, confPath null', () {
      const line =
          '{"t":7,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
          '"state":"TRACKING","depth":"d_7.dep","dw":160,"dh":120,'
          '"fx":1,"fy":1,"cx":1,"cy":1,'
          '"stx":0,"sty":0,"stz":0,"sqx":0,"sqy":0,"sqz":0,"sqw":1}';
      final d = PoseSample.fromJsonLine(line).depth;
      expect(d, isNotNull);
      expect(d!.confPath, isNull);
    });

    test('round-trips WITH depth block (re-parse equals original map)', () {
      final reSerialized = PoseSample.fromJsonLine(_withDepth).toJsonLine();
      expect(jsonDecode(reSerialized), jsonDecode(_withDepth));
    });

    test('round-trips WITHOUT depth block (no depth keys emitted)', () {
      const line = '{"t":2,"tx":1,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
          '"state":"PAUSED"}';
      final reSerialized = PoseSample.fromJsonLine(line).toJsonLine();
      expect(jsonDecode(reSerialized), jsonDecode(line));
      expect(reSerialized.contains('depth'), isFalse);
    });
  });

  group('PoseSample depth block — fail safe', () {
    // Every line below has depth present, so dims+intrinsics+sensor pose are
    // required; each omission/typo must throw FormatException, not default.
    const base = '"t":1,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
        '"state":"TRACKING","depth":"d_1.dep"';
    const intr = '"fx":1,"fy":1,"cx":1,"cy":1';
    const sp = '"stx":0,"sty":0,"stz":0,"sqx":0,"sqy":0,"sqz":0,"sqw":1';

    test('depth present but dw/dh missing → FormatException', () {
      expect(() => PoseSample.fromJsonLine('{$base,$intr,$sp}'),
          throwsFormatException);
    });

    test('depth present but intrinsics missing → FormatException', () {
      expect(
          () => PoseSample.fromJsonLine('{$base,"dw":160,"dh":120,$sp}'),
          throwsFormatException);
    });

    test('depth present but sensor pose missing → FormatException', () {
      expect(
          () => PoseSample.fromJsonLine('{$base,"dw":160,"dh":120,$intr}'),
          throwsFormatException);
    });

    test('non-numeric depth field → FormatException', () {
      expect(
          () => PoseSample.fromJsonLine(
              '{$base,"dw":"wide","dh":120,$intr,$sp}'),
          throwsFormatException);
    });

    test('truncated line → FormatException', () {
      expect(() => PoseSample.fromJsonLine('{$base,"dw":160,'),
          throwsFormatException);
    });
  });
}
