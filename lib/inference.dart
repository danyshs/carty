/// Carty on-device inference layer — public barrel.
///
/// Steers Gemma 4 E2B into strict, version-controllable map updates:
///   [MultimodalPrompt] (image segment + text + spatial bounds, bounded for
///   mobile context limits) -> a [RawInferer] -> [MapUpdate.parse] (tolerant
///   extraction, strict schema validation, safe failure) -> [MapUpdate.apply]
///   over a [MapGraph] -> an optional version-control commit via
///   [InferenceEngine].
///
/// Architecture: this layer sits ABOVE the FFI front door
/// (`lib/carty.dart`) and the version-control engine (`lib/vc.dart`). The model
/// forward pass crosses the bridge as a bridge-owned tensor; the strict parsing
/// that protects the map lives here, in pure Dart, beside the VC engine.
library;

export 'inference/prompt.dart';
export 'inference/map_update.dart';
export 'inference/engine.dart';
