// lib/benchmark/corpus.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../vectorize/geojson_scored.dart';
import 'occupancy_grid.dart';
import 'scorer.dart';

/// One scored corpus scene: ground-truth occupancy + room/door graph + the
/// committed per-scene floors. Reads the source-agnostic fixture layout
/// so a dataset adapter can later emit the same files unchanged.
class BenchmarkScene {
  final String name;
  final OccupancyGrid truthOccupancy;
  final ScoredGraph truthMapGraph;
  final double iouFloor, f1Floor;

  /// The REAL vectorized graph for this scene, parsed from the
  /// committed `vectorized.geojson` produced by native `carty_vectorize`. Null
  /// for scenes not yet vectorized → `scoreScene` falls back to truth-vs-truth.
  final ScoredGraph? predictedMapGraph;
  BenchmarkScene({
    required this.name,
    required this.truthOccupancy,
    required this.truthMapGraph,
    required this.iouFloor,
    required this.f1Floor,
    this.predictedMapGraph,
  });
}

Map<String, Object?> _readJson(String path) {
  final f = File(path);
  if (!f.existsSync()) throw FormatException('missing fixture file: $path');
  try {
    return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  } catch (e) {
    throw FormatException('bad JSON in $path: $e');
  }
}

double _num(Map<String, Object?> m, String k) {
  final v = m[k];
  if (v is! num) throw FormatException('field "$k" not a number');
  return v.toDouble();
}

List<({double x, double y})> _poly(Object? raw) {
  if (raw is! List) throw const FormatException('polygon not a list');
  return [
    for (final p in raw)
      if (p is List && p.length == 2)
        (x: (p[0] as num).toDouble(), y: (p[1] as num).toDouble())
      else
        throw const FormatException('bad polygon vertex')
  ];
}

BenchmarkScene loadScene(String dir) {
  final meta = _readJson('$dir/meta.json');
  final occ = _readJson('$dir/truth_occupancy.json');
  final mg = _readJson('$dir/truth_mapgraph.json');
  final exp = _readJson('$dir/expected.json');

  final n = _num(occ, 'n').toInt();
  final rawCells = occ['cells'];
  if (rawCells is! List || rawCells.length != n * n) {
    throw const FormatException('truth_occupancy.cells length != n*n');
  }
  final cells = Uint8List(n * n);
  for (var i = 0; i < cells.length; i++) {
    cells[i] = (rawCells[i] as num) != 0 ? 1 : 0;
  }
  final grid = OccupancyGrid(
    originX: _num(occ, 'origin_x'),
    originY: _num(occ, 'origin_y'),
    resM: _num(occ, 'res_m'),
    n: n,
    cells: cells,
  );

  final rawRooms = mg['rooms'];
  final rawDoors = mg['doors'];
  if (rawRooms is! List || rawDoors is! List) {
    throw const FormatException('truth_mapgraph missing rooms/doors');
  }
  final graph = ScoredGraph(
    rooms: [
      for (final r in rawRooms.cast<Map<String, Object?>>())
        ScoredRoom(id: (r['id'] as num).toInt(), polygon: _poly(r['polygon']))
    ],
    doors: [
      for (final d in rawDoors.cast<Map<String, Object?>>())
        ScoredDoor(
          roomA: (d['roomA'] as num).toInt(),
          roomB: (d['roomB'] as num).toInt(),
          x: _num(d, 'x'),
          y: _num(d, 'y'),
        )
    ],
  );

  // Optional: the REAL vectorized graph. Absent for scenes not yet
  // vectorized → predictedMapGraph stays null and scoreScene falls back to truth.
  ScoredGraph? predicted;
  final vf = File('$dir/vectorized.geojson');
  if (vf.existsSync()) {
    final fc = jsonDecode(vf.readAsStringSync()) as Map<String, Object?>;
    predicted = scoredGraphFromGeoJson(fc);
  }

  return BenchmarkScene(
    name: meta['name'] as String,
    truthOccupancy: grid,
    truthMapGraph: graph,
    iouFloor: _num(exp, 'iou_floor'),
    f1Floor: _num(exp, 'f1_floor'),
    predictedMapGraph: predicted,
  );
}
