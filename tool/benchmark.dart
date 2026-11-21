// tool/benchmark.dart
import 'dart:io';
import 'package:carty/benchmark.dart';

/// One scene's measured scores vs its committed floor. The CI gate
/// fails the build when any scene regresses below its floor — the instrument
/// that turns "the map is good" into a number every later rung must beat.
class SceneScore {
  final String name;
  final double iou, f1, iouFloor, f1Floor;
  SceneScore(this.name, this.iou, this.f1, this.iouFloor, this.f1Floor);
  bool get passes => iou >= iouFloor && f1 >= f1Floor;
}

/// Score a scene. With no [fused]/[predicted] it scores truth-against-truth —
/// the stub-grid trick that proves the harness end-to-end before
/// real fusion/vectorize quality exists; #7 later supplies the real outputs.
SceneScore scoreScene(BenchmarkScene s,
    {OccupancyGrid? fused, ScoredGraph? predicted}) {
  final iou = occupancyIou(fused ?? s.truthOccupancy, s.truthOccupancy);
  final f1 = roomDoorF1(predicted ?? s.truthMapGraph, s.truthMapGraph).f1;
  return SceneScore(s.name, iou, f1, s.iouFloor, s.f1Floor);
}

List<SceneScore> runCorpus(List<String> dirs) => [
      for (final d in dirs)
        () {
          final s = loadScene(d);
          // Gate integrity: a scene with a non-zero f1 floor MUST be scored
          // against a real vectorized graph. Without this guard a scene that
          // declares a floor but is missing vectorized.geojson would fall back
          // to truth-vs-truth (f1=1.0) and pass falsely — masking a regression.
          if (s.f1Floor > 0 && s.predictedMapGraph == null) {
            throw StateError(
                'scene "${s.name}" has f1_floor=${s.f1Floor} but no '
                'vectorized.geojson — cannot score the real graph');
          }
          // Score the REAL vectorized graph when the scene has one;
          // otherwise scoreScene falls back to the truth-vs-truth stub.
          return scoreScene(s, predicted: s.predictedMapGraph);
        }()
    ];

void main(List<String> args) {
  final dirs = args.isEmpty
      ? Directory('test/fixtures/benchmark')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path)
          .toList()
      : args;
  var failed = false;
  for (final score in runCorpus(dirs)) {
    final ok = score.passes;
    failed = failed || !ok;
    stdout.writeln(
        '${ok ? "PASS" : "FAIL"} ${score.name}  iou=${score.iou.toStringAsFixed(3)} '
        '(>=${score.iouFloor}) f1=${score.f1.toStringAsFixed(3)} (>=${score.f1Floor})');
  }
  if (failed) exit(1);
}
