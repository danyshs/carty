// test/benchmark/corpus_test.dart
import 'package:carty/benchmark.dart';
import 'package:test/test.dart';

void main() {
  const dir = 'test/fixtures/benchmark/box_two_room';

  test('loads the committed scene with polygon truth', () {
    final s = loadScene(dir);
    expect(s.name, 'box_two_room');
    expect(s.truthMapGraph.rooms.length, 2);
    expect(s.truthMapGraph.doors.length, 1);
    expect(s.truthOccupancy.n, greaterThan(0));
  });

  test('scoring truth against itself is a perfect score', () {
    final s = loadScene(dir);
    expect(occupancyIou(s.truthOccupancy, s.truthOccupancy), closeTo(1.0, 1e-9));
    expect(roomDoorF1(s.truthMapGraph, s.truthMapGraph).f1, closeTo(1.0, 1e-9));
  });

  test('a malformed scene dir throws FormatException, not a crash', () {
    expect(() => loadScene('test/fixtures/benchmark/does_not_exist'),
        throwsA(isA<FormatException>()));
  });
}
