// lib/benchmark/occupancy_grid.dart
import 'dart:typed_data';

/// A 2D binary overhead occupancy grid — the common shape both *fused* output
/// (collapsed from the log-odds volume) and *truth* are scored in. Square by
/// construction (`cells.length == n*n`), row-major `idx = gy*n + gx`.
class OccupancyGrid {
  final double originX;
  final double originY;
  final double resM;
  final int n;
  final Uint8List cells;

  OccupancyGrid({
    required this.originX,
    required this.originY,
    required this.resM,
    required this.n,
    required this.cells,
  }) {
    assert(resM.isFinite && resM > 0, 'resM must be finite > 0: $resM');
    assert(n > 0 && n <= 2048, 'n out of bounds: $n');
    assert(cells.length == n * n, 'cells.length ${cells.length} != n*n ${n * n}');
  }

  /// Collapse a band-major log-odds volume (`idx=(band*n+gy)*n+gx`) to a binary
  /// ground map: a column is occupied iff ANY band exceeds [threshold]. This is
  /// the overhead projection the IoU metric compares — height is integrated out.
  factory OccupancyGrid.fromLogOdds(
    Int8List logOdds, {
    required int n,
    required double originX,
    required double originY,
    required double resM,
    int threshold = 0,
  }) {
    assert(n > 0 && n <= 2048, 'n out of bounds: $n');
    assert(logOdds.length % (n * n) == 0, 'volume not a multiple of n*n');
    final h = logOdds.length ~/ (n * n);
    final cells = Uint8List(n * n);
    for (var band = 0; band < h; band++) {
      for (var i = 0; i < n * n; i++) {
        if (logOdds[(band * n * n) + i] > threshold) cells[i] = 1;
      }
    }
    return OccupancyGrid(
        originX: originX, originY: originY, resM: resM, n: n, cells: cells);
  }

  /// World-metric centre of each occupied cell — the point set the aligner and
  /// IoU operate on so a globally shifted/rotated/scaled map is not penalized.
  Iterable<({double x, double y})> occupiedMetric() sync* {
    for (var gy = 0; gy < n; gy++) {
      for (var gx = 0; gx < n; gx++) {
        if (cells[gy * n + gx] == 1) {
          yield (x: originX + gx * resM, y: originY + gy * resM);
        }
      }
    }
  }
}
