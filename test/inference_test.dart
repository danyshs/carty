// on-device inference orchestration tests.
//
// Covers the deterministic scaffold around Gemma 4 E2B WITHOUT loading weights:
//   - prompt layout: deterministic render, bounded by construction;
//   - the strict parser: happy path -> correct VC-schema mutations;
//   - SAFE FAILURE: malformed model output never mutates the map;
//   - tolerant extraction: prose / ```json fences around the object;
//   - the native bridge: structural JSON gate + multimodal block safe-fail,
//     exercised over the SAME FFI surface the APK ships (native/build .so);
//   - end-to-end: a mock multimodal block committed into a VC repository.
import 'dart:ffi';
import 'dart:io';

import 'package:carty/carty.dart';
import 'package:carty/carty_bindings_generated.dart'
    show CARTY_MAP_UPDATE_MAX, CARTY_INFER_ENOMODEL;
import 'package:carty/inference.dart';
import 'package:carty/vc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MultimodalPrompt (context-managed, deterministic)', () {
    MultimodalPrompt make() => MultimodalPrompt(
          instruction: 'Label rooms and the doors connecting them.',
          bounds: SpatialBounds(0.0, 0.0, 0.5, 0.5),
          imageWidth: 224,
          imageHeight: 224,
          imageChannels: 3,
        );

    test('render is deterministic for identical inputs', () {
      expect(make().render(), equals(make().render()));
    });

    test('render carries contract, image descriptor, bounds, instruction', () {
      final text = make().render();
      expect(text, contains('"ops"')); // schema contract present
      expect(text, contains('224x224x3'));
      expect(text, contains('region: [0.0, 0.0] -> [0.5, 0.5]'));
      expect(text, contains('Label rooms'));
    });

    test('output budget is bounded to the native ceiling by default', () {
      expect(make().maxOutputBytes, equals(MultimodalPrompt.kDefaultMaxOutputBytes));
      expect(make().maxOutputBytes, lessThanOrEqualTo(CARTY_MAP_UPDATE_MAX));
    });

    test('over-long instruction is rejected (context budget)', () {
      expect(
        () => MultimodalPrompt(
          instruction: 'x' * (MultimodalPrompt.kMaxInstructionChars + 1),
          imageWidth: 8,
          imageHeight: 8,
          imageChannels: 3,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('disordered spatial bounds are rejected', () {
      expect(() => SpatialBounds(0.6, 0.0, 0.5, 1.0),
          throwsA(isA<AssertionError>()));
      expect(() => SpatialBounds(0.0, 0.0, 1.5, 1.0),
          throwsA(isA<AssertionError>()));
    });
  });

  group('MapUpdate.parse — strict schema, happy path', () {
    test('add/update/connect/remove produce the expected graph', () {
      const raw = '''
      {"ops":[
        {"op":"add","id":0,"type":"room","description":"hall","x":0.1,"y":0.2,"confidence":0.9},
        {"op":"add","id":1,"type":"room","description":"library","x":0.8,"y":0.7,"confidence":0.8},
        {"op":"connect","id":0,"connections":[1]},
        {"op":"update","id":1,"description":"grand library"},
        {"op":"add","id":2,"type":"door","description":"oak","x":0.5,"y":0.5,"confidence":0.7},
        {"op":"remove","id":2}
      ]}''';

      final graph = MapUpdate.parse(raw).apply(MapGraph.empty());

      expect(graph.nodeIds, equals([0, 1]));
      expect(graph.node(0)!.type, equals('room'));
      expect(graph.node(0)!.connections, equals([1]));
      expect(graph.node(1)!.description, equals('grand library'));
      expect(graph.contains(2), isFalse); // added then removed
    });

    test('parse is independent of the in-memory build (round-trips canonical)',
        () {
      const raw =
          '{"ops":[{"op":"add","id":3,"type":"corridor","description":"north",'
          '"x":0.3,"y":0.4,"confidence":0.6,"connections":[1,2]}]}';
      final g = MapUpdate.parse(raw).apply(MapGraph.empty());
      final reparsed =
          MapGraph.fromFeatureCollection(g.toFeatureCollection());
      expect(reparsed.canonical, equals(g.canonical));
      expect(g.node(3)!.connections, equals([1, 2]));
    });
  });

  group('MapUpdate.parse — malformed output FAILS SAFELY (no mutation)', () {
    final base = MapGraph.fromNodes([
      MapNode(
          id: 0,
          type: 'room',
          description: 'seed',
          x: 0.5,
          y: 0.5,
          confidence: 0.9),
    ]);

    void expectFormatError(String raw) {
      expect(() => MapUpdate.parse(raw),
          throwsA(isA<MapUpdateFormatException>()), reason: raw);
    }

    test('truncated JSON', () => expectFormatError('{"ops":[{"op":"add"'));
    test('root not an object', () => expectFormatError('[1,2,3]'));
    test('no object at all', () => expectFormatError('sorry, I cannot help'));
    test('missing ops array', () => expectFormatError('{"nodes":[]}'));
    test('unknown op kind',
        () => expectFormatError('{"ops":[{"op":"teleport","id":0}]}'));
    test('id out of range', () =>
        expectFormatError('{"ops":[{"op":"remove","id":99999}]}'));
    test('coordinate out of [0,1]', () => expectFormatError(
        '{"ops":[{"op":"add","id":1,"type":"x","x":1.7,"y":0.2,"confidence":0.5}]}'));
    test('add missing required field', () => expectFormatError(
        '{"ops":[{"op":"add","id":1,"type":"x","x":0.1,"y":0.2}]}'));
    test('too many connections', () {
      final conns = List<int>.generate(kMaxConnections + 1, (i) => i).join(',');
      expectFormatError('{"ops":[{"op":"connect","id":0,"connections":[$conns]}]}');
    });
    test('empty update', () =>
        expectFormatError('{"ops":[{"op":"update","id":0}]}'));

    test('a malformed batch leaves the base graph untouched', () {
      expect(() => MapUpdate.parse('{"ops":[{"op":"add"').apply(base),
          throwsA(isA<MapUpdateFormatException>()));
      expect(base.nodeIds, equals([0]));
      expect(base.node(0)!.description, equals('seed'));
    });
  });

  group('MapUpdate.apply — semantic conflicts fail safely', () {
    final base = MapGraph.fromNodes([
      MapNode(
          id: 0,
          type: 'room',
          description: 'seed',
          x: 0.5,
          y: 0.5,
          confidence: 0.9),
    ]);

    test('add onto a live id is a conflict; graph unchanged', () {
      final upd = MapUpdate.parse(
          '{"ops":[{"op":"add","id":0,"type":"room","x":0.1,"y":0.1,"confidence":0.5}]}');
      expect(() => upd.apply(base), throwsA(isA<MapUpdateConflictException>()));
      expect(base.node(0)!.description, equals('seed'));
    });

    test('update a missing id is a conflict', () {
      final upd = MapUpdate.parse('{"ops":[{"op":"update","id":7,"x":0.2}]}');
      expect(() => upd.apply(base), throwsA(isA<MapUpdateConflictException>()));
    });
  });

  group('MapUpdate.parse — tolerant extraction', () {
    test('strips prose and ```json fences around the object', () {
      const raw = '''
Here is the update you asked for:
```json
{"ops":[{"op":"add","id":0,"type":"room","description":"den","x":0.2,"y":0.3,"confidence":0.8}]}
```
Let me know if you need anything else.''';
      final g = MapUpdate.parse(raw).apply(MapGraph.empty());
      expect(g.node(0)!.description, equals('den'));
    });

    test('braces inside a string literal do not break extraction', () {
      const raw =
          'prefix {"ops":[{"op":"update","id":0,"description":"a }{ ][ label"}]} suffix';
      final g = MapUpdate.parse(raw).apply(MapGraph.fromNodes([
        MapNode(
            id: 0,
            type: 'room',
            description: 'old',
            x: 0.1,
            y: 0.1,
            confidence: 0.5),
      ]));
      expect(g.node(0)!.description, equals('a }{ ][ label'));
    });
  });

  group('InferenceEngine — orchestration with an injected model', () {
    test('generate applies the model output onto the base graph', () {
      final engine = InferenceEngine((prompt) =>
          '{"ops":[{"op":"add","id":0,"type":"room","description":"AI room",'
          '"x":0.5,"y":0.5,"confidence":0.9}]}');
      final prompt = MultimodalPrompt(
          instruction: 'map it', imageWidth: 64, imageHeight: 64, imageChannels: 3);
      final g = engine.generate(MapGraph.empty(), prompt);
      expect(g.node(0)!.description, equals('AI room'));
    });

    test('end-to-end: a mock multimodal block commits into a VC repo', () {
      final dir = Directory.systemTemp.createTempSync('carty_infer_');
      try {
        final repo = MapRepository.init(dir.path);
        final genesis = repo.headCommitId;

        final engine = InferenceEngine((prompt) =>
            '{"ops":[{"op":"add","id":0,"type":"room","description":"scanned",'
            '"x":0.4,"y":0.6,"confidence":0.85}]}');
        final prompt = MultimodalPrompt(
            instruction: 'reconstruct the room from this segment',
            bounds: SpatialBounds.full(),
            imageWidth: 224,
            imageHeight: 224,
            imageChannels: 3);

        final commitId = engine.commitGeneration(repo, prompt,
            timestampMillis: 1700000000000, message: 'ai: first scan');

        expect(commitId, isNot(equals(genesis)));
        final committed = repo.readGraphAt(commitId);
        expect(committed.node(0)!.description, equals('scanned'));
        expect(repo.readCommit(commitId).author, equals('gemma-4-e2b'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('InferenceEngine — VIDEO sequence (frames fold into one map)', () {
    // A video is an ordered sequence of analyzed frames. Each frame yields a
    // map-update that ACCRETES onto the running graph, so the map is built up
    // across the clip. These exercise that temporal fold WITHOUT weights, using
    // an injected inferer that returns a different op per frame.
    MultimodalPrompt frame(int i) => MultimodalPrompt(
        instruction: 'video frame $i',
        imageWidth: 64,
        imageHeight: 64,
        imageChannels: 3);

    test('folds per-frame updates into one accreting graph', () {
      // Frame N adds node N: a clip that discovers 3 rooms over time.
      var n = 0;
      final engine = InferenceEngine((prompt) {
        final id = n++;
        return '{"ops":[{"op":"add","id":$id,"type":"room",'
            '"description":"room $id","x":0.5,"y":0.5,"confidence":0.9}]}';
      });
      final g = engine.generateSequence(
          MapGraph.empty(), [frame(0), frame(1), frame(2)]);
      expect(g.nodeIds.toList()..sort(), equals([0, 1, 2]));
      expect(g.node(2)!.description, equals('room 2'));
    });

    test('empty clip is a no-op that returns the base graph', () {
      final engine = InferenceEngine((_) => '{"ops":[]}');
      final base = MapGraph.fromNodes([
        MapNode(id: 7, type: 'door', description: 'd', x: 0.1, y: 0.1,
            confidence: 0.5, connections: const []),
      ]);
      final g = engine.generateSequence(base, const []);
      expect(g.nodeIds.toList(), equals([7]));
    });

    test('a malformed frame mid-clip fails safely; base untouched', () {
      var n = 0;
      final engine = InferenceEngine((_) {
        final i = n++;
        // Frame 1 emits garbage -> the whole fold must throw, base preserved.
        return i == 1 ? 'not json at all' : '{"ops":[]}';
      });
      final base = MapGraph.empty();
      expect(() => engine.generateSequence(base, [frame(0), frame(1), frame(2)]),
          throwsA(isA<MapUpdateFormatException>()));
      expect(base.nodeIds, isEmpty); // immutable base never mutated
    });

    test('clip longer than maxFrames is rejected (bounded by construction)', () {
      final engine = InferenceEngine((_) => '{"ops":[]}');
      final tooMany = List.generate(kMaxVideoFrames + 1, frame);
      expect(() => engine.generateSequence(MapGraph.empty(), tooMany),
          throwsA(isA<ArgumentError>()));
    });

    test('commitSequence writes ONE commit for the whole clip', () {
      final dir = Directory.systemTemp.createTempSync('carty_vid_');
      try {
        final repo = MapRepository.init(dir.path);
        final genesis = repo.headCommitId;
        var n = 0;
        final engine = InferenceEngine((_) {
          final id = n++;
          return '{"ops":[{"op":"add","id":$id,"type":"room",'
              '"description":"r$id","x":0.5,"y":0.5,"confidence":0.9}]}';
        });
        final commitId = engine.commitSequence(
            repo, [frame(0), frame(1)],
            timestampMillis: 1700000000001, message: 'ai: clip scan');
        expect(commitId, isNot(equals(genesis)));
        final committed = repo.readGraphAt(commitId);
        expect(committed.nodeIds.toList()..sort(), equals([0, 1]));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('Native bridge — FFI surface the APK ships (host .so)', () {
    late Carty carty;

    setUpAll(() {
      final soPath = File('native/build/libcarty_bridge.so').absolute.path;
      if (!File(soPath).existsSync()) {
        fail('Build the host bridge first: cmake --build native/build ($soPath)');
      }
      carty = Carty.fromLibrary(DynamicLibrary.open(soPath));
    });

    // The native structural pre-gate (carty_validate_map_update_json) was
    // retired: the authoritative Dart parser (MapUpdate.parse)
    // is now the SOLE extraction semantics. See the "malformed output is caught
    // by the Dart parser" test below.

    // The host `.so` can LINK the real LiteRT subprocess. When the runtime env
    // vars are exported this call runs a REAL, slow decode instead of safe-failing
    // ENOMODEL, so the ENOMODEL contract only holds when the runtime is NOT
    // configured. Gated to stay honest in both worlds.
    final litertConfigured =
        Platform.environment.containsKey('CARTY_LITERT_RUNTIME') &&
            Platform.environment.containsKey('CARTY_GEMMA_MODEL');

    test(
      'multimodal infer fails safely (ENOMODEL) without crashing',
      () {
        final model = carty.loadModel('/tmp/gemma4_e2b.tflite');
        final segment =
            carty.allocFrame(width: 224, height: 224, channels: 3);
        try {
          final result = model.inferMapUpdate(
            imageSegment: segment,
            textPrompt: 'map this region',
            bx0: 0.0,
            by0: 0.0,
            bx1: 1.0,
            by1: 1.0,
          );
          expect(result.ok, isFalse);
          expect(result.status, equals(CARTY_INFER_ENOMODEL));
          expect(result.text, isEmpty);
        } finally {
          segment.dispose();
          model.dispose();
        }
      },
      skip: litertConfigured
          ? 'host .so links LiteRT and the runtime is configured: '
              'this call now runs a real decode, not ENOMODEL — the real path is '
              'covered by native ctest (litert_forward) and the opt-in '
              'video_pipeline real-decode test'
          : null,
    );

    test('a malformed model output is caught by the authoritative Dart parser',
        () {
      const bad = '{"ops":[{"op":"add"'; // truncated
      // The Dart parser is the sole extraction semantics:
      // malformed text raises and never mutates the map.
      expect(() => MapUpdate.parse(bad),
          throwsA(isA<MapUpdateFormatException>()));
    });
  });
}
