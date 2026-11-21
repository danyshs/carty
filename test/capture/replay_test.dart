import 'package:carty/capture.dart';
import 'package:test/test.dart';

const _good1 = '{"t":1,"tx":0,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,"state":"TRACKING"}';
const _good2 = '{"t":2,"tx":1,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,"state":"TRACKING"}';
const _paused = '{"t":3,"tx":2,"ty":0,"tz":0,"qx":0,"qy":0,"qz":0,"qw":1,"state":"PAUSED"}';

void main() {
  test('parses all lines in file order', () {
    final h = ReplayHarness.fromLines([_good1, _good2, _paused]);
    expect(h.samples.map((s) => s.t), [1, 2, 3]);
    expect(h.malformedCount, 0);
  });

  test('trackingOnly excludes PAUSED samples', () {
    final h = ReplayHarness.fromLines([_good1, _paused, _good2]);
    expect(h.trackingOnly.map((s) => s.t), [1, 2]);
  });

  test('ignores blank lines but throws on a malformed line by default', () {
    expect(
      () => ReplayHarness.fromLines([_good1, '', 'garbage']),
      throwsFormatException,
    );
  });

  test('skipMalformed drops bad lines and counts them', () {
    final h = ReplayHarness.fromLines(
      [_good1, 'garbage', '{"t":2,', _good2],
      skipMalformed: true,
    );
    expect(h.samples.map((s) => s.t), [1, 2]);
    expect(h.malformedCount, 2);
  });
}
