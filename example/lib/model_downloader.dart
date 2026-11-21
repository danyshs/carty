// model_downloader.dart — on-device acquisition of the Gemma 4 E2B model.
//
// CONTEXT (local-first): inference and storage stay on device.
// A model still has to GET onto the device once. That ONE-TIME provisioning
// download is the sanctioned network exception: after it completes, the
// .litertlm file lives in app-private storage and nothing else leaves the
// machine. No telemetry, no remote inference.
//
// WHY NO AUTH FLOW: Gemma 4 on litert-community is published UNGATED under
// Apache-2.0 (verified via the HuggingFace API: "gated": false). Unlike
// Gemma 3/3n, it needs no account, token, or license-acceptance webview, so
// the AI-Edge-Gallery OAuth flow is intentionally omitted. An optional bearer
// token is still plumbed through [ModelDownloader.huggingFaceToken] purely so a
// future *gated* repo could be supported without restructuring.
//
// FORMAT: the .litertlm file targets LiteRT-LM, which runs directly on the
// LiteRT runtime the Carty C++ bridge links. It is the file
// the bridge will memory-map and load.

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Everything needed to fetch and verify one on-device model artifact.
///
/// All concrete values are VERIFIED against the HuggingFace public API for
/// `litert-community/gemma-4-E2B-it-litert-lm` (checked 2026-06-09). They are
/// not guesses — `sizeInBytes`/`sha256Hex` come from the repo's git-LFS
/// pointers and are the integrity contract for the download.
class GemmaModelSpec {
  const GemmaModelSpec({
    required this.label,
    required this.filename,
    required this.sizeInBytes,
    required this.sha256Hex,
  });

  /// Human-facing name shown in the UI.
  final String label;

  /// The exact file in the HF repo (also the on-device filename).
  final String filename;

  /// Exact byte length from the repo's LFS pointer. Used as a fast,
  /// mandatory integrity gate (a truncated download fails this immediately).
  final int sizeInBytes;

  /// Lower-case hex SHA-256 from the repo's LFS pointer, or null if it was not
  /// captured for this variant (then integrity falls back to size-only).
  final String? sha256Hex;

  /// Direct, unauthenticated download URL (repo is ungated).
  String get url =>
      'https://huggingface.co/${GemmaModels.repo}/resolve/main/$filename';

  double get sizeInGiB => sizeInBytes / (1024 * 1024 * 1024);
}

/// The published Gemma 4 E2B `.litertlm` variants.
/// See https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm .
class GemmaModels {
  GemmaModels._();

  static const String repo = 'litert-community/gemma-4-E2B-it-litert-lm';

  /// Generic build (~2.59 GB). Runs on any arm64 Android via LiteRT CPU/GPU.
  /// SAFE DEFAULT — works regardless of SoC. SHA-256 verified.
  static const GemmaModelSpec generic = GemmaModelSpec(
    label: 'Gemma 4 E2B — generic (~2.6 GB)',
    filename: 'gemma-4-E2B-it.litertlm',
    sizeInBytes: 2588147712,
    sha256Hex:
        '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
  );

  /// Pixel / Google Tensor G5 accelerated build (~3.95 GB). Faster on Tensor
  /// G5, larger download. Size verified; SHA-256 not captured (size-only gate).
  static const GemmaModelSpec tensorG5 = GemmaModelSpec(
    label: 'Gemma 4 E2B — Pixel Tensor G5 (~3.95 GB)',
    filename: 'gemma-4-E2B-it_Google_Tensor_G5.litertlm',
    sizeInBytes: 3953110901,
    sha256Hex: null,
  );

  /// Snapdragon 8 Elite (SM8750) accelerated build (~3.02 GB). Size verified;
  /// SHA-256 not captured (size-only gate).
  static const GemmaModelSpec qualcommSm8750 = GemmaModelSpec(
    label: 'Gemma 4 E2B — Snapdragon 8 Elite (~3.02 GB)',
    filename: 'gemma-4-E2B-it_qualcomm_sm8750.litertlm',
    sizeInBytes: 3016294400,
    sha256Hex: null,
  );

  /// All Android-relevant variants, generic first.
  static const List<GemmaModelSpec> all = <GemmaModelSpec>[
    generic,
    tensorG5,
    qualcommSm8750,
  ];
}

/// Lifecycle state of a model on this device.
enum ModelState {
  /// File absent (or present but wrong size).
  notInstalled,

  /// Background download in progress.
  downloading,

  /// Download paused by the user (resumable).
  paused,

  /// Hashing the downloaded file to confirm integrity.
  verifying,

  /// Present and integrity-checked. Ready for the bridge to load.
  installed,

  /// Download or verification failed; safe to retry (resume if possible).
  failed,
}

/// Drives a resumable, background, integrity-checked download of a
/// [GemmaModelSpec] using `background_downloader`.
///
/// `background_downloader` was chosen over `flutter_downloader` specifically
/// for its true pause/resume + automatic retry, which survives the flaky
/// connections / app-backgrounding that made the previous downloader fail.
class ModelDownloader {
  ModelDownloader({this.huggingFaceToken});

  /// Optional HF bearer token. NOT required for Gemma 4 (ungated). Provided
  /// only as a hook for a future gated repo.
  final String? huggingFaceToken;

  final FileDownloader _downloader = FileDownloader();

  /// The in-flight task, retained so the UI can pause/resume/cancel it.
  DownloadTask? _active;

  /// Absolute on-device path the model will live at once installed.
  Future<String> modelPath(GemmaModelSpec spec) async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}${spec.filename}';
  }

  Future<File> _file(GemmaModelSpec spec) async =>
      File(await modelPath(spec));

  /// Fast presence check: file exists AND byte length matches the spec.
  /// Does not hash (cheap enough to call on every app launch).
  Future<bool> isPresent(GemmaModelSpec spec) async {
    final f = await _file(spec);
    if (!await f.exists()) return false;
    return await f.length() == spec.sizeInBytes;
  }

  DownloadTask _buildTask(GemmaModelSpec spec) => DownloadTask(
        url: spec.url,
        filename: spec.filename,
        baseDirectory: BaseDirectory.applicationSupport,
        updates: Updates.statusAndProgress,
        allowPause: true,
        retries: 5,
        headers: huggingFaceToken == null
            ? const <String, String>{}
            : <String, String>{'Authorization': 'Bearer $huggingFaceToken'},
        metaData: spec.filename,
      );

  /// Download [spec] to app-private storage, then verify it.
  ///
  /// [onProgress] receives a 0..1 fraction during transfer. [onState] receives
  /// coarse [ModelState] transitions for the UI. Returns true iff the file is
  /// present AND passes the integrity gate at the end.
  Future<bool> download(
    GemmaModelSpec spec, {
    required void Function(double fraction) onProgress,
    required void Function(ModelState state) onState,
  }) async {
    // Already installed and intact — skip the multi-GB transfer.
    if (await isPresent(spec) && await verify(spec)) {
      onState(ModelState.installed);
      return true;
    }

    final task = _buildTask(spec);
    _active = task;
    onState(ModelState.downloading);

    final result = await _downloader.download(
      task,
      onProgress: (double p) {
        // background_downloader uses negative sentinels for non-progress
        // events (e.g. paused/failed). Only forward real fractions.
        if (p >= 0.0 && p <= 1.0) onProgress(p);
      },
      onStatus: (TaskStatus status) {
        switch (status) {
          case TaskStatus.paused:
            onState(ModelState.paused);
          case TaskStatus.running:
          case TaskStatus.enqueued:
          case TaskStatus.waitingToRetry:
            onState(ModelState.downloading);
          case TaskStatus.complete:
          case TaskStatus.canceled:
          case TaskStatus.failed:
          case TaskStatus.notFound:
            break; // terminal states handled below
        }
      },
    );

    if (result.status != TaskStatus.complete) {
      _active = null;
      onState(ModelState.failed);
      return false;
    }

    // Transfer finished — now prove the bytes are intact before declaring the
    // model usable (guards against the silent-corruption failure mode).
    onState(ModelState.verifying);
    final ok = await verify(spec);
    _active = null;
    onState(ok ? ModelState.installed : ModelState.failed);
    return ok;
  }

  /// Pause the in-flight download (resumable). No-op if nothing is running.
  Future<bool> pause() async {
    final task = _active;
    if (task == null) return false;
    return _downloader.pause(task);
  }

  /// Resume a paused download.
  Future<bool> resume() async {
    final task = _active;
    if (task == null) return false;
    return _downloader.resume(task);
  }

  /// Cancel the in-flight download and discard partial bytes.
  Future<void> cancel() async {
    final task = _active;
    if (task == null) return;
    await _downloader.cancelTaskWithId(task.taskId);
    _active = null;
  }

  /// Integrity gate: size must match, and (when a published SHA-256 exists)
  /// the streamed hash of the file must match it. The hash is computed over a
  /// streamed read (`openRead`), so memory stays bounded regardless of the
  /// multi-GB file size (Tiger Style: bounded by construction).
  Future<bool> verify(GemmaModelSpec spec) async {
    final f = await _file(spec);
    if (!await f.exists()) return false;
    if (await f.length() != spec.sizeInBytes) return false;

    final expected = spec.sha256Hex;
    if (expected == null) return true; // no published hash → size-only gate

    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString() == expected;
  }

  /// Delete the installed model (e.g. to reclaim space or re-download).
  Future<void> delete(GemmaModelSpec spec) async {
    final f = await _file(spec);
    if (await f.exists()) await f.delete();
  }
}
