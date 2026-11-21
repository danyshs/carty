import 'package:file_selector/file_selector.dart';

/// Real platform picker for Carty's **third-class** input path: passing a
/// PRE-RECORDED video into the Video → Map harness. Live ARCore capture is the
/// first-class flow — this picker exists for the lower-quality,
/// pose-less clip case and the desktop/dev replay loop, and is deliberately not
/// the primary affordance.
///
/// Opens the platform document picker filtered to video files and returns the
/// chosen file's local path, or `null` if the user cancelled. Injected into
/// [VideoMapPage] through its `videoPicker` seam so the widget stays
/// platform-free and unit-testable with a fake.
///
/// Uses the Flutter-team `file_selector` plugin (replacing the unmaintained
/// `file_picker`, which shipped its own Kotlin Gradle Plugin and broke under the
/// built-in-Kotlin toolchain). `file_selector` returns an [XFile] whose `.path`
/// the bridge reads straight from disk — the multi-hundred-MB clip is never
/// loaded into the Dart heap.
Future<String?> pickVideoFile() async {
  // Android filters by MIME type via the Storage Access Framework; `video/*`
  // matches every container the picker exposes.
  const videoGroup = XTypeGroup(label: 'videos', mimeTypes: <String>['video/*']);
  final file = await openFile(acceptedTypeGroups: <XTypeGroup>[videoGroup]);
  return file?.path;
}
