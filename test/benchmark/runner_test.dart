// test/benchmark/runner_test.dart
import 'dart:typed_data';
import 'package:carty/benchmark.dart';
import 'package:test/test.dart';
import '../../tool/benchmark.dart';

void main() {
  const dir = 'test/fixtures/benchmark/box_two_room';

  test('truth-vs-truth passes its (zero) floor with perfect scores', () {
    final s = loadScene(dir);
    final score = scoreScene(s);
    expect(score.iou, closeTo(1.0, 1e-9));
    expect(score.f1, closeTo(1.0, 1e-9));
    expect(score.passes, isTrue);
  });

  test('a fused grid below the floor fails', () {
    final s = loadScene(dir);
    // Empty fused grid → IoU 0; raise the floor so it must fail.
    final empty = OccupancyGrid(
        originX: 0, originY: 0, resM: 1, n: s.truthOccupancy.n,
        cells: Uint8List(s.truthOccupancy.n * s.truthOccupancy.n));
    final hi = BenchmarkScene(
      name: s.name, truthOccupancy: s.truthOccupancy,
      truthMapGraph: s.truthMapGraph, iouFloor: 0.9, f1Floor: 0.0,
    );
    final score = scoreScene(hi, fused: empty);
    expect(score.passes, isFalse);
  });
}
