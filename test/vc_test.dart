// Tests for the Carty Version-Control Engine (lib/vc.dart).
//
// Pure-Dart, no native bridge: these run on the host VM with no `.so` and no
// network. The headline test simulates two branches
// concurrently editing DIFFERENT nodes and merging — which must resolve with
// zero conflicts and zero errors, deterministically. Supporting tests pin the
// canonical-encoding determinism that content-addressing rests on, prove the
// same-node divergence path reports a conflict (and writes nothing), and prove
// the store is durable across a reopen.

import 'dart:io';

import 'package:carty/vc.dart';
import 'package:flutter_test/flutter_test.dart';

/// The genesis map every test forks from: three distinct features.
MapGraph seedGraph() => MapGraph.fromNodes([
      MapNode(
        id: 0,
        type: 'room',
        description: 'entrance_chamber',
        x: 0.25,
        y: 0.35,
        confidence: 0.85,
      ),
      MapNode(
        id: 1,
        type: 'door',
        description: 'north_gate',
        x: 0.50,
        y: 0.10,
        confidence: 0.70,
      ),
      MapNode(
        id: 2,
        type: 'corridor',
        description: 'long_hall',
        x: 0.50,
        y: 0.50,
        confidence: 0.60,
      ),
    ]);

MapRepository freshRepo() {
  final dir = Directory.systemTemp.createTempSync('carty_vc_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return MapRepository.init(dir.path, defaultBranch: 'main', timestampMillis: 0);
}

void main() {
  group('MapNode.shape — optional polygon/line, omit-when-absent', () {
    test('shapeless node toFeature() is byte-identical to the pre-shape form', () {
      final n = MapNode(id: 1, type: 'landmark', description: 'x', x: 0.2, y: 0.3, confidence: 0.9);
      expect(n.shape, isNull);
      // The exact map the pre-shape implementation produced (Point geometry).
      expect(n.toFeature(), {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [0.2, 0.3]},
        'properties': {'id': 1, 'type': 'landmark', 'description': 'x', 'confidence': 0.9, 'connections': <int>[]},
      });
    });

    test('shaped node round-trips through toFeature/fromFeature', () {
      // Frame-normalized [0,1] ring (MapNode's coordinate contract is unchanged).
      final ring = [(x: 0.1, y: 0.1), (x: 0.4, y: 0.1), (x: 0.4, y: 0.9), (x: 0.1, y: 0.9)];
      final n = MapNode(id: 2, type: 'room', description: '', x: 0.25, y: 0.5, confidence: 1.0, shape: ring);
      final back = MapNode.fromFeature(n.toFeature());
      expect(back.shape, equals(ring));
      expect(back, equals(n)); // canonical value equality survives the round-trip
    });

    test('shape vertex outside [0,1] is rejected (frame-normalized invariant)', () {
      // A vertex must share x/y's [0,1] frame space; out-of-range geometry would
      // corrupt serialization/render, so construction must assert it away.
      final bad = [(x: 0.1, y: 0.1), (x: 1.5, y: 0.1), (x: 0.1, y: 0.9)];
      expect(
        () => MapNode(id: 3, type: 'room', description: '', x: 0.2, y: 0.2, confidence: 1.0, shape: bad),
        throwsA(isA<AssertionError>()),
      );
    });

    test('shape vertex count is bounded by construction (kMaxShapeVertices)', () {
      // Bounded-by-construction: a ring cannot grow without limit,
      // since it flows into canonical bytes + content-hash.
      final tooMany = List.generate(
          kMaxShapeVertices + 1, (i) => (x: (i % 2) * 0.5, y: 0.5));
      expect(
        () => MapNode(id: 4, type: 'room', description: '', x: 0.2, y: 0.2, confidence: 1.0, shape: tooMany),
        throwsA(isA<AssertionError>()),
      );
      // The boundary value itself is accepted.
      final atLimit =
          List.generate(kMaxShapeVertices, (i) => (x: (i % 2) * 0.5, y: 0.5));
      expect(
        () => MapNode(id: 5, type: 'room', description: '', x: 0.2, y: 0.2, confidence: 1.0, shape: atLimit),
        returnsNormally,
      );
    });
  });

  group('canonical encoding is deterministic (content-addressing foundation)', () {
    test('insertion order does not change canonical text or hash', () {
      final a = MapGraph.fromNodes([
        MapNode(id: 2, type: 'corridor', description: 'c', x: .5, y: .5, confidence: .6),
        MapNode(id: 0, type: 'room', description: 'a', x: .1, y: .1, confidence: .9),
        MapNode(id: 1, type: 'door', description: 'b', x: .3, y: .2, confidence: .7),
      ]);
      final b = MapGraph.fromNodes([
        MapNode(id: 0, type: 'room', description: 'a', x: .1, y: .1, confidence: .9),
        MapNode(id: 1, type: 'door', description: 'b', x: .3, y: .2, confidence: .7),
        MapNode(id: 2, type: 'corridor', description: 'c', x: .5, y: .5, confidence: .6),
      ]);
      expect(a.canonical, b.canonical);
      expect(contentHash(a.canonical), contentHash(b.canonical));
    });

    test('a one-field edit changes the hash', () {
      final base = seedGraph();
      final edited = base.withNode(base.node(0)!.copyWith(description: 'grand_entrance'));
      expect(contentHash(edited.canonical), isNot(contentHash(base.canonical)));
    });

    test('content hash is genuine SHA-256 (64-hex, pinned to FIPS 180-4)', () {
      // The store migrated from 64-bit FNV-1a to SHA-256.
      // Pin the width AND a known FIPS 180-4 vector so a future change cannot
      // silently swap the algorithm out from under the content-addressed store.
      // SHA-256("abc") is the canonical NIST test vector.
      expect(contentHash('abc'),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(contentHash('abc').length, 64);
    });

    test('seed graph canonical hash is pinned (migration determinism)', () {
      // Locks the exact SHA-256 of the seed graph's canonical text. If the
      // canonical encoder OR the hash function changes, this trips — the
      // content-addressed object name is part of the on-disk contract.
      expect(contentHash(seedGraph().canonical),
          'afd7fc65f028295c8c9213aeb960a0fffadc5dbc9d532e3e656146441a57cdb6');
    });

    test('FeatureCollection round-trips losslessly', () {
      final g = seedGraph();
      final back = MapGraph.fromFeatureCollection(g.toFeatureCollection());
      expect(back, g);
      expect(back.canonical, g.canonical);
    });
  });

  group('repository: fork / commit / DAG', () {
    test('init creates a genesis commit on the default branch', () {
      final repo = freshRepo();
      expect(repo.currentBranch, 'main');
      expect(repo.readGraphAt(repo.headCommitId).nodeCount, 0);
      expect(repo.readCommit(repo.headCommitId).parents, isEmpty);
    });

    test('commit advances the tip and chains parents', () {
      final repo = freshRepo();
      final genesis = repo.headCommitId;
      final c0 = repo.commit(seedGraph(), message: 'seed', timestampMillis: 1000);
      expect(repo.headCommitId, c0);
      expect(repo.readCommit(c0).parents, [genesis]);
      expect(repo.readGraphAt(c0).nodeCount, 3);
    });

    test('fork points a new branch at the current tip', () {
      final repo = freshRepo();
      final c0 = repo.commit(seedGraph(), message: 'seed', timestampMillis: 1000);
      repo.fork('feature-x');
      expect(repo.branches, containsAll(['main', 'feature-x']));
      expect(repo.tipOf('feature-x'), c0);
    });
  });

  // ===========================================================================
  // PHASE 3 ACCEPTANCE: concurrent modification of DIFFERENT nodes must merge
  // cleanly, deterministically, with zero errors.
  // ===========================================================================
  test('concurrent edits to different nodes merge with zero conflicts', () {
    final repo = freshRepo();

    // Common starting point both branches descend from.
    final base = repo.commit(seedGraph(), message: 'seed map', timestampMillis: 1000);

    // Fork a feature branch off the shared base.
    repo.fork('feature-x', from: base);

    // --- main: edit node 0 only -------------------------------------------
    final mainGraph = repo.readGraphAt(repo.headCommitId);
    final mainEdited =
        mainGraph.withNode(mainGraph.node(0)!.copyWith(description: 'grand_entrance'));
    final mainTip = repo.commit(mainEdited, message: 'rename entrance', timestampMillis: 2000);

    // --- feature-x: edit node 1 only --------------------------------------
    repo.checkout('feature-x');
    final featGraph = repo.readGraphAt(repo.headCommitId);
    final featEdited = featGraph.withNode(
        featGraph.node(1)!.copyWith(type: 'portcullis', x: 0.55, confidence: 0.95));
    final featTip = repo.commit(featEdited, message: 'fortify gate', timestampMillis: 3000);

    // --- merge feature-x into main ----------------------------------------
    repo.checkout('main');
    final outcome = repo.merge('feature-x', timestampMillis: 4000);

    // Zero errors, zero conflicts.
    expect(outcome.isClean, isTrue, reason: outcome.result.conflicts.join('\n'));
    expect(outcome.result.conflicts, isEmpty);
    expect(outcome.mergeCommitId, isNotNull);

    // Merge base resolves to the shared seed commit.
    expect(repo.mergeBase(mainTip, featTip), base);

    // Merged graph = main's node 0 edit + feature-x's node 1 edit + untouched 2.
    final merged = repo.readGraphAt(outcome.mergeCommitId!);
    expect(merged.nodeCount, 3);
    expect(merged.node(0)!.description, 'grand_entrance'); // from main
    expect(merged.node(1)!.type, 'portcullis'); // from feature-x
    expect(merged.node(1)!.confidence, 0.95);
    expect(merged.node(2), seedGraph().node(2)); // untouched

    // It is a real merge commit: two parents, first = ours, second = theirs.
    final mergeCommit = repo.readCommit(outcome.mergeCommitId!);
    expect(mergeCommit.isMerge, isTrue);
    expect(mergeCommit.parents, [mainTip, featTip]);

    // Determinism: re-running the pure merge yields byte-identical content.
    final again = threeWayMerge(
      base: repo.readGraphAt(base),
      ours: repo.readGraphAt(mainTip),
      theirs: repo.readGraphAt(featTip),
    );
    expect(again.graph.canonical, merged.canonical);
    expect(contentHash(again.graph.canonical), contentHash(merged.canonical));

    // Durability: a freshly reopened repo sees the merged history on disk.
    final reopened = MapRepository.open(repo.root.path);
    expect(reopened.readGraphAt(reopened.tipOf('main')).canonical, merged.canonical);
  });

  test('divergent edits to the SAME node report a conflict and write nothing', () {
    final repo = freshRepo();
    final base = repo.commit(seedGraph(), message: 'seed', timestampMillis: 1000);
    repo.fork('feature-y', from: base);

    // main edits node 0 one way...
    final g1 = repo.readGraphAt(repo.headCommitId);
    repo.commit(g1.withNode(g1.node(0)!.copyWith(description: 'east_wing')),
        message: 'east', timestampMillis: 2000);

    // ...feature-y edits the SAME node 0 a different way.
    repo.checkout('feature-y');
    final g2 = repo.readGraphAt(repo.headCommitId);
    repo.commit(g2.withNode(g2.node(0)!.copyWith(description: 'west_wing')),
        message: 'west', timestampMillis: 3000);

    repo.checkout('main');
    final tipBefore = repo.headCommitId;
    final outcome = repo.merge('feature-y', timestampMillis: 4000);

    expect(outcome.isClean, isFalse);
    expect(outcome.mergeCommitId, isNull);
    expect(outcome.result.conflicts.single.nodeId, 0);
    // A conflicted merge must not move the branch.
    expect(repo.headCommitId, tipBefore);
  });

  test('PullRequest applies a clean cross-branch merge', () {
    final repo = freshRepo();
    final base = repo.commit(seedGraph(), message: 'seed', timestampMillis: 1000);
    repo.fork('feature-z', from: base);

    repo.checkout('feature-z');
    final g = repo.readGraphAt(repo.headCommitId);
    repo.commit(
      g.withNode(MapNode(
          id: 3, type: 'landmark', description: 'statue', x: .8, y: .8, confidence: .9)),
      message: 'add statue',
      timestampMillis: 2000,
    );

    final pr = PullRequest(
        title: 'Add statue landmark', sourceBranch: 'feature-z', targetBranch: 'main');
    final outcome = pr.apply(repo, timestampMillis: 3000);

    expect(outcome.isClean, isTrue);
    expect(repo.currentBranch, 'main');
    expect(repo.readGraphAt(repo.headCommitId).contains(3), isTrue);
  });
}
