import 'dart:io';
import 'dart:convert';
import 'package:carty/benchmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('box_two_room: real vectorized graph clears a non-zero F1 floor', () {
    final dir = 'test/fixtures/benchmark/box_two_room';
    final scene = loadScene(dir);
    final fc = jsonDecode(File('$dir/vectorized.geojson').readAsStringSync())
        as Map<String, Object?>;
    final predicted = scoredGraphFromGeoJson(fc);
    final f1 = roomDoorF1(predicted, scene.truthMapGraph).f1;
    expect(f1, greaterThan(0.0));
    expect(f1, greaterThanOrEqualTo(scene.f1Floor)); // floor ratcheted below
  });
}
