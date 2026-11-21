// test/render/occupancy_heatmap_painter_test.dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:carty/render.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

OccupancyHeatmap _heatmap(int n, int h, void Function(Int8List) fill) {
  final cells = Int8List(n * n * h);
  fill(cells);
  return OccupancyHeatmap(cells: cells, n: n, h: h);
}

void main() {
  test('bandSlice extracts the camera-height band (h~/2), length n*n', () {
    const n = 4, h = 4;
    final hm = _heatmap(n, h, (cells) {
      // Mark cell (gx=1,gy=2) at band h~/2=2 → idx=(2*4+2)*4+1 = 41.
      cells[(2 * n + 2) * n + 1] = 20;
    });
    expect(hm.bandSlice.length, n * n);
    expect(hm.bandSlice[2 * n + 1], 20); // (gy=2,gx=1) in the slice
    expect(hm.observedCount, 1);
  });

  test('value equality: same contents equal, one changed cell differs', () {
    final a = _heatmap(4, 4, (c) => c[(2 * 4 + 0) * 4 + 0] = 10);
    final b = _heatmap(4, 4, (c) => c[(2 * 4 + 0) * 4 + 0] = 10);
    final c = _heatmap(4, 4, (c) => c[(2 * 4 + 0) * 4 + 0] = 11);
    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.hashCode, equals(b.hashCode));
  });

  test('shouldRepaint: false for equal heatmap, true for changed', () {
    final a = _heatmap(4, 4, (c) => c[(2 * 4 + 0) * 4 + 0] = 10);
    final b = _heatmap(4, 4, (c) => c[(2 * 4 + 0) * 4 + 0] = 10);
    final c = _heatmap(4, 4, (c) => c[(2 * 4 + 0) * 4 + 0] = 99);
    expect(OccupancyHeatmapPainter(b).shouldRepaint(OccupancyHeatmapPainter(a)),
        isFalse);
    expect(OccupancyHeatmapPainter(c).shouldRepaint(OccupancyHeatmapPainter(a)),
        isTrue);
  });

  testWidgets('paints without throwing for empty and populated grids',
      (tester) async {
    for (final hm in [
      _heatmap(8, 4, (_) {}), // empty → hint path
      _heatmap(8, 4, (c) => c[(2 * 8 + 3) * 8 + 3] = 40), // populated
    ]) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      OccupancyHeatmapPainter(hm).paint(canvas, const Size(200, 200));
      recorder.endRecording().dispose();
    }
  });

  test('observedBounds is null for an empty grid, tight for a populated one',
      () {
    const n = 8, h = 4;
    expect(_heatmap(n, h, (_) {}).observedBounds, isNull);
    final hm = _heatmap(n, h, (c) {
      c[(2 * n + 1) * n + 2] = 10; // (gx=2,gy=1)
      c[(2 * n + 3) * n + 5] = 10; // (gx=5,gy=3)
    });
    final b = hm.observedBounds!;
    expect([b.minX, b.minY, b.maxX, b.maxY], [2, 1, 5, 3]);
    expect([b.width, b.height], [4, 3]);
  });

  test('colorAt reads the n*n*3 RGB photo-map; null when unobserved/absent', () {
    const n = 4, h = 4;
    final cells = Int8List(n * n * h);
    cells[(2 * n + 1) * n + 2] = 10; // observed at (gx=2,gy=1)
    final color = Uint8List(n * n * 3);
    final ci = (1 * n + 2) * 3; // (gy=1,gx=2)
    color[ci] = 200;
    color[ci + 1] = 100;
    color[ci + 2] = 50;
    final hm = OccupancyHeatmap(cells: cells, n: n, h: h, color: color);
    expect(hm.colorAt(2, 1), const Color(0xFFC86432)); // 200,100,50
    expect(hm.colorAt(0, 0), isNull); // all-zero → unobserved
    // No color buffer at all → null everywhere.
    expect(OccupancyHeatmap(cells: cells, n: n, h: h).colorAt(2, 1), isNull);
  });

  test('equality includes the color buffer and the camera marker', () {
    final cells = Int8List(4 * 4 * 4)..[(2 * 4 + 0) * 4 + 0] = 10;
    final colorA = Uint8List(4 * 4 * 3)..[0] = 9;
    final colorB = Uint8List(4 * 4 * 3)..[0] = 99;
    final base = OccupancyHeatmap(cells: cells, n: 4, h: 4, color: colorA);
    expect(base,
        equals(OccupancyHeatmap(cells: cells, n: 4, h: 4, color: colorA)));
    expect(base,
        isNot(equals(OccupancyHeatmap(cells: cells, n: 4, h: 4, color: colorB))));
    const cam = CameraMarker(gx: 1, gy: 1, headingRad: 0);
    expect(
      OccupancyHeatmap(cells: cells, n: 4, h: 4, color: colorA, camera: cam),
      isNot(equals(base)),
    );
  });

  testWidgets('paints colored map with a camera marker without throwing',
      (tester) async {
    const n = 8, h = 4;
    final cells = Int8List(n * n * h)..[(2 * n + 3) * n + 3] = 40;
    final color = Uint8List(n * n * 3);
    final ci = (3 * n + 3) * 3;
    color[ci] = 180;
    color[ci + 1] = 160;
    color[ci + 2] = 120;
    final hm = OccupancyHeatmap(
      cells: cells,
      n: n,
      h: h,
      color: color,
      camera: const CameraMarker(gx: 3.5, gy: 3.5, headingRad: 1.2),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    OccupancyHeatmapPainter(hm).paint(canvas, const Size(200, 200));
    recorder.endRecording().dispose();
  });
}
