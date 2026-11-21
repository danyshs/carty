// Live ARCore capture screen — the live integration screen.
// It exists to be the on-device hero surface: the
// user taps Record, walks the space, and watches a live top-down occupancy
// heatmap fill in while an honesty banner NEVER over-claims
// accuracy when tracking is poor. Deleting it would leave the
// recorder (carty/capture channel) unreachable and the live-fusion loop unproven
// on device.
//
// Channel access is behind an injectable CaptureController seam (mirrors
// VideoMapPage's VideoPicker): the default impl drives the native carty/capture
// MethodChannel; the widget test injects a fake so record/stop + the heatmap +
// banner are verified host-side with no device (Tiger Style: test the wiring).
import 'dart:async';
import 'dart:typed_data';

import 'package:carty/capture.dart';
import 'package:carty/carty.dart';
import 'package:carty/render.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

/// The native channel contract `{videoPath, sidecarPath, frameCount}` returned
/// by `carty/capture#stopCapture`. A plain value so the seam is trivially fakeable.
class CaptureResult {
  const CaptureResult({
    required this.videoPath,
    required this.sidecarPath,
    required this.frameCount,
  });

  factory CaptureResult.fromMap(Map<Object?, Object?> m) => CaptureResult(
        videoPath: m['videoPath'] as String? ?? '',
        sidecarPath: m['sidecarPath'] as String? ?? '',
        frameCount: (m['frameCount'] as num?)?.toInt() ?? 0,
      );

  final String videoPath;
  final String sidecarPath;
  final int frameCount;
}

/// The record/stop seam. Exists so CapturePage's channel dependency is injectable
/// (the widget test swaps in a fake; production uses [ChannelCaptureController]).
/// `start()` launches the ARCore capture Activity; `stop()` finalizes the files;
/// [keyframes] streams each live keyframe (image + intrinsics + pose + state) so
/// the live fusion loop can fold it.
abstract class CaptureController {
  Future<void> start();
  Future<CaptureResult> stop();

  /// Live per-keyframe stream during a capture. Each event carries the downscaled
  /// camera image + intrinsics + pose-sidecar fields + tracking state. Empty on
  /// controllers that only record (the live loop simply gets nothing to fold).
  Stream<CaptureKeyframe> get keyframes;
}

/// Production controller: drives the native `carty/capture` MethodChannel. The
/// Kotlin side owns the ARCore Session, the OES camera binding, and the
/// video.mp4 + sidecar.ndjson writers; this is the thin Dart end of that seam.
class ChannelCaptureController implements CaptureController {
  static const MethodChannel _channel = MethodChannel('carty/capture');

  /// Per-keyframe push stream from the ARCore capture Activity. The Kotlin side
  /// emits one event per keyframe: image bytes + dims + intrinsics + pose +
  /// state. Decoded into [CaptureKeyframe] for the live fusion loop.
  static const EventChannel _keyframeChannel =
      EventChannel('carty/capture_keyframes');

  @override
  Future<void> start() => _channel.invokeMethod<void>('startCapture');

  @override
  Future<CaptureResult> stop() async {
    final raw =
        await _channel.invokeMapMethod<Object?, Object?>('stopCapture');
    if (raw == null) {
      throw StateError('carty/capture#stopCapture returned null');
    }
    return CaptureResult.fromMap(raw);
  }

  @override
  Stream<CaptureKeyframe> get keyframes => _keyframeChannel
      .receiveBroadcastStream()
      .map((event) => _keyframeFromEvent(event as Map<Object?, Object?>));

  /// Decode one native keyframe event into a [CaptureKeyframe]. The native side
  /// owns the frozen field names; a malformed event is a fatal bridge bug, so a
  /// missing field surfaces as a cast error rather than silent zeros.
  static CaptureKeyframe _keyframeFromEvent(Map<Object?, Object?> e) {
    return CaptureKeyframe(
      pose: PoseSample(
        t: (e['t'] as num).toInt(),
        tx: (e['tx'] as num).toDouble(),
        ty: (e['ty'] as num).toDouble(),
        tz: (e['tz'] as num).toDouble(),
        qx: (e['qx'] as num).toDouble(),
        qy: (e['qy'] as num).toDouble(),
        qz: (e['qz'] as num).toDouble(),
        qw: (e['qw'] as num).toDouble(),
        state: TrackingState.fromName(e['state'] as String),
      ),
      image: e['image'] as Uint8List,
      width: (e['width'] as num).toInt(),
      height: (e['height'] as num).toInt(),
      channels: (e['channels'] as num).toInt(),
      intrinsics: <double>[
        (e['fx'] as num).toDouble(),
        (e['fy'] as num).toDouble(),
        (e['cx'] as num).toDouble(),
        (e['cy'] as num).toDouble(),
      ],
    );
  }
}

class CapturePage extends StatefulWidget {
  const CapturePage({
    super.key,
    this.controller,
    this.initialHeatmap,
    this.liveFusion,
  });

  /// Overrides the record/stop wiring. `null` → [ChannelCaptureController]
  /// (real device path). The widget test injects a fake to drive record/stop
  /// without a device.
  final CaptureController? controller;

  /// Seed heatmap for host tests — lets the widget test pump a synthetic,
  /// already-observed grid so the heatmap render is asserted without a live
  /// fusion loop. `null` in production (the live loop builds it from keyframes).
  final OccupancyHeatmap? initialHeatmap;

  /// The live fusion loop. When non-null the page binds the heatmap +
  /// honesty banner to it and folds each streamed keyframe; when null the page is
  /// display-only (the Task-6 path: record + the seeded/empty heatmap). Production
  /// injects `LiveFusionController(Carty.instance)`; host tests inject one over the
  /// host bridge .so. Kept injectable so `Carty.instance` (which dlopens the
  /// platform lib) is never reached in a host widget test.
  final LiveFusionController? liveFusion;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  late final CaptureController _controller =
      widget.controller ?? ChannelCaptureController();

  // Honest empty heatmap before any keyframe lands: n=0 renders the "walk the
  // space" hint, never fabricated geometry.
  final ValueNotifier<OccupancyHeatmap> _heatmap =
      ValueNotifier<OccupancyHeatmap>(
    OccupancyHeatmap(cells: Int8List(0), n: 0, h: 1),
  );

  // The live fusion loop, if any. Injected (tests / explicit) → not owned here;
  // built from Carty.instance on the production device path → owned + disposed.
  LiveFusionController? _live;
  bool _ownsLive = false;

  // Live keyframe subscription, active only between Record and Stop.
  StreamSubscription<CaptureKeyframe>? _kfSub;

  bool _recording = false;
  bool _busy = false;
  CaptureResult? _lastResult;
  Object? _error;

  // Live tracking health window (drives the honesty banner). The Kotlin Activity
  // streams per-keyframe state events in the device path; until those land the
  // banner reflects whatever the most recent window holds (starts DEGRADED — the
  // honest default before any TRACKING frame is seen).
  TrackingState _tracking = TrackingState.paused;
  int _recentTrackingFrames = 0;
  int _recentTotalFrames = 0;

  @override
  void initState() {
    super.initState();
    if (widget.liveFusion != null) {
      // Injected live loop (tests): the page binds to it but does not own it.
      _live = widget.liveFusion;
      return;
    }
    if (widget.initialHeatmap != null) {
      // Display-only seeded path (Task-6 host test): no live loop.
      _heatmap.value = widget.initialHeatmap!;
      _tracking = TrackingState.tracking;
      _recentTrackingFrames = 30;
      _recentTotalFrames = 30;
      return;
    }
    // Production device path: own a live loop over the platform bridge. Reached
    // only here (never in host widget tests, which pass liveFusion/initialHeatmap)
    // so Carty.instance's dlopen of the platform .so never runs under flutter test.
    _live = LiveFusionController(Carty.instance);
    _ownsLive = true;
  }

  @override
  void dispose() {
    _kfSub?.cancel();
    _heatmap.dispose();
    // Dispose only a live loop the page itself created; an injected one is owned
    // by the injector (test).
    if (_ownsLive) _live?.dispose();
    super.dispose();
  }

  /// Live accuracy banner level — never HIGH while tracking is poor (honest
  /// degradation). Pure delegation to the logic core so the
  /// over-claim rule has exactly one home.
  AccuracyLevel get _accuracy => deriveAccuracy(
        mode: CaptureMode.arcoreVio,
        tracking: _tracking,
        recentTrackingFrames: _recentTrackingFrames,
        recentTotalFrames: _recentTotalFrames,
      );

  Future<void> _record() async {
    if (_busy || _recording) return;
    setState(() {
      _busy = true;
      _error = null;
      _lastResult = null;
    });
    try {
      await _controller.start();
      // Fold each live keyframe into the persistent grid. The device
      // path streams real ARCore frames; display-only mode has no live loop.
      final live = _live;
      if (live != null) {
        _kfSub = _controller.keyframes.listen(live.onKeyframe);
      }
      if (!mounted) return;
      setState(() => _recording = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (_busy || !_recording) return;
    setState(() => _busy = true);
    try {
      await _kfSub?.cancel();
      _kfSub = null;
      final result = await _controller.stop();
      if (!mounted) return;
      setState(() {
        _recording = false;
        _lastResult = result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Carty — Live capture')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildBanner(),
            const SizedBox(height: 12),
            Expanded(child: _buildHeatmap()),
            const SizedBox(height: 12),
            _buildControls(),
            if (_lastResult != null) ...[
              const SizedBox(height: 12),
              _buildResult(_lastResult!),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text('Error: $_error',
                  style: TextStyle(
                      fontSize: 12, color: Colors.red.shade700)),
            ],
          ],
        ),
      ),
    );
  }

  /// The honesty banner, bound to the live loop's accuracy when present (so it
  /// reflects real ARCore health frame-by-frame), else the display-only level.
  Widget _buildBanner() {
    final live = _live;
    if (live == null) return _AccuracyBanner(level: _accuracy);
    return ValueListenableBuilder<AccuracyLevel>(
      valueListenable: live.accuracy,
      builder: (context, level, _) => _AccuracyBanner(level: level),
    );
  }

  Widget _buildHeatmap() {
    final live = _live;
    final listenable = live?.heatmap ?? _heatmap;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ValueListenableBuilder<OccupancyHeatmap>(
        valueListenable: listenable,
        builder: (context, heatmap, _) {
          return CustomPaint(
            painter: OccupancyHeatmapPainter(heatmap),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }

  Widget _buildControls() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: _recording || _busy ? null : _record,
          icon: const Icon(Icons.fiber_manual_record),
          label: const Text('Record'),
        ),
        OutlinedButton.icon(
          onPressed: _recording && !_busy ? _stop : null,
          icon: const Icon(Icons.stop),
          label: const Text('Stop'),
        ),
        if (_busy)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildResult(CaptureResult r) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF11151C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(
        'video    ${r.videoPath}\n'
        'sidecar  ${r.sidecarPath}\n'
        'frames   ${r.frameCount}',
        style: const TextStyle(
            fontFamily: 'monospace', fontSize: 12, color: Colors.white70),
      ),
    );
  }
}

/// The honesty banner. A coloured strip whose text is driven SOLELY by
/// [deriveAccuracy]: green only for HIGH, amber for LOW/DEGRADED. It is
/// the demo's over-claim insurance — the banner can never say HIGH while VIO is
/// failing.
class _AccuracyBanner extends StatelessWidget {
  const _AccuracyBanner({required this.level});

  final AccuracyLevel level;

  @override
  Widget build(BuildContext context) {
    final bool high = level == AccuracyLevel.high;
    final Color bg = high ? const Color(0xFF1B5E20) : const Color(0xFF8C5A00);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(high ? Icons.gps_fixed : Icons.gps_not_fixed,
              size: 18, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Accuracy: ${level.bannerText}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
