// lib/benchmark/scorer.dart
import 'dart:math';
import 'occupancy_grid.dart';
import 'align.dart';

/// Scale/pose-tolerant overhead occupancy IoU (benchmark metric). The fused map only
/// has to LOOK right from overhead, so fused occupancy is similarity-aligned
/// onto truth's lattice before the rasterized intersection-over-union — a global
/// translate/rotate/uniform-scale is not penalized, a reflection is (align.dart).
double occupancyIou(OccupancyGrid fused, OccupancyGrid truth) {
  final fusedPts = fused.occupiedMetric().toList();
  final truthPts = truth.occupiedMetric().toList();
  if (fusedPts.isEmpty && truthPts.isEmpty) return 1.0;
  if (fusedPts.isEmpty || truthPts.isEmpty) return 0.0;

  final aligned = SimilarityAlign.alignToTruth(fusedPts, truthPts);

  // Rasterize aligned fused points onto truth's cell lattice.
  final fusedSet = <int>{};
  for (final p in aligned) {
    final gx = ((p.x - truth.originX) / truth.resM).round();
    final gy = ((p.y - truth.originY) / truth.resM).round();
    if (gx < 0 || gx >= truth.n || gy < 0 || gy >= truth.n) continue;
    fusedSet.add(gy * truth.n + gx);
  }
  final truthSet = <int>{};
  for (var i = 0; i < truth.cells.length; i++) {
    if (truth.cells[i] == 1) truthSet.add(i);
  }
  if (fusedSet.isEmpty && truthSet.isEmpty) return 1.0;

  var inter = 0;
  for (final i in fusedSet) {
    if (truthSet.contains(i)) inter++;
  }
  final union = fusedSet.length + truthSet.length - inter;
  return union == 0 ? 1.0 : inter / union;
}

/// A room as a closed polygon (CCW or CW; even-odd test is orientation-agnostic).
class ScoredRoom {
  final int id;
  final List<({double x, double y})> polygon;
  ScoredRoom({required this.id, required this.polygon})
      : assert(polygon.length >= 3, 'a room polygon needs >= 3 vertices');
}

/// A door = a connection between two rooms at a position. Matching is topological
/// (the room pair) plus a bounded position gate — naturally scale-invariant.
class ScoredDoor {
  final int roomA, roomB;
  final double x, y;
  ScoredDoor({required this.roomA, required this.roomB, required this.x, required this.y})
      : assert(roomA != roomB, 'a door joins two distinct rooms');
}

class ScoredGraph {
  final List<ScoredRoom> rooms;
  final List<ScoredDoor> doors;
  ScoredGraph({required this.rooms, required this.doors});
}

class F1Result {
  final double precision, recall, f1;
  final int matched, predicted, truth;
  F1Result(
      {required this.precision,
      required this.recall,
      required this.f1,
      required this.matched,
      required this.predicted,
      required this.truth});
}

bool _pointInPoly(double px, double py, List<({double x, double y})> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final xi = poly[i].x, yi = poly[i].y, xj = poly[j].x, yj = poly[j].y;
    final hit = ((yi > py) != (yj > py)) &&
        (px < (xj - xi) * (py - yi) / (yj - yi) + xi);
    if (hit) inside = !inside;
  }
  return inside;
}

/// Cell-IoU of two polygons on a shared lattice — bounded + deterministic, no
/// geometry dependency. The lattice spans the union AABB at [_iouCells]-per-unit
/// resolution: a unit step exactly scores integer-aligned axis-aligned rectangles
/// (the only kind today's bbox vectorizer emits) but rounds sub-unit offsets to a
/// false 0/1 IoU; sampling at 0.1-unit cells keeps sub-unit translations and the
/// future non-rectilinear rooms (marching-squares, a future carty_vectorize pass)
/// stable. Bounded: cell count is (AABB span × [_iouCells])², span itself bounded
/// by the normalized/metric room extents.
double _polyOverlapIou(
    List<({double x, double y})> a, List<({double x, double y})> b) {
  double lo(double Function(({double x, double y})) f, List<({double x, double y})> p) =>
      p.map(f).reduce(min);
  double hi(double Function(({double x, double y})) f, List<({double x, double y})> p) =>
      p.map(f).reduce(max);
  final minX = (min(lo((q) => q.x, a), lo((q) => q.x, b)) * _iouCells).floor();
  final minY = (min(lo((q) => q.y, a), lo((q) => q.y, b)) * _iouCells).floor();
  final maxX = (max(hi((q) => q.x, a), hi((q) => q.x, b)) * _iouCells).ceil();
  final maxY = (max(hi((q) => q.y, a), hi((q) => q.y, b)) * _iouCells).ceil();
  var inter = 0, union = 0;
  for (var y = minY; y < maxY; y++) {
    for (var x = minX; x < maxX; x++) {
      final cx = (x + 0.5) / _iouCells, cy = (y + 0.5) / _iouCells;
      final inA = _pointInPoly(cx, cy, a);
      final inB = _pointInPoly(cx, cy, b);
      if (inA && inB) inter++;
      if (inA || inB) union++;
    }
  }
  return union == 0 ? 0.0 : inter / union;
}

/// Rasterization cells per coordinate unit for [_polyOverlapIou]. 10 → 0.1-unit
/// (10 cm at 1 m/unit) sampling: fine enough to resolve sub-unit room offsets,
/// coarse enough to stay bounded.
const double _iouCells = 10.0;

/// Combined room+door F1 (benchmark metric). Rooms match by polygon-overlap IoU ≥
/// [roomOverlapMin]; doors by identical room-pair AND centroid within
/// [doorPosTol]. Greedy one-to-one matching (each truth item matched once).
F1Result roomDoorF1(ScoredGraph predicted, ScoredGraph truth,
    {double roomOverlapMin = 0.5, double doorPosTol = 3.0}) {
  var matched = 0;

  // Rooms: greedy best-overlap match.
  final usedTruthRoom = <int>{};
  // map predicted room id -> matched truth room id (for door pair remap).
  final predToTruthRoom = <int, int>{};
  for (final pr in predicted.rooms) {
    var bestIdx = -1;
    var bestIou = roomOverlapMin;
    for (var ti = 0; ti < truth.rooms.length; ti++) {
      if (usedTruthRoom.contains(ti)) continue;
      final iou = _polyOverlapIou(pr.polygon, truth.rooms[ti].polygon);
      if (iou >= bestIou) {
        bestIou = iou;
        bestIdx = ti;
      }
    }
    if (bestIdx >= 0) {
      usedTruthRoom.add(bestIdx);
      predToTruthRoom[pr.id] = truth.rooms[bestIdx].id;
      matched++;
    }
  }

  // Doors: a predicted door matches a truth door if its (remapped) room pair
  // equals the truth pair AND position is within tolerance.
  final usedTruthDoor = <int>{};
  for (final pd in predicted.doors) {
    final a = predToTruthRoom[pd.roomA];
    final b = predToTruthRoom[pd.roomB];
    if (a == null || b == null) continue; // its rooms were not matched
    final pair = {a, b};
    for (var ti = 0; ti < truth.doors.length; ti++) {
      if (usedTruthDoor.contains(ti)) continue;
      final td = truth.doors[ti];
      if ({td.roomA, td.roomB}.difference(pair).isEmpty &&
          sqrt(pow(pd.x - td.x, 2) + pow(pd.y - td.y, 2)) <= doorPosTol) {
        usedTruthDoor.add(ti);
        matched++;
        break;
      }
    }
  }

  final predicted0 = predicted.rooms.length + predicted.doors.length;
  final truth0 = truth.rooms.length + truth.doors.length;
  final precision = predicted0 == 0 ? 1.0 : matched / predicted0;
  final recall = truth0 == 0 ? 1.0 : matched / truth0;
  final f1 = (precision + recall) == 0 ? 0.0 : 2 * precision * recall / (precision + recall);
  return F1Result(
      precision: precision,
      recall: recall,
      f1: f1,
      matched: matched,
      predicted: predicted0,
      truth: truth0);
}
