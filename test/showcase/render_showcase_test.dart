// Renders the box_two_room e2e run to the README images. Skipped unless SHOWCASE_OUT is set:
// SHOWCASE_OUT=docs/images flutter test test/showcase/render_showcase_test.dart
import 'dart:ffi' show DynamicLibrary;
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:carty/benchmark.dart';
import 'package:carty/capture.dart';
import 'package:carty/carty.dart';
import 'package:carty/render.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _save(void Function(Canvas, Size) draw, Size size, String path) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101418));
  draw(canvas, size);
  final img = await rec.endRecording().toImage(size.width.toInt(), size.height.toInt());
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
}

List<List<double>> _ring(Object? geom) {
  final g = geom as Map<String, Object?>;
  final coords = (g['coordinates'] as List).first as List;
  return [for (final p in coords) [(p as List)[0].toDouble(), p[1].toDouble()]];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('render showcase', () async {
    const dir = 'test/fixtures/benchmark/box_two_room';
    final out = Platform.environment['SHOWCASE_OUT']!;
    Directory(out).createSync(recursive: true);
    final carty = Carty.fromLibrary(
        DynamicLibrary.open(File('native/build/libcarty_bridge.so').absolute.path));
    final scene = loadScene(dir);
    final replay = ReplayHarness.fromLines(File('$dir/capture.jsonl').readAsLinesSync());
    final grid = carty.createWorldGrid(n: 96, h: 16, resM: 0.1, bandM: 0.25);
    FusionLoop(carty).runFromDepth(replay: replay, grid: grid, sidecarDir: dir);

    final hm = OccupancyHeatmap(cells: Int8List.fromList(grid.cells), n: 96, h: 16);
    const size = Size(800, 800);
    await _save((c, s) => OccupancyHeatmapPainter(hm).paint(c, s), size, '$out/fused_occupancy.png');

    final geo = grid.vectorize();
    final feats = (geo['features'] as List).cast<Map<String, Object?>>();
    final rooms = [for (final f in feats) if ((f['geometry'] as Map)['type'] == 'Polygon') _ring(f['geometry'])];
    final truth = [for (final r in scene.truthMapGraph.rooms) r];
    double minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9;
    for (final r in rooms) { for (final p in r) { minX = p[0] < minX ? p[0] : minX; maxX = p[0] > maxX ? p[0] : maxX; minY = p[1] < minY ? p[1] : minY; maxY = p[1] > maxY ? p[1] : maxY; } }
    final colors = [const Color(0xFF4FC3F7), const Color(0xFFFFB74D), const Color(0xFF81C784), const Color(0xFFE57373)];
    await _save((c, s) {
      final scale = (s.width - 80) / ((maxX - minX) > (maxY - minY) ? (maxX - minX) : (maxY - minY));
      Offset tx(List<double> p) => Offset(40 + (p[0] - minX) * scale, 40 + (p[1] - minY) * scale);
      for (var i = 0; i < rooms.length; i++) {
        final path = Path()..addPolygon([for (final p in rooms[i]) tx(p)], true);
        c.drawPath(path, Paint()..color = colors[i % 4].withValues(alpha: 0.35));
        c.drawPath(path, Paint()..color = colors[i % 4]..style = PaintingStyle.stroke..strokeWidth = 4);
      }
    }, size, '$out/vectorized_rooms.png');
    // ignore: avoid_print
    print('rooms=${rooms.length} truthRooms=${truth.length} bbox=$minX,$minY..$maxX,$maxY features=${feats.length}');
    grid.dispose();
  }, skip: Platform.environment['SHOWCASE_OUT'] == null ? 'set SHOWCASE_OUT to render' : null);
}
