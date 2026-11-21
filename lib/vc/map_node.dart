/// [MapNode] — one versioned spatial feature in a Carty map.
///
/// This is the exact unit the CV pipeline emits (a GeoJSON
/// `Point` feature) and the unit the version-control engine diffs and merges.
/// It is an **immutable value type**: edits produce a new node via [copyWith],
/// never mutate in place, so a node captured in a commit can never change under
/// it. Equality is value equality, which is what lets the merge engine ask the
/// only question that matters — "did this node change?" — by comparing values.
library;

import 'canonical.dart';

/// Hard bounds mirrored from the native side (`CARTY_MAX_NODES`,
/// `connections[16]`). Bounded by construction.
const int kMaxNodes = 1024;
const int kMaxConnections = 16;

/// Upper bound on a node's [MapNode.shape] ring/polyline vertex count. A shape
/// flows into the canonical bytes + content-hash, so it must be bounded by
/// construction like every other field — an unbounded ring would
/// let one node's geometry grow without limit. Dart-side bound only; there is no
/// native `shape` array yet to mirror (none exists).
const int kMaxShapeVertices = 256;

class MapNode {
  /// Stable identity, `0 <= id < kMaxNodes`. The node's key in a [MapGraph] and
  /// the granularity at which merges resolve.
  final int id;

  /// Semantic tag: room, door, corridor, landmark, wall, ...
  final String type;

  /// Human-readable label.
  final String description;

  /// Frame-normalized position, each in `[0, 1]`.
  final double x;
  final double y;

  /// Detection confidence in `[0, 1]`.
  final double confidence;

  /// Ids of connected nodes, ascending & deduplicated, length `<= kMaxConnections`.
  final List<int> connections;

  /// Optional geometry carrier: a closed polygon ring (rooms) or open polyline
  /// (walls/corridors), each vertex in the same `[0,1]` frame-normalized space
  /// as `x`/`y`. Omit-when-absent: when null, `toFeature()` emits a plain
  /// `Point` byte-identically to the pre-shape form — so shapeless nodes do NOT
  /// change their canonical bytes or content-hash (the on-disk migration
  /// invariant). Never serialize `null` as a key.
  final List<({double x, double y})>? shape;

  MapNode({
    required this.id,
    required this.type,
    required this.description,
    required this.x,
    required this.y,
    required this.confidence,
    List<int> connections = const [],
    this.shape,
  }) : connections = _normalizeConnections(connections) {
    // Preconditions are invariants, kept in all builds.
    assert(id >= 0 && id < kMaxNodes, 'id out of range: $id');
    assert(type.isNotEmpty, 'type must be non-empty');
    assert(x >= 0.0 && x <= 1.0, 'x out of [0,1]: $x');
    assert(y >= 0.0 && y <= 1.0, 'y out of [0,1]: $y');
    assert(confidence >= 0.0 && confidence <= 1.0, 'confidence out of [0,1]: $confidence');
    assert(this.connections.length <= kMaxConnections, 'too many connections');
    assert(shape == null || shape!.length >= 3, 'shape ring/polyline must have >= 3 vertices');
    assert(shape == null || shape!.length <= kMaxShapeVertices,
        'shape has ${shape?.length} vertices > kMaxShapeVertices ($kMaxShapeVertices)');
    // shape vertices share x/y's frame-normalized [0,1] space (see field doc) —
    // assert it here so out-of-bounds geometry can't corrupt serialization/render.
    assert(() {
      for (final p in shape ?? const <({double x, double y})>[]) {
        assert(p.x >= 0.0 && p.x <= 1.0, 'shape vertex x out of [0,1]: ${p.x}');
        assert(p.y >= 0.0 && p.y <= 1.0, 'shape vertex y out of [0,1]: ${p.y}');
      }
      return true;
    }());
  }

  static List<int> _normalizeConnections(List<int> raw) {
    final set = <int>{};
    for (final c in raw) {
      assert(c >= 0 && c < kMaxNodes, 'connection id out of range: $c');
      set.add(c);
    }
    final list = set.toList()..sort();
    return List.unmodifiable(list);
  }

  MapNode copyWith({
    String? type,
    String? description,
    double? x,
    double? y,
    double? confidence,
    List<int>? connections,
    List<({double x, double y})>? shape,
  }) {
    return MapNode(
      id: id,
      type: type ?? this.type,
      description: description ?? this.description,
      x: x ?? this.x,
      y: y ?? this.y,
      confidence: confidence ?? this.confidence,
      connections: connections ?? this.connections,
      shape: shape ?? this.shape,
    );
  }

  /// GeoJSON `Feature` form. The plain `Map` is fed to
  /// [canonicalEncode]; ordering is irrelevant here because the encoder sorts.
  ///
  /// When [shape] is null the output is byte-identical to the pre-shape Point
  /// form — the omit-when-absent invariant that keeps shapeless nodes' canonical
  /// hashes stable across migrations. When [shape] is present, emits a Polygon
  /// geometry and moves the `x`/`y` centroid into properties.
  Map<String, Object?> toFeature() {
    if (shape == null) {
      return {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [x, y],
        },
        'properties': {
          'id': id,
          'type': type,
          'description': description,
          'confidence': confidence,
          'connections': connections,
        },
      };
    }
    return {
      'type': 'Feature',
      'geometry': {
        'type': 'Polygon',
        'coordinates': [
          [for (final p in shape!) [p.x, p.y]],
        ],
      },
      'properties': {
        'id': id,
        'type': type,
        'description': description,
        'x': x,
        'y': y,
        'confidence': confidence,
        'connections': connections,
      },
    };
  }

  /// Parses a GeoJSON `Feature` produced by [toFeature] (round-trip exact).
  /// Reads `geometry.type` to dispatch: `Point` → shapeless; `Polygon` → with shape.
  factory MapNode.fromFeature(Map<String, Object?> feature) {
    assert(feature['type'] == 'Feature', 'not a Feature');
    final geometry = feature['geometry']! as Map<String, Object?>;
    final props = feature['properties']! as Map<String, Object?>;
    final geomType = geometry['type']! as String;

    if (geomType == 'Point') {
      final coords = (geometry['coordinates']! as List).cast<num>();
      return MapNode(
        id: (props['id']! as num).toInt(),
        type: props['type']! as String,
        description: props['description']! as String,
        x: coords[0].toDouble(),
        y: coords[1].toDouble(),
        confidence: (props['confidence']! as num).toDouble(),
        connections: (props['connections'] as List? ?? const [])
            .cast<num>()
            .map((n) => n.toInt())
            .toList(),
      );
    }

    assert(geomType == 'Polygon', 'unsupported geometry type: $geomType');
    // Polygon ring is coordinates[0] — a list of [x, y] pairs.
    final ring = ((geometry['coordinates']! as List)[0] as List)
        .cast<List<dynamic>>()
        .map((pair) => (x: (pair[0] as num).toDouble(), y: (pair[1] as num).toDouble()))
        .toList();
    return MapNode(
      id: (props['id']! as num).toInt(),
      type: props['type']! as String,
      description: props['description']! as String,
      x: (props['x']! as num).toDouble(),
      y: (props['y']! as num).toDouble(),
      confidence: (props['confidence']! as num).toDouble(),
      connections: (props['connections'] as List? ?? const [])
          .cast<num>()
          .map((n) => n.toInt())
          .toList(),
      shape: ring,
    );
  }

  /// Canonical text of just this node — the value-equality fingerprint the
  /// merge engine compares.
  String get canonical => canonicalEncode(toFeature());

  @override
  bool operator ==(Object other) =>
      other is MapNode && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => 'MapNode(#$id $type "$description")';
}
