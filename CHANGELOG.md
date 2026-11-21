# Changelog

All notable changes to Carty are recorded here. Carty is in early development;
versions are not yet published. Dates are the working dates from the
project history.

## Unreleased

### Tooling
- **Purged Nix flakes.** Deleted `flake.nix`, `flake.lock`, `litert.nix`, and
  `build-android-sdk.nix`, and stripped all `nix develop` / flake references from
  docs and code comments. The project now builds purely from the global toolchain
  in `/etc/nixos/configuration.nix`.

### Architecture
- Ratified the LLM-as-corrector pivot: classical CV builds the map from a fused
  2.5D voxel-column grid; the on-device LLM only corrects low-confidence regions.
  The old per-frame "LLM emits map JSON" design was retired.

### Maintainability (tech-debt cleanup, items 1–7 of 8)
- Deleted the dead `CartySpatialGraph` subsystem and the `carty_infer` stub.
- Retired the native `carty_validate_map_update_json` gate — the Dart
  `MapUpdate.parse` is now the sole extraction semantics.
- Single-sourced the `{"ops":[…]}` output contract in Dart (the native bridge keeps
  no copy; it receives it as an `instruction` argument).
- Replaced FNV-1a with SHA-256 in the version-control store.
- Split the 1166-line `carty_bridge.cpp` into `carty_frame.cpp` / `carty_model.cpp`
  / `carty_ortho.cpp` + an internal header (public C ABI unchanged).
- The in-process LiteRT engine remains open, owned by the architecture pivot.

### Android spike
- Android spike proven on a real device: ARCore `SUPPORTED_INSTALLED`, the
  Dart→FFI→bridge seam end-to-end, `MediaMetadataRetriever` frame extraction, and a
  real ARCore Session 6-DoF pose probe. The on-device LLM decode gate remains open
  (currently honest `ENOMODEL`).

### Foundations (built and tested earlier)
- C/FFI native bridge with crash-at-boundary discipline; Dart inference layer
  (prompt / parser / engine); a git-style version-control engine for maps
  (content-addressed objects, three-way merge, pull requests); video frame
  extraction (ffmpeg on host, `MediaMetadataRetriever` on Android).
