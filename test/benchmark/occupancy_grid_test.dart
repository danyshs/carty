// test/benchmark/occupancy_grid_test.dart
import 'dart:typed_data';
import 'package:carty/benchmark.dart';
import 'package:test/test.dart';

void main() {
  test('fromLogOdds collapses bands: a column is occupied if any band > threshold', () {
    // n=2, h=2 → 8 cells, band-major idx=(band*n+gy)*n+gx.
    final logOdds = Int8List.fromList([
      // band 0
      0, 5, // (0,0)=0 (1,0)=5
      0, 0, // (0,1)=0 (1,1)=0
      // band 1
      0, 0, // (0,0)=0 (1,0)=0
      9, 0, // (0,1)=9 (1,1)=0
    ]);
    final g = OccupancyGrid.fromLogOdds(logOdds,
        n: 2, originX: 0, originY: 0, resM: 0.05, threshold: 0);
    expect(g.cells, Uint8List.fromList([0, 1, 1, 0])); // (1,0) and (0,1) occupied
  });

  test('occupiedMetric returns world-metric cell centres', () {
    final g = OccupancyGrid(
        originX: 1.0, originY: 2.0, resM: 0.5, n: 2,
        cells: Uint8List.fromList([0, 1, 0, 0]));
    expect(g.occupiedMetric().single, (x: 1.0 + 1 * 0.5, y: 2.0 + 0 * 0.5));
  });

  test('asserts on a non-square cells length', () {
    expect(
      () => OccupancyGrid(originX: 0, originY: 0, resM: 0.05, n: 2,
          cells: Uint8List.fromList([1, 0, 0])),
      throwsA(isA<AssertionError>()),
    );
  });
}
