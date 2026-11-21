/// The LIVE replay→fuse loop — the on-device sibling of [FusionLoop.runFromFrames]
/// (lib/capture/fusion_loop.dart). It exists so the hero moment ("walk a
/// space, watch its accurate top-down map fill in") runs against a LIVE keyframe
/// stream while reusing the exact, host-proven fold path: each TRACKING keyframe
/// is back-projected with full extrinsics + K via [CartyWorldGridHandle.accreteFromFrame]
/// into ONE persistent world grid, then snapshotted into an [OccupancyHeatmap].
///
/// Deleting it would force the capture UI to embed the fusion + honesty logic
/// inline, where it could not be unit-tested without a device — the precise thing
/// the CaptureController seam was built to avoid. PAUSED keyframes
/// are dropped (they carry untrustworthy pose and would smear the grid), and the
/// honesty banner can never read HIGH while ARCore tracking is unhealthy
///.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../carty.dart';
import '../render.dart';
import 'fusion_loop.dart';
import 'honesty.dart';
import 'pose_sidecar.dart';

/// One live keyframe off the ARCore stream: a downscaled camera image plus the
/// pose + intrinsics needed to splat it metrically. A plain value type so the
/// live loop is driven by a fake stream in tests (no device).
@immutable
class CaptureKeyframe {
  const CaptureKeyframe({
    required this.pose,
    required this.image,
    required this.width,
    required this.height,
    required this.channels,
    required this.intrinsics,
  });

  /// Pose-sidecar fields for this frame (translation/rotation + tracking state +
  /// `t`, which doubles as the idempotency keyframe id).
  final PoseSample pose;

  /// Downscaled camera pixels, `width*height*channels` bytes (RGBA, channels==4).
  final Uint8List image;
  final int width;
  final int height;
  final int channels;

  /// Camera intrinsics for THIS resolution: `[fx, fy, cx, cy]`.
  final List<double> intrinsics;
}

/// Drives a persistent [CartyWorldGridHandle] from a live keyframe stream and
/// publishes a repaint-ready [OccupancyHeatmap] + an honesty [AccuracyLevel].
class LiveFusionController {
  LiveFusionController(
    this.carty, {
    this.n = 256,
    this.h = 16,
    double resM = 0.05,
    double bandM = 0.25,
    this.trackingWindow = 30,
    this.minTranslationM = 0.05,
  })  : _grid = carty.createWorldGrid(n: n, h: h, resM: resM, bandM: bandM) {
    // Honest empty start: an all-zero grid renders the "walk the space" hint, not
    // fabricated geometry.
    heatmap = ValueNotifier<OccupancyHeatmap>(_snapshot());
    accuracy = ValueNotifier<AccuracyLevel>(AccuracyLevel.degraded);
  }

  final Carty carty;
  final int n;
  final int h;

  /// How many recent keyframes the honesty banner's tracking-health ratio spans.
  final int trackingWindow;

  /// Minimum metric camera translation (m) between two FOLDED keyframes. A live
  /// stream delivers ~30 fps even while the operator stands still; without this
  /// gate those near-identical poses keep folding the same patch ahead of the
  /// feet, over-weighting it into the forward-bias smear the device walk exposed
  /// (HISTORY 2026-06-23). Re-delivered ids are exempt (see [onKeyframe]) so the
  /// native idempotency contract is unaffected.
  final double minTranslationM;

  final CartyWorldGridHandle _grid;

  /// Repaint-ready top-down occupancy snapshot; updated on each folded keyframe.
  late final ValueNotifier<OccupancyHeatmap> heatmap;

  /// Live accuracy banner level; never HIGH while ARCore tracking is unhealthy.
  late final ValueNotifier<AccuracyLevel> accuracy;

  // Sliding window of recent tracking states → the banner's health ratio.
  final List<TrackingState> _window = <TrackingState>[];

  int _accreted = 0, _duplicate = 0, _outOfBounds = 0, _seenFull = 0;
  int _throttledByTranslation = 0;
  bool _disposed = false;

  // Position + id of the last keyframe actually folded — the reference the
  // translation gate measures the next keyframe against. Null until the first
  // fold places the camera.
  double? _lastFoldX, _lastFoldY, _lastFoldZ;
  int? _lastFoldId;

  /// New TRACKING keyframes dropped because the camera had not moved past
  /// [minTranslationM] since the last fold. Exposed (separate from [stats]) so
  /// the live-loop throttle is observable in tests and dev diagnostics.
  int get throttledByTranslation => _throttledByTranslation;

  // Latest "you are here" marker (grid cell + heading), recomputed from each
  // accreted pose. Null until the first TRACKING keyframe places the camera.
  CameraMarker? _camera;

  FusionStats get stats => FusionStats(
        accreted: _accreted,
        duplicate: _duplicate,
        outOfBounds: _outOfBounds,
        seenFull: _seenFull,
      );

  /// Fold ONE live keyframe. PAUSED frames update only the honesty banner (they
  /// must never accrete — an untrustworthy pose would smear the grid). TRACKING
  /// frames are splatted with full extrinsics + K, then the heatmap is refreshed.
  void onKeyframe(CaptureKeyframe kf) {
    assert(!_disposed, 'onKeyframe after dispose');
    _window.add(kf.pose.state);
    if (_window.length > trackingWindow) {
      _window.removeAt(0);
    }
    _refreshAccuracy(kf.pose.state);

    if (kf.pose.state != TrackingState.tracking) return;

    // Translation gate: a genuinely-new keyframe (distinct id) that has not
    // moved past minTranslationM since the last fold is dropped before it can
    // re-fold the same forward patch. Re-delivered ids (id == last fold) are
    // exempt — they must reach native to be counted as duplicates, preserving
    // the idempotency contract the live loop depends on.
    if (_lastFoldId != null && kf.pose.t != _lastFoldId) {
      final dx = kf.pose.tx - _lastFoldX!;
      final dy = kf.pose.ty - _lastFoldY!;
      final dz = kf.pose.tz - _lastFoldZ!;
      if (math.sqrt(dx * dx + dy * dy + dz * dz) < minTranslationM) {
        _throttledByTranslation++;
        return;
      }
    }

    final frame =
        carty.allocFrame(width: kf.width, height: kf.height, channels: kf.channels);
    try {
      frame.bytes.setAll(0, kf.image);
      final status = _grid.accreteFromFrame(
        frame: frame,
        width: kf.width,
        height: kf.height,
        channels: kf.channels,
        intrinsics: kf.intrinsics,
        pose: kf.pose.toPoseMatrix(),
        keyframeId: kf.pose.t,
      );
      switch (status) {
        case CartyFuseStatus.ok:
          _accreted++;
          _lastFoldX = kf.pose.tx;
          _lastFoldY = kf.pose.ty;
          _lastFoldZ = kf.pose.tz;
          _lastFoldId = kf.pose.t;
          _camera = _markerFromPose(kf.pose.toPoseMatrix());
          heatmap.value = _snapshot(); // grid changed → publish a new snapshot
        case CartyFuseStatus.duplicate:
          _duplicate++;
        case CartyFuseStatus.outOfBounds:
          _outOfBounds++;
        case CartyFuseStatus.seenFull:
          _seenFull++;
      }
    } finally {
      frame.dispose();
    }
  }

  void _refreshAccuracy(TrackingState current) {
    final tracked =
        _window.where((s) => s == TrackingState.tracking).length;
    accuracy.value = deriveAccuracy(
      mode: CaptureMode.arcoreVio,
      tracking: current,
      recentTrackingFrames: tracked,
      recentTotalFrames: _window.length,
    );
  }

  /// Copy the live grid into an immutable [OccupancyHeatmap]. The copy is what
  /// makes value-equality (and thus `shouldRepaint`/`ValueNotifier`) meaningful:
  /// the bridge mutates `cells`/`color` IN PLACE, so two snapshots over the live
  /// buffers would always compare equal and the UI would never repaint. The
  /// color photo-map is copied alongside the log-odds so the painter draws the
  /// real observed floor color, not a flat blue.
  OccupancyHeatmap _snapshot() => OccupancyHeatmap(
        cells: Int8List.fromList(_grid.cells),
        n: _grid.n,
        h: _grid.h,
        color: Uint8List.fromList(_grid.color),
        camera: _camera,
      );

  /// The camera's grid cell + heading for the live "you are here" marker, derived
  /// from the SAME world→cell mapping the native splat uses (carty_fusion.cpp:
  /// `gx=(camX-originX)/res`, `gy=(camZ-originZorigin)/res`) so the marker lands
  /// on the cells it actually painted. Heading mirrors native `pose_yaw`: project
  /// the camera-forward axis (−3rd column) onto the world X-Z plane, falling back
  /// to the right axis when forward is near-vertical — the camera is pitched down,
  /// so a naive atan2 is unstable. Returns the angle in grid space (0 = +gx,
  /// toward +gy), matching the painter's arrow convention.
  CameraMarker _markerFromPose(List<double> pose) {
    final origin = _grid.origin;
    final res = _grid.resolution.resM;
    final camX = pose[3], camZ = pose[11];
    final gx = (camX - origin.x) / res;
    final gy = (camZ - origin.y) / res;

    final fx = -pose[2], fz = -pose[10]; // camera forward on world X-Z
    final double theta;
    if (math.sqrt(fx * fx + fz * fz) >= 1e-9) {
      theta = math.atan2(fx, fz);
    } else {
      theta = math.atan2(pose[0], pose[8]) + math.pi / 2; // right axis fallback
    }
    // Grid-forward maps to (sinθ, cosθ) in (gx,gy); the painter draws the arrow
    // toward (cos h, sin h), so h = atan2(cosθ, sinθ).
    final heading = math.atan2(math.cos(theta), math.sin(theta));
    return CameraMarker(gx: gx, gy: gy, headingRad: heading);
  }

  /// Frees the persistent grid + notifiers deterministically. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    heatmap.dispose();
    accuracy.dispose();
    _grid.dispose();
  }
}
