/// Live top-down occupancy renderer — the hero surface. It exists to turn
/// the fused CartyWorldGrid into the "watch a map of THIS place fill in" moment
/// It renders ONLY observation evidence (log-odds > 0) and never
/// fabricates geometry — an empty grid shows an
/// honest hint, not invented walls. Value equality makes shouldRepaint exact, so
/// the live loop repaints exactly when the grid changes (mirrors MapGraphPainter).
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';

/// The camera's live position + facing in GRID coordinates — the "you are here"
/// marker. Coordinates are fractional cells (gx,gy) so the marker slides smoothly
/// between cells; [headingRad] is the facing direction in grid space (0 = +gx,
/// increasing toward +gy), drawn as an arrow so the operator can orient the map
/// to their body. A plain value type so it participates in [OccupancyHeatmap]
/// equality (the marker moving must trigger a repaint).
@immutable
class CameraMarker {
  const CameraMarker({
    required this.gx,
    required this.gy,
    required this.headingRad,
  });

  final double gx;
  final double gy;
  final double headingRad;

  @override
  bool operator ==(Object other) =>
      other is CameraMarker &&
      gx == other.gx &&
      gy == other.gy &&
      headingRad == other.headingRad;

  @override
  int get hashCode => Object.hash(gx, gy, headingRad);
}

/// Inclusive bounding box (in grid cells) of the observed region — the input to
/// the painter's auto-fit zoom. It exists so the renderer maps ONLY the cells the
/// operator actually walked into the widget, not the full (mostly-empty) grid:
/// without it a real room is a few pale pixels lost in 256×256 of background.
@immutable
class GridBounds {
  const GridBounds({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  final int minX;
  final int minY;
  final int maxX;
  final int maxY;

  int get width => maxX - minX + 1;
  int get height => maxY - minY + 1;
}

@immutable
class OccupancyHeatmap {
  const OccupancyHeatmap({
    required this.cells,
    required this.n,
    required this.h,
    int? band,
    this.color,
    this.camera,
  }) : band = band ?? (h ~/ 2);

  final Int8List cells; // band-major n*n*h log-odds (zero-copy from the bridge)
  final int n;
  final int h;
  final int band;

  /// The floor-OBSERVATION photo-map: `n*n*3` row-major RGB, the real camera
  /// color each ground cell was seen with (0,0,0 == unobserved). Null until the
  /// bridge color buffer is plumbed through. HONESTY: evidence of
  /// what the floor looked like, NOT the D&D map — walls show only as the edge
  /// where coverage stops (mirrors [CartyWorldGridHandle.color]).
  final Uint8List? color;

  /// The live "you are here" marker, or null when pose is unavailable.
  final CameraMarker? camera;

  /// The single ground plane the current accrete folds into (camera-height band).
  Int8List get bandSlice {
    final out = Int8List(n * n);
    final base = band * n * n;
    for (var i = 0; i < n * n; i++) {
      out[i] = cells[base + i];
    }
    return out;
  }

  int get observedCount {
    final slice = bandSlice;
    var c = 0;
    for (final v in slice) {
      if (v > 0) c++;
    }
    return c;
  }

  /// Tight bounding box of observed cells (band-slice log-odds > 0), or null when
  /// nothing has been observed. Drives the painter's auto-fit zoom.
  GridBounds? get observedBounds {
    final slice = bandSlice;
    var minX = n, minY = n, maxX = -1, maxY = -1;
    for (var gy = 0; gy < n; gy++) {
      for (var gx = 0; gx < n; gx++) {
        if (slice[gy * n + gx] <= 0) continue;
        if (gx < minX) minX = gx;
        if (gx > maxX) maxX = gx;
        if (gy < minY) minY = gy;
        if (gy > maxY) maxY = gy;
      }
    }
    if (maxX < 0) return null;
    return GridBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }

  /// The real RGB this ground cell was observed with, or null if there is no
  /// color buffer or the cell is unobserved (sentinel 0,0,0). Row-major lookup
  /// into the `n*n*3` photo-map: `idx=(gy*n+gx)*3`.
  Color? colorAt(int gx, int gy) {
    final c = color;
    if (c == null) return null;
    final i = (gy * n + gx) * 3;
    final r = c[i], g = c[i + 1], b = c[i + 2];
    if (r == 0 && g == 0 && b == 0) return null;
    return Color.fromARGB(255, r, g, b);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! OccupancyHeatmap) return false;
    if (n != other.n || h != other.h || band != other.band) return false;
    if (camera != other.camera) return false;
    final a = bandSlice, b = other.bandSlice;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    final ca = color, cb = other.color;
    if ((ca == null) != (cb == null)) return false;
    if (ca != null && cb != null) {
      if (ca.length != cb.length) return false;
      for (var i = 0; i < ca.length; i++) {
        if (ca[i] != cb[i]) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = Object.hash(n, h, band, camera);
    final slice = bandSlice;
    for (final v in slice) {
      hash = 0x1fffffff & (hash * 31 + v);
    }
    return hash;
  }
}

class OccupancyHeatmapPainter extends CustomPainter {
  OccupancyHeatmapPainter(this.heatmap);

  final OccupancyHeatmap heatmap;

  static const Color _bg = Color(0xFF12161D);
  static const Color _observed = Color(0xFF4FC3F7);
  static const double _pad = 8.0; // widget-px margin around the fitted bbox

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
    final n = heatmap.n;
    if (n <= 0) return;

    final bounds = heatmap.observedBounds;
    if (bounds == null) {
      _hint(canvas, size,
          'Walk the space — the map fills in as Carty observes it.');
      return;
    }

    // Auto-fit: map ONLY the observed bbox into the widget, square cells, so a
    // walked room fills the view instead of being a few pale pixels in 256×256.
    final cw = (size.width - 2 * _pad) / bounds.width;
    final ch = (size.height - 2 * _pad) / bounds.height;
    final cell = math.min(cw, ch);
    final ox = _pad + (size.width - 2 * _pad - cell * bounds.width) / 2;
    final oy = _pad + (size.height - 2 * _pad - cell * bounds.height) / 2;
    double sx(num gx) => ox + (gx - bounds.minX) * cell;
    double sy(num gy) => oy + (gy - bounds.minY) * cell;

    final slice = heatmap.bandSlice;
    for (var gy = bounds.minY; gy <= bounds.maxY; gy++) {
      for (var gx = bounds.minX; gx <= bounds.maxX; gx++) {
        final v = slice[gy * n + gx];
        if (v <= 0) continue;
        // Real observed color when we have the photo-map; else fall back to the
        // confidence-ramped blue (honest: no color buffer plumbed yet).
        final real = heatmap.colorAt(gx, gy);
        final Paint paint;
        if (real != null) {
          paint = Paint()..color = real;
        } else {
          final intensity = (v / 127.0).clamp(0.05, 1.0);
          paint = Paint()..color = _observed.withValues(alpha: intensity);
        }
        canvas.drawRect(
          Rect.fromLTWH(sx(gx), sy(gy), cell + 0.5, cell + 0.5),
          paint,
        );
      }
    }

    final cam = heatmap.camera;
    if (cam != null) _drawCamera(canvas, cam, sx(cam.gx), sy(cam.gy), cell);
  }

  /// "You are here" + heading arrow, so the operator can orient the map to their
  /// own body. Drawn last (on top of the cells); sized off the cell pitch so it
  /// scales with the auto-fit zoom.
  void _drawCamera(Canvas canvas, CameraMarker cam, double px, double py,
      double cell) {
    final r = math.max(4.0, cell * 1.5);
    canvas.drawCircle(
        Offset(px, py), r, Paint()..color = const Color(0xFFFFCA28));
    canvas.drawCircle(
      Offset(px, py),
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF12161D),
    );
    final tip = Offset(
      px + math.cos(cam.headingRad) * r * 2.2,
      py + math.sin(cam.headingRad) * r * 2.2,
    );
    canvas.drawLine(
      Offset(px, py),
      tip,
      Paint()
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFFFCA28),
    );
  }

  void _hint(Canvas canvas, Size size, String text) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: const TextStyle(color: Colors.white38, fontSize: 12)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    tp.paint(canvas,
        Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  @override
  bool shouldRepaint(covariant OccupancyHeatmapPainter old) =>
      old.heatmap != heatmap;
}
