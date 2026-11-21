// Video → Map page: select a local video, stream its frames through the
// Carty bridge on a background isolate, and watch the spatial MapGraph grow.
//
// File selection is an injectable seam (VideoPicker). No platform picker is
// wired yet — the Android SAF document picker is the planned implementation;
// until then the typed-path field is the working input. (The old desktop
// zenity picker was removed 2026-06-12 with the Linux desktop runner: Carty
// never runs as a desktop app; pre-recorded video input is exercised on
// device / the eventual Android emulator instead.)
//
// HONEST degraded behaviour: where libcarty.so is built without a linked
// LiteRT runtime, inference safe-fails ENOMODEL and the live map stays empty
// while every frame still reaches the bridge. The status log shows that
// plainly. With real weights, nodes appear with no UI change.
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:carty/vc.dart';
import 'package:carty/video.dart';

/// Picks a video file, returning its absolute path or `null` if the user
/// cancelled / no path was chosen. Injected so the button→picker wiring is
/// testable without spawning a real OS dialog (Tiger Style: test the wiring).
typedef VideoPicker = Future<String?> Function();

/// Starts the video→map pipeline for [videoPath] and returns its event stream.
/// Injected so the "Reconstruct map" button's wiring is testable without
/// spawning a real background isolate / FFI bridge (Tiger Style: test the
/// wiring, not the OS). `null` → [_defaultPipelineRunner], the real
/// [VideoToMapPipeline].
typedef PipelineRunner = Stream<PipelineEvent> Function(String videoPath);

class VideoMapPage extends StatefulWidget {
  const VideoMapPage({
    super.key,
    required this.bridgeLibrary,
    this.modelPath = fallbackModelPath,
    this.videoPicker,
    this.pipelineRunner,
  });

  /// Last-resort model path when the caller does not thread the resolved
  /// on-device path (the model downloader's `getApplicationSupportDirectory`
  /// location). Real builds pass the resolved path; this only keeps host/dev
  /// runs constructible.
  static const String fallbackModelPath = '/tmp/gemma4_e2b.litertlm';

  /// Bridge `.so` to load in the pipeline isolate. On a packaged desktop build
  /// this is `libcarty.so`; for source/dev runs point it at the host build.
  final String bridgeLibrary;

  /// Absolute path to the on-device Gemma model the pipeline isolate loads.
  /// Injected (not hard-wired) so the resolved per-platform path flows in from
  /// the caller and the page stays free of platform path assumptions.
  final String modelPath;

  /// Overrides how a video path is obtained. `null` → `_noPlatformPicker`
  /// (no picker wired yet; Android SAF picker pending). Tests inject a fake
  /// to verify the "Choose video file" button actually reaches the picker.
  final VideoPicker? videoPicker;

  /// Overrides how the pipeline is started. `null` → the real
  /// [VideoToMapPipeline]. Tests inject a fake to verify the "Reconstruct map"
  /// button drives the page off a controlled event stream.
  final PipelineRunner? pipelineRunner;

  @override
  State<VideoMapPage> createState() => _VideoMapPageState();
}

class _VideoMapPageState extends State<VideoMapPage> {
  final TextEditingController _pathController = TextEditingController();
  final ValueNotifier<MapGraph> _graph =
      ValueNotifier<MapGraph>(MapGraph.empty());
  final List<String> _log = <String>[];

  StreamSubscription<PipelineEvent>? _subscription;
  bool _running = false;
  bool _picking = false;

  /// True while a (multi-second) grid-conditioned Gemma decode is actively
  /// running in the background isolate — drives the loading overlay.
  bool _isProcessing = false;
  int _processed = 0;
  int _dropped = 0;

  @override
  void dispose() {
    _subscription?.cancel();
    _pathController.dispose();
    _graph.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    setState(() {
      _log.insert(0, line);
      if (_log.length > 200) _log.removeLast(); // bounded log
    });
  }

  /// "Choose video file" button handler. Drives UI state (`_picking` spinner),
  /// delegates the actual path selection to the injected picker, then stores
  /// the result. Logs unconditionally so the button→picker→result path is
  /// fully observable in the in-app panel.
  Future<void> _pickVideo() async {
    setState(() => _picking = true);
    _appendLog('Choose-video tapped → invoking picker…');
    try {
      final picker = widget.videoPicker ?? _noPlatformPicker;
      final path = await picker();
      if (path != null && path.isNotEmpty) {
        _pathController.text = path;
        _appendLog('Selected video: $path');
      } else {
        _appendLog('No video chosen (cancelled or empty).');
      }
    } catch (e) {
      _appendLog('File chooser error: $e. Type the path manually instead.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Default picker: no platform file picker is wired yet. The Android SAF
  /// document picker is the planned implementation behind this same seam; the
  /// typed-path field below is the working fallback until then.
  Future<String?> _noPlatformPicker() async {
    _appendLog('No platform file picker wired yet (Android SAF picker '
        'pending) — type the video path in the field below.');
    return null;
  }

  /// The real pipeline behind the [PipelineRunner] seam: spawns the background
  /// isolate that loads the bridge and folds frames. Tuning (frame size, fps
  /// cap, frame ceiling) lives here so the seam stays a one-argument contract.
  Stream<PipelineEvent> _defaultPipelineRunner(String path) =>
      VideoToMapPipeline().run(
        videoPath: path,
        modelPath: widget.modelPath,
        bridgeLibrary: widget.bridgeLibrary,
        targetWidth: 224,
        targetHeight: 224,
        // Decode smoothly up to the 20fps cap; the isolate throttle drops frames
        // that arrive while a (tens-of-seconds) grid-conditioned decode runs.
        sampleFps: VideoToMapPipeline.kMaxSampleFps,
        maxFrames: 64,
      );

  void _start() {
    final path = _pathController.text.trim();
    if (path.isEmpty) {
      _appendLog('No video selected — click "Choose video file" or type a path.');
      return;
    }
    if (!File(path).existsSync()) {
      _appendLog('File not found: $path');
      return;
    }

    // Reset for a fresh run.
    _subscription?.cancel();
    _graph.value = MapGraph.empty();
    setState(() {
      _running = true;
      _isProcessing = false;
      _processed = 0;
      _dropped = 0;
      _log.clear();
    });
    _appendLog('Started pipeline on background isolate → $path');

    final runner = widget.pipelineRunner ?? _defaultPipelineRunner;
    final stream = runner(path);

    _subscription = stream.listen(
      (event) {
        switch (event) {
          case PipelineProcessing():
            setState(() => _isProcessing = event.isProcessing);
          case PipelineFrame():
            _graph.value = event.graph; // live repaint via ValueListenable
            setState(() {
              _processed = event.processed;
              _dropped = event.dropped;
            });
            _appendLog('frame ${event.index}: '
                'status ${event.status} — ${event.note}');
          case PipelineDone():
            _graph.value = event.graph;
            setState(() {
              _running = false;
              _isProcessing = false;
            });
            _appendLog('Done: ${event.frameCount} frames, '
                '${event.graph.nodeCount} nodes committed.');
          case PipelineFailed():
            setState(() {
              _running = false;
              _isProcessing = false;
            });
            _appendLog('Pipeline error: ${event.message}');
        }
      },
      onDone: () {
        if (mounted) {
          setState(() {
            _running = false;
            _isProcessing = false;
          });
        }
      },
    );
  }

  void _stop() {
    _subscription?.cancel();
    _subscription = null;
    setState(() {
      _running = false;
      _isProcessing = false;
    });
    _appendLog('Stopped.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Carty — Video → Map')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildControls(),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _buildMapView()),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _buildLog()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    final theme = Theme.of(context);
    // A prominent, self-explanatory "insert a video" card. The earlier UI was a
    // bare TextField a user could miss entirely: the
    // primary affordance is the "Choose video file" button (picker seam; SAF
    // picker pending), with a typed-path field as the working manual input —
    // both styled and impossible to overlook here.
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.video_file_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Select a video',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            // Reactive status banner driven by the path field itself. Empty →
            // a loud "No Video Loaded" prompt; populated → a clear confirmation.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _pathController,
              builder: (context, value, _) {
                final path = value.text.trim();
                final hasPath = path.isNotEmpty;
                final Color bg = hasPath
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.errorContainer;
                final Color fg = hasPath
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onErrorContainer;
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        hasPath
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        size: 18,
                        color: fg,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          hasPath
                              ? 'Video selected: $path'
                              : 'No video loaded. Click "Choose video file" to '
                                  'pick a recording (or type a local path below).',
                          style: TextStyle(
                              color: fg, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pathController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Local video file path',
                hintText: '/path/to/recording.mp4',
                prefixIcon: const Icon(Icons.folder_open),
                filled: true,
                border: const OutlineInputBorder(),
                enabledBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.black26),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                      color: theme.colorScheme.primary, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Primary "insert a video" action: opens a native file dialog.
                // First-class so it can't be overlooked.
                FilledButton.tonalIcon(
                  onPressed: _running || _picking ? null : _pickVideo,
                  icon: _picking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.folder_open),
                  label: const Text('Choose video file'),
                ),
                FilledButton.icon(
                  onPressed: _running ? null : _start,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Reconstruct map'),
                ),
                OutlinedButton.icon(
                  onPressed: _running ? _stop : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
                if (_running)
                  Chip(
                    avatar: _isProcessing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.hourglass_empty, size: 16),
                    label: Text('$_processed processed · $_dropped dropped'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapView() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<MapGraph>(
            valueListenable: _graph,
            builder: (context, graph, _) {
              return CustomPaint(
                painter: MapGraphPainter(graph),
                child: const SizedBox.expand(),
              );
            },
          ),
          // Loading overlay: shown while a grid-conditioned Gemma decode is
          // actively running in the background isolate. The map underneath keeps
          // the nodes already accreted; new nodes land when the decode returns.
          if (_isProcessing)
            const _AnalyzingOverlay(),
        ],
      ),
    );
  }

  Widget _buildLog() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF11151C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('Pipeline log (newest first)',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  _log[i],
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Translucent "Analyzing Geometry…" scrim shown over the map canvas while a
/// grid-conditioned Gemma decode is running in the background isolate.
class _AnalyzingOverlay extends StatelessWidget {
  const _AnalyzingOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xCC0B0E14),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(height: 14),
            Text(
              'Analyzing Geometry…',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'on-device Gemma decode • frames throttled',
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
