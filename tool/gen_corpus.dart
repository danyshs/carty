// tool/gen_corpus.dart
import 'dart:convert';
import 'dart:io';

/// Deterministic code-generated corpus. Authoring the scene in
/// code means we KNOW its exact occupancy + room/door graph by construction —
/// the only way to score a map is to know the right answer. Same seed → same
/// bytes, so the committed fixture is reproducible and CI is hermetic.
String genBoxTwoRoom({int seed = 1}) {
  const n = 6;
  // Outer wall ring + a partition column at gx=2 spanning rows 2..3.
  final cells = List<int>.filled(n * n, 0);
  for (var i = 0; i < n; i++) {
    cells[i] = 1; // top
    cells[(n - 1) * n + i] = 1; // bottom
    cells[i * n] = 1; // left
    cells[i * n + (n - 1)] = 1; // right
  }
  cells[2 * n + 2] = 1;
  cells[3 * n + 2] = 1;
  final m = {
    'origin_x': 0, 'origin_y': 0, 'res_m': 1, 'n': n, 'cells': cells,
  };
  return const JsonEncoder.withIndent('  ').convert(m);
}

String genBoxTwoRoomMapGraph() {
  final m = {
    'rooms': [
      {'id': 0, 'polygon': [[1, 1], [2, 1], [2, 5], [1, 5]]},
      {'id': 1, 'polygon': [[3, 1], [5, 1], [5, 5], [3, 5]]},
    ],
    'doors': [{'roomA': 0, 'roomB': 1, 'x': 2.5, 'y': 3}],
  };
  return const JsonEncoder.withIndent('  ').convert(m);
}

void main(List<String> args) {
  final dir = args.isEmpty ? 'test/fixtures/benchmark/box_two_room' : args.first;
  Directory(dir).createSync(recursive: true);
  File('$dir/truth_occupancy.json').writeAsStringSync(genBoxTwoRoom());
  File('$dir/truth_mapgraph.json').writeAsStringSync(genBoxTwoRoomMapGraph());
  File('$dir/meta.json').writeAsStringSync(
      '{ "name": "box_two_room", "units": "m", "source": "codegen", "seed": 1 }\n');
  File('$dir/expected.json').writeAsStringSync('{ "iou_floor": 0.0, "f1_floor": 0.0 }\n');
  stdout.writeln('wrote $dir');
}
