/// [MapGraphPainter] — renders a Carty [MapGraph] as a spatial node graph
///. Nodes are placed by their frame-normalized (x, y) in [0,1],
/// connections are drawn as edges, and the whole thing repaints as the model
/// commits nodes (drive it from a [PipelineFrame.graph] stream).
///
/// Pure presentation: it reads the immutable graph and never mutates it.
/// Equality of [MapGraph] is by canonical content, so [shouldRepaint] is exact —
/// an identical graph triggers no repaint, a committed node always does.
library;

import 'package:material_ui/material_ui.dart';

import '../vc/map_graph.dart';
import '../vc/map_node.dart';

class MapGraphPainter extends CustomPainter {
  final MapGraph graph;

  /// Whether to draw node text labels (off for tiny thumbnails).
  final bool showLabels;

  MapGraphPainter(this.graph, {this.showLabels = true});

  // A small, stable palette keyed by node type so the same feature kind keeps
  // its colour across frames as the map accretes.
  static const List<Color> _palette = [
    Color(0xFF4FC3F7), // room
    Color(0xFFFFB74D), // door
    Color(0xFF81C784), // corridor
    Color(0xFFE57373), // landmark
    Color(0xFFBA68C8), // wall
    Color(0xFF4DB6AC), // other
  ];

  Color _colorFor(String type) =>
      _palette[type.hashCode.abs() % _palette.length];

  Offset _project(MapNode node, Size size) => Offset(
        // Clamp defensively even though MapNode asserts [0,1] — a painter must
        // never throw mid-frame.
        node.x.clamp(0.0, 1.0) * size.width,
        node.y.clamp(0.0, 1.0) * size.height,
      );

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size);

    final ids = graph.nodeIds;
    if (ids.isEmpty) {
      _paintEmptyHint(canvas, size);
      return;
    }

    // Edges first, under the nodes. Draw each undirected connection once.
    final edgePaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final id in ids) {
      final node = graph.node(id)!;
      final from = _project(node, size);
      for (final other in node.connections) {
        if (other <= id) continue; // dedupe undirected edges
        final target = graph.node(other);
        if (target == null) continue; // dangling connection — skip, never crash
        canvas.drawLine(from, _project(target, size), edgePaint);
      }
    }

    // Nodes on top: radius scales gently with confidence.
    for (final id in ids) {
      final node = graph.node(id)!;
      final center = _project(node, size);
      final radius = 5.0 + 6.0 * node.confidence.clamp(0.0, 1.0);
      final color = _colorFor(node.type);

      canvas.drawCircle(
        center,
        radius + 2,
        Paint()..color = color.withValues(alpha: 0.25),
      );
      canvas.drawCircle(center, radius, Paint()..color = color);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      if (showLabels) {
        _paintLabel(canvas, center, radius, '${node.type} #$id');
      }
    }
  }

  void _paintBackground(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1A1F29),
    );
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1.0;
    const step = 32.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
  }

  void _paintEmptyHint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: const TextSpan(
        text: 'No nodes yet — frames are reaching the bridge.',
        style: TextStyle(color: Colors.white38, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
    );
  }

  void _paintLabel(Canvas canvas, Offset center, double radius, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 96);
    final dx = center.dx + radius + 3;
    final dy = center.dy - tp.height / 2;
    // Subtle backing so labels stay legible over edges.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(dx - 2, dy - 1, tp.width + 4, tp.height + 2),
        const Radius.circular(3),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant MapGraphPainter oldDelegate) =>
      oldDelegate.graph != graph || oldDelegate.showLabels != showLabels;
}
