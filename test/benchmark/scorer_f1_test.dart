// test/benchmark/scorer_f1_test.dart
import 'package:carty/benchmark.dart';
import 'package:test/test.dart';

ScoredRoom _sq(int id, double x, double y, double s) => ScoredRoom(
      id: id,
      polygon: [(x: x, y: y), (x: x + s, y: y), (x: x + s, y: y + s), (x: x, y: y + s)],
    );

void main() {
  test('identical graph → F1 1.0', () {
    final g = ScoredGraph(
      rooms: [_sq(0, 0, 0, 4), _sq(1, 6, 0, 4)],
      doors: [ScoredDoor(roomA: 0, roomB: 1, x: 5, y: 2)],
    );
    final r = roomDoorF1(g, g);
    expect(r.f1, closeTo(1.0, 1e-9));
  });

  test('one missing door → precision 1, recall < 1', () {
    final truth = ScoredGraph(
      rooms: [_sq(0, 0, 0, 4), _sq(1, 6, 0, 4)],
      doors: [ScoredDoor(roomA: 0, roomB: 1, x: 5, y: 2)],
    );
    final pred = ScoredGraph(rooms: truth.rooms, doors: const []);
    final r = roomDoorF1(pred, truth);
    // 2 rooms matched, 0/1 doors → matched 2, predicted 2, truth 3
    expect(r.precision, closeTo(1.0, 1e-9));
    expect(r.recall, closeTo(2 / 3, 1e-9));
  });

  test('a room below the overlap threshold is unmatched', () {
    final truth = ScoredGraph(rooms: [_sq(0, 0, 0, 4)], doors: const []);
    final pred = ScoredGraph(rooms: [_sq(0, 3.5, 0, 4)], doors: const []); // ~12% overlap
    final r = roomDoorF1(pred, truth);
    expect(r.matched, 0);
  });

  test('door just outside doorPosTol is unmatched', () {
    final rooms = [_sq(0, 0, 0, 4), _sq(1, 6, 0, 4)];
    final truth = ScoredGraph(rooms: rooms, doors: [ScoredDoor(roomA: 0, roomB: 1, x: 5, y: 2)]);
    final pred = ScoredGraph(rooms: rooms, doors: [ScoredDoor(roomA: 0, roomB: 1, x: 5, y: 9)]);
    final r = roomDoorF1(pred, truth, doorPosTol: 3.0);
    expect(r.matched, 2); // both rooms match, door does not
  });

  test('sub-unit room offset is scored on a refined lattice, not unit cells', () {
    // Unit-metre square truth vs a 0.4 m-shifted unit square: true IoU is
    // overlap 0.6 / union 1.4 = 0.4286 < 0.5, so the rooms must NOT match. A
    // unit-step rasterizer samples a single cell centre and rounds this to a
    // false IoU=1.0 (a spurious match); the refined lattice scores it correctly.
    final truth = ScoredGraph(rooms: [_sq(0, 0, 0, 1)], doors: const []);
    final pred = ScoredGraph(rooms: [_sq(0, 0.4, 0, 1)], doors: const []);
    final r = roomDoorF1(pred, truth);
    expect(r.matched, 0);
  });
}
