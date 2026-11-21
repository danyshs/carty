import 'package:material_ui/material_ui.dart';

import 'android_spike_page.dart';
import 'capture_page.dart';
import 'model_downloader.dart';
import 'video_file_picker.dart';
import 'video_map_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // MyApp's ONLY job is to install the MaterialApp. All screen state lives
    // below it — so showDialog and Navigator can find the Material ancestors
    // they require. (Putting that state in the same widget that builds
    // MaterialApp gives callbacks a context ABOVE MaterialApp → "No
    // MaterialLocalizations found".)
    return MaterialApp(
      title: 'Carty',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.light,
        ),
      ),
      home: const HomePage(),
    );
  }
}

/// The PRODUCT face — what a non-technical user sees. One branded screen with a
/// single big primary action. No developer jargon, no diagnostics. The dev /
/// diagnostic surfaces (model download, Video→Map harness, the on-device decode
/// spike) live in [DeveloperPage], reachable ONLY by long-pressing the title —
/// a deliberately hidden affordance. (Once the capture→map pipeline ships, that
/// escape hatch moves behind the app icon.)
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _openDeveloperTools(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DeveloperPage()),
    );
  }

  void _makeAMap(BuildContext context) {
    // Honest pre-release behaviour: the real Scan→Map flow (ARCore capture →
    // voxel fusion → vectorize → D&D render) is the product surface
    // and does not exist yet. Don't fake a scan — take the user to a warm
    // "coming soon" screen instead.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ComingSoonPage(
          headline: 'Carty is still learning to see',
          message: "Soon you'll be able to record a room and watch Carty draw "
              "its map. We're building that now — check back shortly.",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              Icon(Icons.map_rounded, size: 96, color: scheme.primary),
              const SizedBox(height: 20),
              // The wordmark IS the hidden developer-tools affordance: a long
              // press opens the diagnostics page. No visual hint by design.
              GestureDetector(
                onLongPress: () => _openDeveloperTools(context),
                child: Text(
                  'Carty',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Turn a video of any room into a\nbeautiful overhead map.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const Spacer(flex: 4),
              FilledButton.icon(
                onPressed: () => _makeAMap(context),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Make a map'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(64),
                  textStyle: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}

/// Honest placeholder for a not-yet-built stage — warm, on-brand, and making no
/// false promise of working functionality. Used both for the product "Make a
/// map" button and for every not-yet-wired developer stage.
///
/// It LOGS on entry (`initState`): because each non-working button routes to its
/// OWN ComingSoonPage with a distinct title, the dev log shows unambiguously
/// which flow the user reached (honest degradation + observability).
class ComingSoonPage extends StatefulWidget {
  const ComingSoonPage({
    super.key,
    required this.headline,
    required this.message,
    this.appBarTitle,
    this.icon = Icons.construction_rounded,
  });

  /// Big on-screen headline.
  final String headline;

  /// Supporting copy under the headline.
  final String message;

  /// AppBar title. Null → a blank bar (used for the polished product face so no
  /// dev-ish title shows). Non-null → shown in the bar (dev stages).
  final String? appBarTitle;
  final IconData icon;

  @override
  State<ComingSoonPage> createState() => _ComingSoonPageState();
}

class _ComingSoonPageState extends State<ComingSoonPage> {
  @override
  void initState() {
    super.initState();
    // Where did we enter? One log line per stage, greppable in logcat.
    debugPrint(
        '[Carty][nav] coming-soon: ${widget.appBarTitle ?? widget.headline}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: widget.appBarTitle == null ? null : Text(widget.appBarTitle!),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 80, color: scheme.primary),
              const SizedBox(height: 24),
              Text(
                widget.headline,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                widget.message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// DEVELOPER / DIAGNOSTIC surface — intentionally hidden from the product face
/// (reached via a long-press of the home title). Holds everything an end user
/// should never see: the raw model downloader, the Video→Map harness, and the
/// On-device decode spike. Not for shipping.
class DeveloperPage extends StatefulWidget {
  const DeveloperPage({super.key});

  @override
  State<DeveloperPage> createState() => _DeveloperPageState();
}

class _DeveloperPageState extends State<DeveloperPage> {
  // --- Model acquisition (Gemma 4 E2B .litertlm) ---
  final ModelDownloader _downloader = ModelDownloader();
  // Generic build is the safe default (runs on any arm64 Android). The
  // SoC-accelerated variants in GemmaModels.all are faster on matching
  // hardware; expose a picker later if desired.
  final GemmaModelSpec _model = GemmaModels.generic;
  ModelState _modelState = ModelState.notInstalled;
  double _progress = 0;

  /// Resolved on-device path the model lives at (or will live at). Surfaced in
  /// the UI so the user can confirm there is exactly one copy, in a real place —
  /// not a phantom path. Null until resolved; an error string if the platform
  /// directory can't be resolved.
  String? _modelPath;

  @override
  void initState() {
    super.initState();
    _refreshModelState();
  }

  Future<void> _refreshModelState() async {
    // isPresent + modelPath both touch the platform documents/support dir,
    // which can throw on a misconfigured desktop (MissingPlatformDirectory).
    // Resolve defensively so the card degrades to a visible message instead of
    // an unhandled async exception.
    String? path;
    var present = false;
    try {
      path = await _downloader.modelPath(_model);
      present = await _downloader.isPresent(_model);
    } catch (e) {
      path = 'Path unavailable on this platform: $e';
    }
    if (!mounted) return;
    setState(() {
      _modelState = present ? ModelState.installed : ModelState.notInstalled;
      _modelPath = path;
    });
  }

  Future<void> _deleteModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete downloaded model?'),
        content: Text(
          'This removes the on-device model file. You can re-download it '
          'later.\n\n${_modelPath ?? ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _downloader.delete(_model);
    await _refreshModelState();
    if (mounted) setState(() => _progress = 0);
  }

  Future<void> _startDownload() async {
    await _downloader.download(
      _model,
      onProgress: (f) {
        if (!mounted) return;
        setState(() => _progress = f);
      },
      onState: (s) {
        if (!mounted) return;
        setState(() => _modelState = s);
      },
    );
  }

  /// Routes a not-yet-wired stage to its OWN logging [ComingSoonPage], so the
  /// dev log records exactly which flow was entered.
  void _openComingSoon({
    required String title,
    required String message,
    required IconData icon,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComingSoonPage(
          appBarTitle: title,
          headline: title,
          message: message,
          icon: icon,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Developer tools')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ModelCard(
              model: _model,
              state: _modelState,
              progress: _progress,
              modelPath: _modelPath,
              onDownload: _startDownload,
              onPause: () => _downloader.pause(),
              onResume: () => _downloader.resume(),
              onDelete: _deleteModel,
              onCancel: () async {
                await _downloader.cancel();
                await _refreshModelState();
                if (mounted) setState(() => _progress = 0);
              },
            ),
            const SizedBox(height: 16),
            // 2A — FIRST-CLASS input: live ARCore capture. The availability +
            // on-device decode spike is the current diagnostic surface; the
            // recorder (video + pose sidecar) is built on top of it.
            _DevSection(
              number: '2A',
              title: 'Live capture (ARCore)',
              description:
                  'First-class input: a live ARCore session — 6-DoF pose, floor '
                  'plane, and video+pose recording. The availability + on-device '
                  'decode spike is the current diagnostic here.',
              buttonIcon: Icons.videocam_outlined,
              buttonLabel: 'Open ARCore spike',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AndroidSpikePage(),
                ),
              ),
            ),
            // the live integration screen: the real
            // capture screen that records video + pose sidecar AND shows the
            // live top-down heatmap with the honesty banner. The spike above is
            // diagnostics; this is the product flow on top of it.
            _DevSection(
              number: '2A-live',
              title: 'Live capture → map (ARCore)',
              description:
                  'Record a live ARCore capture (video + pose sidecar) and watch '
                  'a top-down occupancy map fill in as you walk — with an honest '
                  'accuracy banner that never over-claims when tracking is poor.',
              buttonIcon: Icons.map_outlined,
              buttonLabel: 'Open live capture',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CapturePage(),
                ),
              ),
            ),
            // 2B — THIRD-CLASS input: a pre-recorded clip via the file picker.
            _DevSection(
              number: '2B',
              title: 'Video input (pre-recorded)',
              description:
                  'Third-class input: pick a pre-recorded clip and stream its '
                  'frames through the bridge. Pose-less, so lower fidelity than '
                  'live capture.',
              buttonIcon: Icons.video_file_outlined,
              buttonLabel: 'Open Video → Map',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VideoMapPage(
                    // Resolves from the APK's lib/<abi>/ by name
                    // (native/CMakeLists.txt names the bridge libcarty.so).
                    bridgeLibrary: 'libcarty.so',
                    // Thread the resolved on-device model path into the pipeline
                    // (the downloader's getApplicationSupportDirectory location);
                    // fall back only until it has resolved.
                    modelPath: _modelPath ?? VideoMapPage.fallbackModelPath,
                    // Third-class pre-recorded input: real Android document
                    // picker behind the injectable seam.
                    videoPicker: pickVideoFile,
                  ),
                ),
              ),
            ),
            // 3 — observe every pipeline stage with time + size (NOT built).
            _DevSection(
              number: '3',
              title: 'Pipeline data inspector',
              description:
                  'Observe data at every stage — pre/post-ARCore, pre/post '
                  'overhead map, pre/post beautification — with per-stage '
                  'processing time and data size.',
              buttonIcon: Icons.insights_outlined,
              buttonLabel: 'Open inspector',
              ready: false,
              onPressed: () => _openComingSoon(
                title: 'Pipeline data inspector',
                icon: Icons.insights_outlined,
                message:
                    'A stage-by-stage view of the pipeline — raw frames, ARCore '
                    'pose, voxel volume, overhead map, beautified map — each '
                    'with its processing time and data size, so you can judge '
                    'what every step actually buys us. Being built.',
              ),
            ),
            // 4 — turn the captured data into an overhead map (NOT built).
            _DevSection(
              number: '4',
              title: 'Build overhead map',
              description:
                  'Run fusion + vectorization to turn captured data into an '
                  'overhead MapGraph.',
              buttonIcon: Icons.grid_on_outlined,
              buttonLabel: 'Build map',
              ready: false,
              onPressed: () => _openComingSoon(
                title: 'Build overhead map',
                icon: Icons.grid_on_outlined,
                message:
                    'Voxel-column fusion → classical vectorization → overhead '
                    'MapGraph. This is the product core. Being built.',
              ),
            ),
            // 5 — hand-edit the generated map (NOT built).
            _DevSection(
              number: '5',
              title: 'Map editor',
              description:
                  'Add or remove rooms, walls, doors and details on the '
                  'generated map.',
              buttonIcon: Icons.edit_outlined,
              buttonLabel: 'Open editor',
              ready: false,
              onPressed: () => _openComingSoon(
                title: 'Map editor',
                icon: Icons.edit_outlined,
                message:
                    'Hand-edit the map — add or remove context and detail — on '
                    'top of the version-controlled MapGraph. Being built.',
              ),
            ),
            // 6 — opt-in online community features (NOT built).
            _DevSection(
              number: '6',
              title: 'Community (fork / clone / PR)',
              description:
                  'Opt-in online features: fork, clone, and pull-request maps '
                  'other people have shared.',
              buttonIcon: Icons.public_outlined,
              buttonLabel: 'Open community',
              ready: false,
              onPressed: () => _openComingSoon(
                title: 'Community',
                icon: Icons.public_outlined,
                message:
                    'Git-style sharing of maps — fork, clone, and open pull '
                    'requests against uploaded maps. Additive and opt-in; it '
                    'never gates the offline core flow. Being built.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.state,
    required this.progress,
    required this.modelPath,
    required this.onDownload,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
    required this.onCancel,
  });

  final GemmaModelSpec model;
  final ModelState state;
  final double progress;

  /// Resolved on-device storage path (or an error string), or null while it is
  /// still being resolved. Shown verbatim so the user can confirm the single,
  /// real location of the model file.
  final String? modelPath;
  final VoidCallback onDownload;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  String get _statusLine => switch (state) {
        ModelState.notInstalled => 'Not installed',
        ModelState.downloading =>
          'Downloading… ${(progress * 100).toStringAsFixed(1)}%',
        ModelState.paused =>
          'Paused at ${(progress * 100).toStringAsFixed(1)}%',
        ModelState.verifying => 'Verifying integrity (SHA-256)…',
        ModelState.installed => 'Installed ✓ (verified)',
        ModelState.failed => 'Failed — safe to retry',
      };

  @override
  Widget build(BuildContext context) {
    final busy =
        state == ModelState.downloading || state == ModelState.verifying;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1 · On-device model',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(model.label),
            const SizedBox(height: 4),
            Text(_statusLine),
            const SizedBox(height: 8),
            // Storage path — surfaced so the user can confirm exactly one copy
            // lives at one real place (not a phantom / duplicated path).
            Text('Storage path',
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 2),
            SelectableText(
              modelPath ?? 'Resolving…',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.black87,
              ),
            ),
            Text(
              state == ModelState.installed
                  ? 'File present at this path.'
                  : 'No file here yet — it will be created on download.',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            if (state == ModelState.downloading || state == ModelState.paused)
              LinearProgressIndicator(value: progress == 0 ? null : progress)
            else if (state == ModelState.verifying)
              const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (state == ModelState.notInstalled ||
                    state == ModelState.failed)
                  ElevatedButton(
                    onPressed: onDownload,
                    child: const Text('Download'),
                  ),
                if (state == ModelState.downloading)
                  OutlinedButton(
                    onPressed: onPause,
                    child: const Text('Pause'),
                  ),
                if (state == ModelState.paused)
                  ElevatedButton(
                    onPressed: onResume,
                    child: const Text('Resume'),
                  ),
                if (busy || state == ModelState.paused)
                  OutlinedButton(
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  ),
                if (state == ModelState.installed ||
                    state == ModelState.failed)
                  OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete model'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'One-time download. Keep the app open on weak connections; the '
              'download resumes automatically after drops.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

/// One numbered developer-tools row. The dev page is laid out to MIRROR the
/// product pipeline so diagnostics map onto real user flows:
///   1 model · 2A live capture · 2B video input · 3 inspect · 4 build map ·
///   5 edit · 6 community.
/// Not-yet-wired stages (`ready: false`) still get a button — it routes to a
/// logging [ComingSoonPage] so the dev log records where we entered.
class _DevSection extends StatelessWidget {
  const _DevSection({
    required this.number,
    required this.title,
    required this.description,
    required this.buttonIcon,
    required this.buttonLabel,
    required this.onPressed,
    this.ready = true,
  });

  final String number;
  final String title;
  final String description;
  final IconData buttonIcon;
  final String buttonLabel;
  final VoidCallback onPressed;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      number,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  if (!ready)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Coming soon',
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(description,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: Icon(buttonIcon, size: 18),
                  label: Text(buttonLabel),
                  onPressed: onPressed,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
