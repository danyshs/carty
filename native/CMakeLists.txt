# CMakeLists.txt — builds the Carty native bridge shared library + its tests.
#
# Produces libcarty_bridge.so, the single FFI surface Dart loads at runtime
# (LiteRT-LM is linked in-process when its runtime is vendored, see below).
cmake_minimum_required(VERSION 3.22)
project(carty_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Zero-warnings policy (quality gate): warnings are build-breaking errors.
add_compile_options(-Wall -Wextra -Wpedantic -Werror)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)  # clangd finds the headers

# Nix-provided libraries (e.g. OpenCV) live in the content-addressed store with
# no global ld path; bake their link directories into the build rpath so the
# bridge + ctest binaries resolve their .so at runtime without LD_LIBRARY_PATH.
set(CMAKE_BUILD_RPATH_USE_LINK_PATH ON)

# OpenCV — the Geometric stage (carty_ortho_project) uses cv::warpPerspective to
# orthorectify raw frames into the top-down CartyOrthoMap. It is OPTIONAL by
# design: when found (the Nix dev shell provides it) the real warp
# path is compiled with CARTY_HAVE_OPENCV; when absent (e.g. a stripped Android
# cross-build before OpenCV is vendored for the ABI) the bridge falls back to its
# dependency-free inverse-map sampler, so every target still builds and links.
find_package(OpenCV QUIET COMPONENTS core imgproc)
if(OpenCV_FOUND)
  message(STATUS "OpenCV ${OpenCV_VERSION} found — Geometric stage uses cv::warpPerspective")
else()
  message(STATUS "OpenCV NOT found — Geometric stage uses the dependency-free sampler")
endif()

# Apply OpenCV (when present) to a target: include dirs, libs, and the
# CARTY_HAVE_OPENCV switch that selects the warpPerspective path in the bridge.
function(carty_use_opencv target)
  if(OpenCV_FOUND)
    target_include_directories(${target} PRIVATE ${OpenCV_INCLUDE_DIRS})
    target_link_libraries(${target} PRIVATE ${OpenCV_LIBS})
    target_compile_definitions(${target} PRIVATE CARTY_HAVE_OPENCV=1)
  endif()
endfunction()

# LiteRT-LM in-process runtime + Gemma 4 E2B weights for on-device inference.
#
# WEIGHTS: the model is `gemma-4-E2B-it.litertlm` (LiteRT-LM bundle, 2.4 GB, sha256
# verified). On the host the path is given by CARTY_GEMMA_MODEL; on the device the
# in-app downloader (example/lib/model_downloader.dart) fetches it (its own hash gate).
#
# RUNTIME (Route 1, vendored 2026-06-18): the host- and device-linkable LiteRT-LM
# C ABI now exists. `litert-runtime/` vendors `include/engine.h` (the Engine/Session
# C API) and `lib/<abi>/liblitert-lm.so` for x86_64 (host ctest) and arm64-v8a
# (device) — built from `//python/litert_lm:litert-lm` at tag v0.13.1; recipe +
# sha256s in `litert-runtime/PROVENANCE.md`. This REPLACES the old fork/exec
# subprocess driver: the engine is loaded once and decode runs in-process behind
# the bridge.
#
# The .so payloads are gitignored (rebuild per PROVENANCE.md); a fresh clone has
# the header but not the binaries, so wiring is guarded on the .so existing for the
# target ABI — when absent the bridge degrades to an honest ENOMODEL.
#
# Layout:
#   LITERT_DIR/include/engine.h
#   LITERT_DIR/lib/<abi>/liblitert-lm.so          (<abi> = x86_64 | arm64-v8a)
set(LITERT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../litert-runtime" CACHE STRING
    "Path to the vendored host/device-linkable LiteRT-LM C API (headers + .so)")

# Select the .so for the ABI being built and check it is actually present AND
# valid for this platform. CRITICAL: lib/x86_64 holds the HOST (glibc) runtime for
# the headless ctest loop — it is NOT an Android binary. The two "x86_64"s collide
# on one path, so an Android x86_64/emulator build must NOT pick the host .so up:
# the NDK linker rejects its glibc ELF version table ("version definition index out
# of bounds"). We vendor an Android runtime for arm64-v8a ONLY (the product ABI),
# so on Android the runtime counts as available for arm64-v8a alone;
# any other Android ABI degrades to an honest ENOMODEL.
if(ANDROID)
  set(_litert_abi "${CMAKE_ANDROID_ARCH_ABI}")
else()
  set(_litert_abi "${CMAKE_SYSTEM_PROCESSOR}")  # x86_64 on the host loop
endif()
set(LITERT_SO "${LITERT_DIR}/lib/${_litert_abi}/liblitert-lm.so")

set(CARTY_LITERT_AVAILABLE OFF)
if(EXISTS "${LITERT_SO}" AND (NOT ANDROID OR _litert_abi STREQUAL "arm64-v8a"))
  set(CARTY_LITERT_AVAILABLE ON)
  message(STATUS "LiteRT-LM in-process runtime FOUND (${_litert_abi}): ${LITERT_SO}")
  # liblitert-lm.so was built expecting a companion libGemmaModelConstraintProvider.so
  # (DT_NEEDED + 3 versioned UND symbols) that upstream does not ship. Those symbols
  # are only used for constrained/tool-call decoding; for plain text generation a
  # stub whose Create returns NULL ("no constraint") satisfies the loader. The
  # version script re-exports them under VERS_1.0 so the versioned UNDs resolve.
  add_library(GemmaModelConstraintProvider SHARED litert/cprov_stub.c)
  target_link_options(GemmaModelConstraintProvider PRIVATE
      "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/litert/cprov.map")
else()
  message(STATUS "LiteRT-LM in-process runtime ABSENT (${_litert_abi}) — honest "
                 "ENOMODEL; build it per litert-runtime/PROVENANCE.md to enable")
endif()

# Link the vendored in-process runtime (+ the constraint-provider stub it NEEDs)
# into a target. No-op when the .so is absent for this ABI, so every target still
# configures on a fresh clone (degrading to ENOMODEL).
function(carty_use_litert target)
  if(CARTY_LITERT_AVAILABLE)
    target_include_directories(${target} PRIVATE ${LITERT_DIR}/include)
    target_link_libraries(${target} PRIVATE ${LITERT_SO} GemmaModelConstraintProvider)
  endif()
endfunction()

# The bridge implementation, split along its natural seams):
# core/version (carty_bridge.cpp), frame buffers (carty_frame.cpp), model handle +
# ROI inference + the in-process LiteRT decode driver (carty_model.cpp), ortho
# projection (carty_ortho.cpp), and world-frame voxel-column fusion
# (carty_fusion.cpp, the CartyWorldGrid, the fusion stage). Shared structs/CARTY_ASSERT/
# driver decl live in src/carty_bridge_internal.h. Every target compiles the full set.
set(CARTY_BRIDGE_SRCS
    src/carty_bridge.cpp
    src/carty_frame.cpp
    src/carty_model.cpp
    src/carty_ortho.cpp
    src/carty_fusion.cpp
    src/carty_vectorize.cpp)

# The FFI shared library.
add_library(carty_bridge SHARED ${CARTY_BRIDGE_SRCS})
if(APPLE)
  # tests and the app dlopen libcarty_bridge.so on every host; dlopen doesn't care about the suffix
  set_target_properties(carty_bridge PROPERTIES SUFFIX ".so")
endif()
target_include_directories(carty_bridge PUBLIC include)
carty_use_opencv(carty_bridge)

# Dart opens the bridge as `libcarty.so` (lib/carty.dart _libName) on Android,
# where the APK packages whatever this target emits — so name it to match Dart
# there. Host tests bypass the name: they DynamicLibrary.open the built
# libcarty_bridge.so by absolute path (headless dev loop; no desktop app).
if(ANDROID)
  set_target_properties(carty_bridge PROPERTIES OUTPUT_NAME carty)
endif()

# In-process LiteRT-LM decode (Route 1) for the Dart-facing bridge.
#
# CARTY_HAVE_LITERT compiles the IN-PROCESS decode path: the bridge links the
# vendored liblitert-lm.so (carty_use_litert) and holds the Gemma engine resident
# in CartyModel — no subprocess. It is enabled whenever the runtime .so is vendored
# for the target ABI (CARTY_LITERT_AVAILABLE):
#   - Android (arm64): ALWAYS on when available — this is the SHIPPED product
#     (Step 4, the on-device decode gate A2). The APK packages liblitert-lm.so via
#     jniLibs (example/android/app/build.gradle.kts); libGemmaModelConstraintProvider
#     .so is a CMake build-dependency so AGP packages it automatically.
#   - Host (x86_64): on by default for the HEADLESS dev loop (flutter test / ctest /
#     tool/e2e_probe.dart exercise REAL Gemma 4 E2B through the exact same FFI seam
#     the Android app uses), behind the CARTY_ENABLE_LITERT_HOST opt-out so a host
#     build can disable it.
# A fresh clone without the .so for this ABI degrades to an honest
# CARTY_INFER_ENOMODEL — it still builds. The model path arrives through the C ABI
# (carty_model_load); no env vars are read. Absent weights also safe-fail ENOMODEL —
# never fabricate.
option(CARTY_ENABLE_LITERT_HOST
       "Link the in-process LiteRT-LM runtime into the host bridge (dev; x86_64). Android always links it when the .so is vendored for the ABI."
       ON)
if(CARTY_LITERT_AVAILABLE AND (ANDROID OR CARTY_ENABLE_LITERT_HOST))
  target_compile_definitions(carty_bridge PRIVATE CARTY_HAVE_LITERT=1)
  carty_use_litert(carty_bridge)
  message(STATUS "LiteRT in-process path ENABLED for the bridge (${_litert_abi})")
else()
  message(STATUS "LiteRT in-process path OFF for the bridge (${_litert_abi}; disabled or .so absent) — honest ENOMODEL")
endif()

# Dependency-free native unit tests (Tiger Style: test-first).
enable_testing()
add_executable(test_bridge tests/test_bridge.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_bridge PRIVATE include)
add_test(NAME bridge_unit COMMAND test_bridge)

# Isolated dummy-tensor pass-through over the FFI surface (no Flutter, no
# LiteRT). Proves bit-for-bit round-trip + buffer ownership; run under ASan/LSan
# separately for the memory-poison/leak gate (see native/build-asan).
add_executable(test_tensor_passthrough
               tests/test_tensor_passthrough.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_tensor_passthrough PRIVATE include)
add_test(NAME tensor_passthrough COMMAND test_tensor_passthrough)

# Geometric stage tests (orthorectification). Verifies the planar
# homography produces a bounded, DETERMINISTIC top-down occupancy grid from raw
# RGBA frames (byte-identical across runs == stable 2D coords) and that every
# CartyOrthoMap is freed cleanly (run under ASan/LSan via native/build-asan).
add_executable(test_ortho_project
               tests/test_ortho_project.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_ortho_project PRIVATE include)
carty_use_opencv(test_ortho_project)
add_test(NAME ortho_project_unit COMMAND test_ortho_project)

# Fusion stage tests (the fusion stage: the world-frame voxel-column grid). The
# host done-signal for backlog item #2 — proves multi-frame accretion stays within
# N×N×H, is idempotent under a repeated keyframe (DUPLICATE -> byte-identical),
# monotonic in evidence, bounded under repetition, OOB-safe, correctly anchored,
# and that yaw placement is isolated from the ~60° down pitch (the #1 correctness
# risk). No LiteRT, no model. Runs under ASan/LSan via native/build-asan.
add_executable(test_world_grid_fusion
               tests/test_world_grid_fusion.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_world_grid_fusion PRIVATE include)
carty_use_opencv(test_world_grid_fusion)
add_test(NAME world_grid_fusion_unit COMMAND test_world_grid_fusion)

# Depth reprojection tests (depth reprojection): proves
# carty_world_grid_accrete_from_depth travels the measured depth Z down each ray
# and folds the hit at the band of its real world-Y (vs the frame path's
# ground-plane projection), via a hand-computed asymmetric synthetic fixture —
# zero device cost. No LiteRT, no model.
add_executable(test_depth_reproject
               tests/test_depth_reproject.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_depth_reproject PRIVATE include)
carty_use_opencv(test_depth_reproject)
add_test(NAME depth_reproject_unit COMMAND test_depth_reproject)

# Depth confidence-weighting tests (depth confidence weighting): proves
# carty_world_grid_accrete_from_depth scales the fold by ARCore's conf plane (hard
# threshold + linear soft-scale), with NULL-conf parity to depth reprojection. Host-only, no model.
add_executable(test_depth_confidence
               tests/test_depth_confidence.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_depth_confidence PRIVATE include)
carty_use_opencv(test_depth_confidence)
add_test(NAME depth_confidence_unit COMMAND test_depth_confidence)

# Depth occlusion-carve tests (depth occlusion carving): proves
# carty_world_grid_accrete_from_depth ray-marches free-space from sensor to hit and
# lowers log-odds on passed-through voxels (hit voxel excluded; NULL/sub-threshold
# rays carve nothing). Host-only, no model.
add_executable(test_depth_carve
               tests/test_depth_carve.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_depth_carve PRIVATE include)
carty_use_opencv(test_depth_carve)
add_test(NAME depth_carve_unit COMMAND test_depth_carve)

# Geometric→Semantic fusion tests (wire CartyOrthoMap into inference).
# Built WITHOUT CARTY_HAVE_LITERT, so it gates the deterministic Spatial Context
# serializer (carty_ortho_to_spatial_prompt) + the honest ENOMODEL safe-fail of
# carty_infer_map_update_ortho when no runtime is linked. The real-decode side of
# the fusion is exercised by test_litert_forward (below). Runs under ASan/LSan via
# native/build-asan to prove the serializer leaks nothing.
add_executable(test_ortho_prompt
               tests/test_ortho_prompt.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_ortho_prompt PRIVATE include)
carty_use_opencv(test_ortho_prompt)
add_test(NAME ortho_prompt_unit COMMAND test_ortho_prompt)

# Multimodal structured-inference tests (model integration scaffold).
# Mock multimodal block through the tensor pipeline (safe-fail with no LiteRT)
# + the structural JSON-output safety gate (malformed output fails safely).
add_executable(test_multimodal_inference
               tests/test_multimodal_inference.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_multimodal_inference PRIVATE include)
add_test(NAME multimodal_inference COMMAND test_multimodal_inference)

# Real Gemma 4 E2B forward pass, IN-PROCESS through the carty_bridge ABI. Built
# with CARTY_HAVE_LITERT=1 AND linked against the vendored LiteRT-LM .so
# (carty_use_litert), so carty_model_load holds the engine resident and
# carty_infer_map_update decodes over the weights with NO subprocess — the Route 1
# bridge-level seam gate. Env-gated: when CARTY_GEMMA_MODEL is exported it runs a
# real prefill+decode and asserts steered output; otherwise 77 → ctest SKIP.
# test_multimodal_inference above stays the no-weights safe-fail ABI gate (built
# WITHOUT CARTY_HAVE_LITERT) and is intentionally left intact. Only built where the
# runtime .so is vendored for this ABI (it fundamentally needs the link); a fresh
# clone without the .so omits it (build per litert-runtime/PROVENANCE.md).
if(CARTY_LITERT_AVAILABLE)
  add_executable(test_litert_forward
                 tests/test_litert_forward.cpp ${CARTY_BRIDGE_SRCS})
  target_include_directories(test_litert_forward PRIVATE include)
  target_compile_definitions(test_litert_forward PRIVATE CARTY_HAVE_LITERT=1)
  carty_use_litert(test_litert_forward)
  add_test(NAME litert_forward COMMAND test_litert_forward)
  set_tests_properties(litert_forward PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 900)
endif()

# Vectorize stage tests: occupancy volume -> MapGraph
# GeoJSON via classical CV. Per-stage property tests + the FFI boundary contract
# (null-abort, unanchored-grid status). No LiteRT, no model. Runs under ASan/LSan
# via native/build-asan.
add_executable(test_vectorize
               tests/test_vectorize.cpp ${CARTY_BRIDGE_SRCS})
target_include_directories(test_vectorize PRIVATE include src)
target_compile_definitions(test_vectorize PRIVATE
    CARTY_REPO_ROOT="${CMAKE_SOURCE_DIR}/..")
add_test(NAME vectorize_unit COMMAND test_vectorize)

# Real Gemma 4 E2B decode IN-PROCESS via the vendored LiteRT-LM C ABI (engine.h),
# with NO subprocess. Drives litert-runtime/lib/<abi>/liblitert-lm.so directly,
# isolating "does the vendored runtime decode" from the bridge wrapping. Env-gated
# on CARTY_GEMMA_MODEL alone (no separate runtime binary) → 77 SKIP when unset.
# Only built where the runtime .so is vendored for this ABI (fundamentally needs
# the link); a fresh clone without the .so simply omits it (build per PROVENANCE).
if(CARTY_LITERT_AVAILABLE)
  add_executable(test_inprocess_decode tests/test_inprocess_decode.cpp)
  carty_use_litert(test_inprocess_decode)
  add_test(NAME inprocess_decode COMMAND test_inprocess_decode)
  set_tests_properties(inprocess_decode PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 900)
endif()
