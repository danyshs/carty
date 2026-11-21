import 'dart:io';
import 'dart:typed_data';
import 'package:carty/capture.dart';
import 'package:test/test.dart';

// Build a sidecar dir with a depth (+optional conf) .dep pair for one keyframe.
// Returns (dir, sample). dw*dh = 2*2 = 4 elements for a tiny deterministic fixture.
(Directory, PoseSample) _fixture({bool withConf = true}) {
  final dir = Directory.systemTemp.createTempSync('d1_replay_');
  final depth = Uint16List.fromList([0, 100, 65535, 4]); // incl a 0 hole
  File('${dir.path}/d_5.dep')
      .writeAsBytesSync(depth.buffer.asUint8List()); // host LE
  if (withConf) {
    File('${dir.path}/c_5.dep')
        .writeAsBytesSync(Uint8List.fromList([0, 255, 128, 0]));
  }
  final sample = PoseSample.fromJsonLine(
      '{"t":5,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
      '"state":"TRACKING","depth":"d_5.dep"${withConf ? ',"conf":"c_5.dep"' : ''},'
      '"dw":2,"dh":2,"fx":1,"fy":1,"cx":1,"cy":1,'
      '"stx":0,"sty":0,"stz":0,"sqx":0,"sqy":0,"sqz":0,"sqw":1}');
  return (dir, sample);
}

void main() {
  test('reads depth + confidence buffers of exactly dw×dh', () {
    final (dir, sample) = _fixture();
    final f = loadDepthFrame(dir.path, sample);
    expect(f.depth, [0, 100, 65535, 4]);
    expect(f.confidence, [0, 255, 128, 0]);
    expect(f.dw, 2);
    expect(f.dh, 2);
    dir.deleteSync(recursive: true);
  });

  test('conf absent → confidence is null, depth still reads', () {
    final (dir, sample) = _fixture(withConf: false);
    final f = loadDepthFrame(dir.path, sample);
    expect(f.confidence, isNull);
    expect(f.depth.length, 4);
    dir.deleteSync(recursive: true);
  });

  test('all-zero confidence reads back faithfully (depth recording records, never interprets)',
      () {
    final dir = Directory.systemTemp.createTempSync('d1_zero_');
    File('${dir.path}/d_5.dep')
        .writeAsBytesSync(Uint16List.fromList([1, 2, 3, 4]).buffer.asUint8List());
    File('${dir.path}/c_5.dep').writeAsBytesSync(Uint8List(4)); // all 0x00
    final sample = PoseSample.fromJsonLine(
        '{"t":5,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
        '"state":"TRACKING","depth":"d_5.dep","conf":"c_5.dep","dw":2,"dh":2,'
        '"fx":1,"fy":1,"cx":1,"cy":1,'
        '"stx":0,"sty":0,"stz":0,"sqx":0,"sqy":0,"sqz":0,"sqw":1}');
    expect(loadDepthFrame(dir.path, sample).confidence, [0, 0, 0, 0]);
    dir.deleteSync(recursive: true);
  });

  test('referenced-but-missing .dep file → FormatException (fails safe)', () {
    final dir = Directory.systemTemp.createTempSync('d1_missing_');
    final sample = PoseSample.fromJsonLine(
        '{"t":5,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
        '"state":"TRACKING","depth":"d_5.dep","dw":2,"dh":2,'
        '"fx":1,"fy":1,"cx":1,"cy":1,'
        '"stx":0,"sty":0,"stz":0,"sqx":0,"sqy":0,"sqz":0,"sqw":1}');
    expect(() => loadDepthFrame(dir.path, sample), throwsFormatException);
    dir.deleteSync(recursive: true);
  });

  test('partial artifact (conf declared, file absent) → FormatException', () {
    final (dir, sample) = _fixture(); // writes both
    File('${dir.path}/c_5.dep').deleteSync(); // simulate crash between writes
    expect(() => loadDepthFrame(dir.path, sample), throwsFormatException);
    dir.deleteSync(recursive: true);
  });

  test('depth byte length ≠ dw×dh×2 → FormatException', () {
    final dir = Directory.systemTemp.createTempSync('d1_size_');
    File('${dir.path}/d_5.dep')
        .writeAsBytesSync(Uint8List(6)); // 3 uint16, not 4
    final sample = PoseSample.fromJsonLine(
        '{"t":5,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
        '"state":"TRACKING","depth":"d_5.dep","dw":2,"dh":2,'
        '"fx":1,"fy":1,"cx":1,"cy":1,'
        '"stx":0,"sty":0,"stz":0,"sqx":0,"sqy":0,"sqz":0,"sqw":1}');
    expect(() => loadDepthFrame(dir.path, sample), throwsFormatException);
    dir.deleteSync(recursive: true);
  });

  test('throws StateError when the sample has no depth block', () {
    final sample = PoseSample.fromJsonLine(
        '{"t":1,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,'
        '"state":"TRACKING"}');
    expect(() => loadDepthFrame('/tmp', sample), throwsStateError);
  });
}
