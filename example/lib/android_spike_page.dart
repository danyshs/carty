// On-device spike surface.
//
// Two probes, both honest about degradation:
//   1. ARCore availability via the `carty/arcore_spike` MethodChannel
//      (Android only — desktop shows N/A).
//   2. ONE in-process decode through the EXISTING C ABI seam
//      (carty_model_load → carty_ortho_project → carty_infer_map_update_ortho),
//      timed: model load s, decode s, RSS before/after. On Android this returns
//      CARTY_INFER_ENOMODEL (-100) until the in-process LiteRT-LM engine is
//      linked for arm64 — that honest failure still proves the whole
//      Dart→FFI→bridge seam works on-device. On the host, with the LiteRT runtime
//      env vars exported, it runs a REAL ~50 s Gemma decode.
//
// GATE: a decode completes on-device through this seam.
import 'dart:io';
import 'dart:isolate';

import 'package:carty/carty.dart';
import 'package:carty/carty_bindings_generated.dart' show CARTY_INFER_ENOMODEL;
import 'package:carty/inference/prompt.dart' show kMapUpdateSchemaContract;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'model_downloader.dart';

/// Measurement record produced by [_runSeamProbe] in a worker isolate.
class SpikeResult {
  const SpikeResult({
    required this.bridgeVersion,
    required this.loadMs,
    required this.orthoMs,
    required this.decodeMs,
    required this.status,
    required this.outputBytes,
    required this.rssBeforeBytes,
    required this.rssAfterBytes,
  });

  final String bridgeVersion;
  final int loadMs;
  final int orthoMs;
  final int decodeMs;
  final int status;
  final int outputBytes;
  final int rssBeforeBytes;
  final int rssAfterBytes;

  bool get decodeCompleted => status >= 0;
  bool get honestNoModel => status == CARTY_INFER_ENOMODEL;
}

/// Runs the whole probe in a fresh isolate so the synchronous FFI decode
/// (~50 s with real weights) never blocks the UI isolate. The isolate opens its
/// own `Carty.instance` (the bridge .so resolves by name per platform).
Future<SpikeResult> _runSeamProbe(String modelPath) {
  return Isolate.run(() {
    final carty = Carty.instance;
    final rssBefore = ProcessInfo.currentRss;

    final loadWatch = Stopwatch()..start();
    final model = carty.loadModel(modelPath);
    loadWatch.stop();

    const dim = 64;
    final frame = carty.allocFrame(width: dim, height: dim, channels: 4);
    CartyOrthoMapHandle? ortho;
    try {
      // A deterministic synthetic gradient — enough signal for the geometric
      // stage; the spike measures the seam, not map quality.
      final pixels = frame.bytes;
      for (var y = 0; y < dim; y++) {
        for (var x = 0; x < dim; x++) {
          final i = (y * dim + x) * 4;
          pixels[i] = (x * 4) & 0xFF;
          pixels[i + 1] = (y * 4) & 0xFF;
          pixels[i + 2] = ((x + y) * 2) & 0xFF;
          pixels[i + 3] = 0xFF;
        }
      }

      final orthoWatch = Stopwatch()..start();
      ortho = carty.orthoProject(frame, width: dim, height: dim, channels: 4);
      orthoWatch.stop();

      final decodeWatch = Stopwatch()..start();
      final inference = model.inferMapUpdateOrtho(
        ortho,
        instruction: kMapUpdateSchemaContract,
      );
      decodeWatch.stop();

      return SpikeResult(
        bridgeVersion: carty.version,
        loadMs: loadWatch.elapsedMilliseconds,
        orthoMs: orthoWatch.elapsedMilliseconds,
        decodeMs: decodeWatch.elapsedMilliseconds,
        status: inference.status,
        outputBytes: inference.text.length,
        rssBeforeBytes: rssBefore,
        rssAfterBytes: ProcessInfo.currentRss,
      );
    } finally {
      ortho?.dispose();
      frame.dispose();
      model.dispose();
    }
  });
}

class AndroidSpikePage extends StatefulWidget {
  const AndroidSpikePage({super.key});

  @override
  State<AndroidSpikePage> createState() => _AndroidSpikePageState();
}

/// One ARCore frame snapshot returned by the `startPoseProbe` channel call.
class PoseSnapshot {
  const PoseSnapshot({
    required this.trackingState,
    required this.tx,
    required this.ty,
    required this.tz,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.qw,
    required this.floorPlaneTracked,
    required this.floorY,
  });

  factory PoseSnapshot.fromMap(Map<Object?, Object?> m) => PoseSnapshot(
        trackingState: m['trackingState'] as String? ?? '?',
        tx: (m['tx'] as num?)?.toDouble() ?? 0,
        ty: (m['ty'] as num?)?.toDouble() ?? 0,
        tz: (m['tz'] as num?)?.toDouble() ?? 0,
        qx: (m['qx'] as num?)?.toDouble() ?? 0,
        qy: (m['qy'] as num?)?.toDouble() ?? 0,
        qz: (m['qz'] as num?)?.toDouble() ?? 0,
        qw: (m['qw'] as num?)?.toDouble() ?? 1,
        floorPlaneTracked: m['floorPlaneTracked'] as bool? ?? false,
        floorY: (m['floorY'] as num?)?.toDouble() ?? 0,
      );

  final String trackingState;
  final double tx, ty, tz;
  final double qx, qy, qz, qw;
  final bool floorPlaneTracked;
  final double floorY;
}

class _AndroidSpikePageState extends State<AndroidSpikePage> {
  static const _arChannel = MethodChannel('carty/arcore_spike');

  final ModelDownloader _downloader = ModelDownloader();
  final GemmaModelSpec _model = GemmaModels.generic;

  String _arAvailability = Platform.isAndroid ? 'checking…' : 'N/A (not Android)';
  String? _modelPath;
  bool _modelPresent = false;
  bool _running = false;
  SpikeResult? _result;
  Object? _error;

  // Pose probe state.
  bool _poseRunning = false;
  List<PoseSnapshot>? _poseSnapshots;
  Object? _poseError;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) _pollArAvailability();
    _resolveModel();
  }

  Future<void> _pollArAvailability() async {
    // checkAvailability can answer UNKNOWN_CHECKING while Play Services warms
    // up; re-poll a bounded number of times (Tiger Style: bounded loops).
    for (var attempt = 0; attempt < 10; attempt++) {
      String value;
      try {
        value =
            await _arChannel.invokeMethod<String>('availability') ?? 'null';
      } on PlatformException catch (e) {
        value = 'error: ${e.code}';
      }
      if (!mounted) return;
      setState(() => _arAvailability = value);
      if (value != 'UNKNOWN_CHECKING') return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _requestArInstall() async {
    try {
      final status = await _arChannel.invokeMethod<String>('requestInstall');
      if (!mounted) return;
      setState(() => _arAvailability = 'install: $status');
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _arAvailability = 'install error: ${e.code}');
    }
    await _pollArAvailability();
  }

  Future<void> _startPoseProbe() async {
    if (_poseRunning || !Platform.isAndroid) return;
    setState(() {
      _poseRunning = true;
      _poseSnapshots = null;
      _poseError = null;
    });
    try {
      final raw = await _arChannel.invokeMethod<List<Object?>>(
        'startPoseProbe',
        <String, Object?>{'maxFrames': 30},
      );
      final snapshots = (raw ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map(PoseSnapshot.fromMap)
          .toList();
      if (!mounted) return;
      setState(() => _poseSnapshots = snapshots);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _poseError = '${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _poseError = e);
    } finally {
      if (mounted) setState(() => _poseRunning = false);
    }
  }

  Future<void> _resolveModel() async {
    try {
      final path = await _downloader.modelPath(_model);
      final present = await _downloader.isPresent(_model);
      if (!mounted) return;
      setState(() {
        _modelPath = path;
        _modelPresent = present;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modelPath = null;
        _modelPresent = false;
        _error = e;
      });
    }
  }

  Future<void> _runProbe() async {
    final path = _modelPath;
    if (path == null || _running) return;
    setState(() {
      _running = true;
      _result = null;
      _error = null;
    });
    try {
      final result = await _runSeamProbe(path);
      if (!mounted) return;
      setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  List<Widget> _buildPoseResults() {
    final snaps = _poseSnapshots!;
    if (snaps.isEmpty) {
      return [
        const SizedBox(height: 8),
        const Text('No snapshots returned.',
            style: TextStyle(fontSize: 12, color: Colors.orange)),
      ];
    }
    final tracked =
        snaps.where((s) => s.trackingState == 'TRACKING').length;
    final floorFrames = snaps.where((s) => s.floorPlaneTracked).length;
    final last = snaps.last;
    PoseSnapshot? floorSnap;
    for (final s in snaps.reversed) {
      if (s.floorPlaneTracked) { floorSnap = s; break; }
    }
    return [
      const SizedBox(height: 12),
      Text(
        'frames:  ${snaps.length}\n'
        'TRACKING: $tracked / ${snaps.length}\n'
        'floor plane seen: $floorFrames / ${snaps.length}'
        '${floorSnap != null ? " (Y=${floorSnap.floorY.toStringAsFixed(3)} m)" : ""}\n'
        '\nlast frame:\n'
        '  state  ${last.trackingState}\n'
        '  t      (${last.tx.toStringAsFixed(3)}, '
        '${last.ty.toStringAsFixed(3)}, ${last.tz.toStringAsFixed(3)}) m\n'
        '  q      (${last.qx.toStringAsFixed(3)}, '
        '${last.qy.toStringAsFixed(3)}, ${last.qz.toStringAsFixed(3)}, '
        '${last.qw.toStringAsFixed(3)})',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
      const SizedBox(height: 8),
      Text(
        tracked > 0
            ? 'GATE EVIDENCE: live 6-DoF pose received on-device via ARCore Session.'
            : 'Session ran but no TRACKING frames — move the device and retry.',
        style: TextStyle(
          fontSize: 12,
          color: tracked > 0 ? Colors.green.shade700 : Colors.orange.shade800,
        ),
      ),
    ];
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Device spike')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ARCore (pose / VIO)',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text('Availability: $_arAvailability',
                        style: const TextStyle(fontFamily: 'monospace')),
                    if (Platform.isAndroid &&
                        (_arAvailability == 'SUPPORTED_NOT_INSTALLED' ||
                            _arAvailability == 'SUPPORTED_APK_TOO_OLD')) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _requestArInstall,
                        child: const Text('Install / update ARCore'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // --- Pose probe card ---
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('6-DoF pose + floor plane probe',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    const Text(
                      'Opens a real ARCore Session (EGL pbuffer, no visible surface) '
                      'and collects 30 live pose updates. Gate evidence for the capture work.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    if (Platform.isAndroid)
                      FilledButton.icon(
                        icon: _poseRunning
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sensors),
                        label: Text(_poseRunning
                            ? 'Collecting 30 frames…'
                            : 'Start pose probe (30 frames)'),
                        onPressed: _poseRunning ? null : _startPoseProbe,
                      )
                    else
                      const Text('N/A — Android only',
                          style: TextStyle(fontSize: 12)),
                    if (_poseSnapshots != null) ..._buildPoseResults(),
                    if (_poseError != null) ...[
                      const SizedBox(height: 8),
                      Text('Error: $_poseError',
                          style: TextStyle(
                              fontSize: 12, color: Colors.red.shade700)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('One decode through the FFI seam',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Model: ${_modelPath ?? "(unresolved)"}\n'
                      'Present: $_modelPresent',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      icon: _running
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bolt),
                      label: Text(_running
                          ? 'Running (a real decode takes ~a minute)…'
                          : 'Load model + run ONE decode'),
                      onPressed:
                          _modelPath == null || _running ? null : _runProbe,
                    ),
                    if (result != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        'bridge   ${result.bridgeVersion}\n'
                        'load     ${result.loadMs} ms\n'
                        'ortho    ${result.orthoMs} ms\n'
                        'decode   ${result.decodeMs} ms\n'
                        'status   ${result.status}'
                        '${result.honestNoModel ? "  (ENOMODEL — runtime not linked on this platform yet; seam itself OK)" : ""}\n'
                        'output   ${result.outputBytes} bytes\n'
                        'rss      ${_mb(result.rssBeforeBytes)} → ${_mb(result.rssAfterBytes)} MB',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        result.decodeCompleted
                            ? 'GATE EVIDENCE: a decode completed through the '
                                'existing C ABI seam on this device.'
                            : 'Seam exercised end-to-end; decode degraded '
                                'honestly (no in-process runtime linked here).',
                        style: TextStyle(
                          fontSize: 12,
                          color: result.decodeCompleted
                              ? Colors.green.shade700
                              : Colors.orange.shade800,
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text('Error: $_error',
                          style: TextStyle(
                              fontSize: 12, color: Colors.red.shade700)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
