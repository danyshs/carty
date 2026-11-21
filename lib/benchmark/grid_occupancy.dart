// lib/benchmark/grid_occupancy.dart
import '../carty.dart';
import 'occupancy_grid.dart';

/// Projects a fused world grid's log-odds volume into the scorer's binary
/// [OccupancyGrid] (overhead, height integrated out). Exists so the benchmark IoU
/// metric scores the REAL fused grid instead of truth-vs-truth — the input half
/// of the honest end-to-end gate (#7). Reuses [OccupancyGrid.fromLogOdds] so the
/// band-collapse rule lives in exactly one place. The grid's ground axes are
/// world X ([CartyGridOrigin.x]) and world Z ([CartyGridOrigin.y]); height (the
/// band axis) is integrated out by the projection.
OccupancyGrid occupancyFromGrid(CartyWorldGridHandle grid, {int threshold = 0}) {
  return OccupancyGrid.fromLogOdds(
    grid.cells,
    n: grid.n,
    originX: grid.origin.x,
    originY: grid.origin.y,
    resM: grid.resolution.resM,
    threshold: threshold,
  );
}
