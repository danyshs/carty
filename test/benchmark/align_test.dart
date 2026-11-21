// test/benchmark/align_test.dart
import 'dart:math';
import 'package:carty/benchmark.dart';
import 'package:test/test.dart';

List<({double x, double y})> _lShape() => const [
      (x: 0, y: 0), (x: 1, y: 0), (x: 2, y: 0), (x: 0, y: 1), (x: 0, y: 2),
    ];

List<({double x, double y})> _transform(
    List<({double x, double y})> p, double tx, double ty, double s, double deg) {
  final r = deg * pi / 180.0;
  return [
    for (final q in p)
      (
        x: tx + s * (q.x * cos(r) - q.y * sin(r)),
        y: ty + s * (q.x * sin(r) + q.y * cos(r)),
      )
  ];
}

double _maxDist(List<({double x, double y})> a, List<({double x, double y})> b) {
  var m = 0.0;
  for (var i = 0; i < a.length; i++) {
    m = max(m, sqrt(pow(a[i].x - b[i].x, 2) + pow(a[i].y - b[i].y, 2)));
  }
  return m;
}

void main() {
  test('aligns a translated+rotated+scaled copy back onto truth', () {
    final truth = _lShape();
    final moved = _transform(truth, 10, -4, 2.5, 35);
    final out = SimilarityAlign.alignToTruth(moved, truth);
    expect(_maxDist(out, truth), lessThan(1e-6));
  });

  test('does NOT correct a reflection (mirrored stays far from truth)', () {
    final truth = _lShape();
    final mirrored = [for (final q in truth) (x: -q.x, y: q.y)];
    final out = SimilarityAlign.alignToTruth(mirrored, truth);
    expect(_maxDist(out, truth), greaterThan(0.5));
  });

  test('principalAngle of a horizontal line is ~0', () {
    final a = SimilarityAlign.principalAngle(
        const [(x: -2, y: 0), (x: -1, y: 0), (x: 1, y: 0), (x: 2, y: 0)]);
    expect(a.abs(), lessThan(1e-9));
  });
}
