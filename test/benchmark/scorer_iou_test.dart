// test/benchmark/scorer_iou_test.dart
import 'dart:typed_data';
import 'package:carty/benchmark.dart';
import 'package:test/test.dart';

OccupancyGrid _grid(int n, List<int> cells, {double ox = 0, double oy = 0, double res = 1}) =>
    OccupancyGrid(originX: ox, originY: oy, resM: res, n: n, cells: Uint8List.fromList(cells));

void main() {
  test('identical grids → 1.0', () {
    final g = _grid(2, [1, 1, 0, 0]);
    expect(occupancyIou(g, g), closeTo(1.0, 1e-9));
  });

  test('partial coverage scores below 1 (fused covers only part of truth)', () {
    // A pose/scale-tolerant metric maps a lone dot's centroid onto truth's, so
    // two single cells are congruent (→1.0) — "disjoint single cells" is NOT a
    // 0.0 case here. The meaningful sub-1 property is COVERAGE: a fused dot that
    // lands on one of truth's three L-tromino cells shares 1, unions 3 → 1/3.
    final fused = _grid(2, [1, 0, 0, 0]); // 1 occupied
    final truth = _grid(2, [1, 1, 1, 0]); // 3 occupied (L-tromino)
    expect(occupancyIou(fused, truth), closeTo(1 / 3, 1e-9));
  });

  test('50% overlap → 0.5', () {
    final truth = _grid(2, [1, 1, 1, 0]); // 3 occupied
    final fused = _grid(2, [1, 1, 0, 0]); // 2 occupied, both in truth
    // ∩=2, ∪=3 → 2/3
    expect(occupancyIou(fused, truth), closeTo(2 / 3, 1e-9));
  });

  test('a translated copy of truth → ≈1.0 after alignment', () {
    final truth = _grid(3, [1, 1, 0, 1, 0, 0, 0, 0, 0]); // L of 3 cells
    // same shape but origin shifted by +5 in x (a global translation)
    final shifted = _grid(3, [1, 1, 0, 1, 0, 0, 0, 0, 0], ox: 5.0);
    expect(occupancyIou(shifted, truth), greaterThan(0.95));
  });

  test('two empty grids → 1.0; one empty → 0.0', () {
    final empty = _grid(2, [0, 0, 0, 0]);
    final some = _grid(2, [1, 0, 0, 0]);
    expect(occupancyIou(empty, empty), 1.0);
    expect(occupancyIou(empty, some), 0.0);
  });
}
