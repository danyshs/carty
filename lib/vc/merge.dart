/// Deterministic three-way merge for [MapGraph]s — the heart of the engine.
///
/// "Three-way" means we never guess from two endpoints alone; we compare each
/// side against their common ancestor (the *base*) so we can tell a real edit
/// from an unchanged value. Resolution runs per node, walking ids in ascending
/// order, so the outcome is a pure function of (base, ours, theirs):
///
///   For each id in base ∪ ours ∪ theirs (sorted):
///     • unchanged on both sides ......... keep base value
///     • changed on exactly one side ..... take that side
///     • changed identically on both ..... take that (agreed) value
///     • changed differently on both ..... CONFLICT (recorded, not guessed)
///   Where "changed" includes add (absent in base) and delete (absent in side).
///
/// Editing *different* nodes can never conflict — each id is decided in
/// isolation — which is exactly the concurrent-branch case the merge test
/// exercises. Same-id divergent edits surface as [MergeConflict]s rather than a
/// silent last-writer-wins, because losing map data silently is worse than
/// asking (no silent degradation).
library;

import 'map_graph.dart';
import 'map_node.dart';

/// One unresolved divergence at a single node id. `null` in any slot means the
/// node is absent on that side (i.e. added or deleted).
class MergeConflict {
  final int nodeId;
  final MapNode? base;
  final MapNode? ours;
  final MapNode? theirs;

  const MergeConflict({
    required this.nodeId,
    required this.base,
    required this.ours,
    required this.theirs,
  });

  @override
  String toString() =>
      'MergeConflict(node #$nodeId: ours=$ours theirs=$theirs base=$base)';
}

class MergeResult {
  /// The merged graph. Always present (conflicting ids are left at the base
  /// value) so callers can inspect a complete graph alongside [conflicts].
  final MapGraph graph;
  final List<MergeConflict> conflicts;

  const MergeResult({required this.graph, required this.conflicts});

  bool get isClean => conflicts.isEmpty;

  @override
  String toString() =>
      'MergeResult(${graph.nodeCount} nodes, ${conflicts.length} conflicts)';
}

/// Pure deterministic three-way merge of [ours] and [theirs] over [base].
MergeResult threeWayMerge({
  required MapGraph base,
  required MapGraph ours,
  required MapGraph theirs,
}) {
  // Union of every id any side knows about, ascending → deterministic order.
  final ids = <int>{...base.nodeIds, ...ours.nodeIds, ...theirs.nodeIds}.toList()
    ..sort();

  var merged = MapGraph.empty();
  final conflicts = <MergeConflict>[];

  for (final id in ids) {
    final b = base.node(id);
    final o = ours.node(id);
    final t = theirs.node(id);

    final ourChange = !_same(b, o);
    final theirChange = !_same(b, t);

    if (!ourChange && !theirChange) {
      // Untouched on both sides — carry the base value through unchanged.
      if (b != null) merged = merged.withNode(b);
    } else if (ourChange && !theirChange) {
      if (o != null) merged = merged.withNode(o); // ours edited; theirs == base
    } else if (!ourChange && theirChange) {
      if (t != null) merged = merged.withNode(t); // theirs edited; ours == base
    } else if (_same(o, t)) {
      // Both moved, but to the same place: convergent edit, no conflict.
      if (o != null) merged = merged.withNode(o);
    } else {
      // Genuine divergence at the same id. Record it; keep base in the graph so
      // the result stays a complete, valid map the caller can resolve over.
      conflicts.add(MergeConflict(nodeId: id, base: b, ours: o, theirs: t));
      if (b != null) merged = merged.withNode(b);
    }
  }

  return MergeResult(graph: merged, conflicts: conflicts);
}

/// Value equality that treats "absent" (null) as a first-class state, so that
/// add/delete are diffed the same way as edits.
bool _same(MapNode? a, MapNode? b) {
  if (a == null || b == null) return a == null && b == null;
  return a == b; // MapNode.== is canonical value equality
}
