// lib/benchmark/align.dart
import 'dart:math';

/// Closed-form similarity alignment (translate + uniform-scale + rotate, NO
/// reflection) used before IoU so "overhead-appearance correctness" is scored:
/// a globally shifted/rotated/scaled map must not be penalized, but a MIRRORED
/// one must (it is wrong overhead). Reflection is excluded by only ever applying
/// a proper rotation chosen from the two principal-axis orientations {θ, θ+π}.
class SimilarityAlign {
  static ({double x, double y}) _centroid(List<({double x, double y})> p) {
    assert(p.isNotEmpty, 'cannot align an empty point set');
    var sx = 0.0, sy = 0.0;
    for (final q in p) {
      sx += q.x;
      sy += q.y;
    }
    return (x: sx / p.length, y: sy / p.length);
  }

  static double _rms(List<({double x, double y})> p, ({double x, double y}) c) {
    var s = 0.0;
    for (final q in p) {
      s += (q.x - c.x) * (q.x - c.x) + (q.y - c.y) * (q.y - c.y);
    }
    return sqrt(s / p.length);
  }

  /// Principal axis angle of a centred point cloud: 0.5*atan2(2*Sxy, Sxx-Syy).
  static double principalAngle(List<({double x, double y})> p) {
    final c = _centroid(p);
    var sxx = 0.0, syy = 0.0, sxy = 0.0;
    for (final q in p) {
      final dx = q.x - c.x, dy = q.y - c.y;
      sxx += dx * dx;
      syy += dy * dy;
      sxy += dx * dy;
    }
    return 0.5 * atan2(2 * sxy, sxx - syy);
  }

  static List<({double x, double y})> _apply(
    List<({double x, double y})> src,
    ({double x, double y}) srcC,
    ({double x, double y}) dstC,
    double scale,
    double rot,
  ) {
    final cr = cos(rot), sr = sin(rot);
    return [
      for (final q in src)
        (
          x: dstC.x + scale * ((q.x - srcC.x) * cr - (q.y - srcC.y) * sr),
          y: dstC.y + scale * ((q.x - srcC.x) * sr + (q.y - srcC.y) * cr),
        )
    ];
  }

  static double _meanSqNearest(
      List<({double x, double y})> a, List<({double x, double y})> b) {
    // Symmetric-index distance is enough here: a/truth share construction order
    // in tests, and for IoU the metric re-rasterizes anyway. We pick the rotation
    // minimizing summed squared INDEX distance, which resolves the 180° ambiguity.
    final m = min(a.length, b.length);
    var s = 0.0;
    for (var i = 0; i < m; i++) {
      s += (a[i].x - b[i].x) * (a[i].x - b[i].x) +
          (a[i].y - b[i].y) * (a[i].y - b[i].y);
    }
    return s / m;
  }

  /// Map [source] into [truth]'s frame. Resolves the principal-axis 180°
  /// ambiguity by trying both {θ, θ+π} and keeping the lower-residual rotation.
  static List<({double x, double y})> alignToTruth(
    List<({double x, double y})> source,
    List<({double x, double y})> truth,
  ) {
    assert(source.isNotEmpty && truth.isNotEmpty, 'empty point set');
    final sc = _centroid(source), tc = _centroid(truth);
    final srms = _rms(source, sc), trms = _rms(truth, tc);
    final scale = srms == 0 ? 1.0 : trms / srms;
    final base = principalAngle(truth) - principalAngle(source);
    final candA = _apply(source, sc, tc, scale, base);
    final candB = _apply(source, sc, tc, scale, base + pi);
    return _meanSqNearest(candA, truth) <= _meanSqNearest(candB, truth)
        ? candA
        : candB;
  }
}
