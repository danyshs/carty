/// [MapGraph] — an immutable snapshot of a whole Carty map: the *tree* object
/// of the version-control engine.
///
/// A graph is a set of [MapNode]s keyed by id. Edits ([withNode]/[withoutNode])
/// return a new graph; the original is frozen, so any graph captured by a commit
/// is permanent. Its on-disk form is a **canonical GeoJSON FeatureCollection**
/// (features sorted by id) — identical bytes for identical content, which is
/// what makes it content-addressable and line-diffable.
library;

import 'canonical.dart';
import 'map_node.dart';

class MapGraph {
  /// id -> node. Private + unmodifiable: a graph cannot mutate after birth.
  final Map<int, MapNode> _nodes;

  MapGraph._(this._nodes);

  /// Empty graph — the content of the very first ("genesis") commit.
  factory MapGraph.empty() => MapGraph._(const {});

  factory MapGraph.fromNodes(Iterable<MapNode> nodes) {
    final map = <int, MapNode>{};
    for (final n in nodes) {
      assert(!map.containsKey(n.id), 'duplicate node id ${n.id}');
      map[n.id] = n;
    }
    assert(map.length <= kMaxNodes, 'graph exceeds kMaxNodes');
    return MapGraph._(Map.unmodifiable(map));
  }

  int get nodeCount => _nodes.length;

  /// Node ids in ascending order — the deterministic iteration order every
  /// consumer (serialization, diff, merge) walks.
  List<int> get nodeIds => _nodes.keys.toList()..sort();

  MapNode? node(int id) => _nodes[id];

  bool contains(int id) => _nodes.containsKey(id);

  /// Returns a new graph with [node] added or replaced.
  MapGraph withNode(MapNode node) {
    final next = Map<int, MapNode>.from(_nodes)..[node.id] = node;
    assert(next.length <= kMaxNodes, 'graph exceeds kMaxNodes');
    return MapGraph._(Map.unmodifiable(next));
  }

  /// Returns a new graph with node [id] removed (no-op if absent).
  MapGraph withoutNode(int id) {
    if (!_nodes.containsKey(id)) return this;
    final next = Map<int, MapNode>.from(_nodes)..remove(id);
    return MapGraph._(Map.unmodifiable(next));
  }

  /// Canonical FeatureCollection, features sorted by id.
  Map<String, Object?> toFeatureCollection() => {
        'type': 'FeatureCollection',
        'features': [for (final id in nodeIds) _nodes[id]!.toFeature()],
      };

  factory MapGraph.fromFeatureCollection(Map<String, Object?> fc) {
    assert(fc['type'] == 'FeatureCollection', 'not a FeatureCollection');
    final features = (fc['features']! as List).cast<Map<String, Object?>>();
    return MapGraph.fromNodes(features.map(MapNode.fromFeature));
  }

  /// The exact bytes written to the object store — and hashed to name them.
  String get canonical => canonicalEncode(toFeatureCollection());

  @override
  bool operator ==(Object other) =>
      other is MapGraph && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => 'MapGraph(${_nodes.length} nodes)';
}
