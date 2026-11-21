/// [Commit] — one immutable node in the commit DAG.
///
/// A commit binds a *tree* (a [MapGraph] snapshot, referenced by content hash)
/// to its history (`parents`). Zero parents = genesis; one parent = an ordinary
/// edit; two parents = a merge. The commit's own id is the content hash of its
/// canonical text, so the entire DAG is content-addressed and tamper-evident:
/// change any byte of history and every descendant hash changes.
library;

import 'canonical.dart';

class Commit {
  /// Parent commit ids. Order is meaningful: for a merge, `parents[0]` is the
  /// branch we merged *into* (first parent), `parents[1]` the branch merged in.
  final List<String> parents;

  /// Content hash of the [MapGraph] tree this commit points at.
  final String tree;

  final String message;
  final String author;

  /// Unix millis. Part of the identity (two commits with identical trees but
  /// different times are different commits), so callers pass it explicitly —
  /// the engine never reads the wall clock, keeping construction deterministic.
  final int timestampMillis;

  Commit({
    required this.parents,
    required this.tree,
    required this.message,
    required this.author,
    required this.timestampMillis,
  }) {
    assert(parents.length <= 2, 'Carty commits have <= 2 parents, got ${parents.length}');
    assert(tree.length == 64, 'tree must be a 64-hex content hash, got "$tree"');
    assert(message.isNotEmpty, 'commit message must be non-empty');
    assert(timestampMillis >= 0, 'timestamp must be non-negative');
  }

  bool get isMerge => parents.length == 2;

  Map<String, Object?> toJson() => {
        'parents': parents,
        'tree': tree,
        'message': message,
        'author': author,
        'timestamp': timestampMillis,
      };

  factory Commit.fromJson(Map<String, Object?> json) => Commit(
        parents: (json['parents']! as List).cast<String>(),
        tree: json['tree']! as String,
        message: json['message']! as String,
        author: json['author']! as String,
        timestampMillis: (json['timestamp']! as num).toInt(),
      );

  String get canonical => canonicalEncode(toJson());

  /// This commit's id: the hash of its own canonical bytes.
  String get id => contentHash(canonical);

  @override
  String toString() => 'Commit($id "$message" parents=$parents)';
}
