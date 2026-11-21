// lib/vectorize/geojson_scored.dart
import '../benchmark/scorer.dart';

/// Parses a vectorized GeoJSON FeatureCollection (METRIC coordinates, as emitted
/// by native `carty_vectorize`) directly into the benchmark scorer's [ScoredGraph]. This
/// deliberately bypasses [MapNode]: MapNode is `[0,1]` frame-normalized, but the
/// F1 ruler compares rooms/doors in absolute metric units (coord-frame
/// decision ratified 2026-06-28). Without this seam the gate would have to either
/// break MapNode's `[0,1]` invariant or normalize-then-rescale — both lossy. Room
/// `Polygon` (properties.type "room") → [ScoredRoom]; door `Point` + 2-id
/// `connections` → [ScoredDoor]. The GeoJSON closing-duplicate vertex is dropped so
/// `ScoredRoom`'s `polygon.length >= 3` holds without a degenerate repeat.
ScoredGraph scoredGraphFromGeoJson(Map<String, Object?> fc) {
  final feats = (fc['features']! as List).cast<Map<String, Object?>>();
  final rooms = <ScoredRoom>[];
  final doors = <ScoredDoor>[];
  for (final f in feats) {
    final geom = f['geometry']! as Map<String, Object?>;
    final props = f['properties']! as Map<String, Object?>;
    final gtype = geom['type'];
    final ptype = props['type'];
    if (gtype == 'Polygon' && ptype == 'room') {
      final ring = (geom['coordinates']! as List).first as List;
      var pts = [
        for (final v in ring.cast<List>())
          (x: (v[0] as num).toDouble(), y: (v[1] as num).toDouble())
      ];
      // Drop the GeoJSON closing-duplicate vertex if present.
      if (pts.length >= 2 && pts.first == pts.last) {
        pts = pts.sublist(0, pts.length - 1);
      }
      rooms.add(ScoredRoom(id: (props['id']! as num).toInt(), polygon: pts));
    } else if (gtype == 'Point' && ptype == 'door') {
      final c = (geom['coordinates']! as List).cast<num>();
      final conn = (props['connections']! as List).cast<num>();
      if (conn.length == 2) {
        doors.add(ScoredDoor(
          roomA: conn[0].toInt(),
          roomB: conn[1].toInt(),
          x: c[0].toDouble(),
          y: c[1].toDouble(),
        ));
      }
    }
  }
  return ScoredGraph(rooms: rooms, doors: doors);
}
