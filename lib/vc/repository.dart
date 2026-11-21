/// [MapRepository] — the on-disk, Git-shaped store for map versions.
///
/// Local-first by construction: everything is plain text under a
/// single directory, so a repo is `adb pull`-able, diffable, and survives with
/// no server. The layout mirrors Git deliberately, because the model is proven:
///
/// ```text
/// <root>/
///   objects/<hash>.json   content-addressed trees & commits (immutable)
///   refs/heads/<branch>   one line: the commit id at that branch tip
///   HEAD                  one line: the name of the checked-out branch
/// ```
///
/// Objects are immutable and content-named, so writes are idempotent and
/// history is tamper-evident. Only refs and HEAD ever change in place — they are
/// the single source of "where we are now". All persistence is synchronous:
/// these are tiny files and the engine must be usable from simple test and CLI
/// flows without an event loop.
library;

import 'dart:convert';
import 'dart:io';

import 'canonical.dart';
import 'commit.dart';
import 'map_graph.dart';
import 'merge.dart';

/// Outcome of [MapRepository.merge]: the merge commit id when clean, or the
/// conflict list when not. A conflicted merge writes nothing — the working
/// branch is left exactly where it was, so a failed merge is never half-applied.
class MergeOutcome {
  /// Non-null iff the merge was clean and committed.
  final String? mergeCommitId;
  final MergeResult result;

  const MergeOutcome({required this.mergeCommitId, required this.result});

  bool get isClean => result.isClean;
}

class MapRepository {
  /// Root directory holding `objects/`, `refs/`, and `HEAD`.
  final Directory root;

  MapRepository._(this.root);

  Directory get _objects => Directory('${root.path}/objects');
  Directory get _heads => Directory('${root.path}/refs/heads');
  File get _head => File('${root.path}/HEAD');

  /// Creates a fresh repository at [path] with an empty genesis commit on
  /// `defaultBranch`, and checks that branch out. [timestampMillis] is supplied
  /// (not read from a clock) so repo creation is reproducible in tests.
  static MapRepository init(
    String path, {
    String defaultBranch = 'main',
    String author = 'carty',
    int timestampMillis = 0,
  }) {
    final repo = MapRepository._(Directory(path));
    assert(!repo._objects.existsSync(), 'repository already initialised at $path');
    repo._objects.createSync(recursive: true);
    repo._heads.createSync(recursive: true);

    final treeHash = repo._writeTree(MapGraph.empty());
    final genesis = Commit(
      parents: const [],
      tree: treeHash,
      message: 'genesis',
      author: author,
      timestampMillis: timestampMillis,
    );
    final genesisId = repo._writeCommit(genesis);
    repo._writeRef(defaultBranch, genesisId);
    repo._head.writeAsStringSync(defaultBranch);
    return repo;
  }

  /// Opens an existing repository (used to prove on-disk durability).
  static MapRepository open(String path) {
    final repo = MapRepository._(Directory(path));
    assert(repo._objects.existsSync(), 'no repository at $path');
    assert(repo._head.existsSync(), 'repository has no HEAD at $path');
    return repo;
  }

  // ---- refs / HEAD -------------------------------------------------------

  /// Name of the currently checked-out branch.
  String get currentBranch {
    final name = _head.readAsStringSync().trim();
    assert(name.isNotEmpty, 'HEAD is empty');
    return name;
  }

  List<String> get branches =>
      (_heads.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList())
        ..sort();

  /// Commit id at the tip of [branch].
  String tipOf(String branch) {
    final ref = File('${_heads.path}/$branch');
    assert(ref.existsSync(), 'no such branch: $branch');
    return ref.readAsStringSync().trim();
  }

  String get headCommitId => tipOf(currentBranch);

  void _writeRef(String branch, String commitId) {
    assert(commitId.length == 64, 'commit id must be a 64-hex hash');
    File('${_heads.path}/$branch').writeAsStringSync(commitId);
  }

  /// Points [name] at [from] (defaults to the current tip) — i.e. **fork**.
  void fork(String name, {String? from}) {
    assert(!File('${_heads.path}/$name').existsSync(), 'branch exists: $name');
    _writeRef(name, from ?? headCommitId);
  }

  /// Moves HEAD to an existing branch.
  void checkout(String branch) {
    assert(File('${_heads.path}/$branch').existsSync(), 'no such branch: $branch');
    _head.writeAsStringSync(branch);
  }

  // ---- objects -----------------------------------------------------------

  // A tree is named by the hash of its graph's canonical content (matching
  // MapGraph.canonical), so Commit.tree and the on-disk file name always agree.
  String _writeTree(MapGraph graph) {
    final name = contentHash(graph.canonical);
    _writeObject(name, 'tree', graph.canonical);
    return name;
  }

  // A commit is named by Commit.id (the hash of its own canonical bytes).
  String _writeCommit(Commit commit) {
    _writeObject(commit.id, 'commit', commit.canonical);
    return commit.id;
  }

  /// Writes a `kind`-tagged, content-addressed object under [name]. Idempotent:
  /// because [name] is a hash of the content, re-writes replace identical bytes.
  void _writeObject(String name, String kind, String canonical) {
    File('${_objects.path}/$name.json').writeAsStringSync(_wrap(kind, canonical));
  }

  /// Tags canonical content with its `kind` and re-canonicalizes the whole file,
  /// so the stored object is itself deterministic and line-diffable.
  String _wrap(String kind, String canonical) =>
      canonicalEncode({'kind': kind, 'content': jsonDecode(canonical)});

  MapGraph readTree(String hash) {
    final json = _readObject(hash, expectKind: 'tree');
    return MapGraph.fromFeatureCollection(json);
  }

  Commit readCommit(String id) {
    final json = _readObject(id, expectKind: 'commit');
    return Commit.fromJson(json);
  }

  /// Reads the [MapGraph] a commit points at — the working content at that
  /// point in history.
  MapGraph readGraphAt(String commitId) => readTree(readCommit(commitId).tree);

  Map<String, Object?> _readObject(String name, {required String expectKind}) {
    final file = File('${_objects.path}/$name.json');
    assert(file.existsSync(), 'missing object: $name');
    final wrapped = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    assert(wrapped['kind'] == expectKind,
        'object $name is ${wrapped['kind']}, expected $expectKind');
    return wrapped['content']! as Map<String, Object?>;
  }

  // ---- commit ------------------------------------------------------------

  /// Snapshots [graph] as a new commit on the current branch, advancing its tip.
  /// [parentsOverride] lets the merge path record two parents.
  String commit(
    MapGraph graph, {
    required String message,
    String author = 'carty',
    required int timestampMillis,
    List<String>? parentsOverride,
  }) {
    final treeHash = _writeTree(graph);
    final commit = Commit(
      parents: parentsOverride ?? [headCommitId],
      tree: treeHash,
      message: message,
      author: author,
      timestampMillis: timestampMillis,
    );
    final id = _writeCommit(commit);
    _writeRef(currentBranch, id);
    return id;
  }

  // ---- DAG walk / merge --------------------------------------------------

  /// All ancestors of [commitId] (inclusive), by breadth-first walk of parents.
  Set<String> _ancestors(String commitId) {
    final seen = <String>{};
    final queue = <String>[commitId];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      if (!seen.add(id)) continue;
      queue.addAll(readCommit(id).parents);
    }
    return seen;
  }

  /// Lowest common ancestor of two commits — the three-way merge base.
  ///
  /// We collect all ancestors of [a], then BFS from [b] returning the first
  /// commit also in a's ancestor set. BFS order makes "first hit" the *nearest*
  /// shared commit, and the walk is deterministic, so the base is well-defined.
  String mergeBase(String a, String b) {
    final ancestorsOfA = _ancestors(a);
    final queue = <String>[b];
    final seen = <String>{};
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      if (!seen.add(id)) continue;
      if (ancestorsOfA.contains(id)) return id;
      queue.addAll(readCommit(id).parents);
    }
    throw StateError('no common ancestor between $a and $b');
  }

  /// Merges [sourceBranch] into the current branch.
  ///
  /// Clean → writes a two-parent merge commit `[ourTip, theirTip]` and advances
  /// the current branch. Conflicted → writes nothing and returns the conflicts;
  /// the caller resolves and retries. Either way the repo is left consistent.
  MergeOutcome merge(
    String sourceBranch, {
    String author = 'carty',
    required int timestampMillis,
    String? message,
  }) {
    final ourTip = headCommitId;
    final theirTip = tipOf(sourceBranch);
    final baseId = mergeBase(ourTip, theirTip);

    final result = threeWayMerge(
      base: readGraphAt(baseId),
      ours: readGraphAt(ourTip),
      theirs: readGraphAt(theirTip),
    );

    if (!result.isClean) {
      return MergeOutcome(mergeCommitId: null, result: result);
    }

    final id = commit(
      result.graph,
      message: message ?? "merge '$sourceBranch' into '$currentBranch'",
      author: author,
      timestampMillis: timestampMillis,
      parentsOverride: [ourTip, theirTip],
    );
    return MergeOutcome(mergeCommitId: id, result: result);
  }
}
