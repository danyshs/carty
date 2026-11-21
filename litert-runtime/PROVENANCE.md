# litert-runtime — vendored LiteRT-LM C API runtime (provenance)

This directory holds the **LiteRT-LM C API** that Carty's FFI bridge links against (the
`LITERT_DIR` seam in [`../native/CMakeLists.txt`](../native/CMakeLists.txt)). It is what
makes in-process decode possible. The build is pinned and content-addressed.

## Layout

```
litert-runtime/
  include/engine.h                  # the C ABI: extern "C", 89 litert_lm_* functions (shared by both ABIs)
  lib/arm64-v8a/liblitert-lm.so     # Android device/emulator runtime
  lib/x86_64/liblitert-lm.so        # host runtime for the headless ctest in-process path
```

## Build pins (shared)

| Field | Value |
|-------|-------|
| Source | `github.com/google-ai-edge/LiteRT-LM` |
| Tag | `v0.13.1` |
| Commit | `a0afb5a5` |
| Bazel | `7.6.1` (`.bazelversion`, via bazelisk) |
| NDK (android only) | `r29` (`29.0.14206865`) |
| Bazel target | `//python/litert_lm:litert-lm` (`cc_binary linkshared=1`, srcs `//c:engine.{cc,h}`). NOTE: the docs' `//c:litert-lm` does **not** exist at this tag. |
| `include/engine.h` sha256 | `d8bde0cc43751d62f9e5cd59e4c149abe35b57e5dcb15a691ae765910169751f` |

## Per-ABI artifacts

| ABI | command | `.so` sha256 | facts |
|-----|---------|--------------|-------|
| arm64-v8a | `bazelisk build --config=android_arm64 //python/litert_lm:litert-lm` | `7ff3ea04a898437ff8227cdabf0ae87878271611de571f0359614ff150eef64a` | ELF aarch64, "for Android 31, NDK r29", 24 MB, stripped. `PT_GNU_STACK` = `RW` (non-exec) as built — no post-step needed. |
| x86_64 | `bazelisk build //python/litert_lm:litert-lm` **then clear execstack (below)** | `a2d5250634c75f7f89424c901eb09b703013ed73a74229bfac3d01db05966137` | ELF x86-64, 30 MB, stripped, CPU-only (`-DLITERT_DISABLE_OPENCL_SUPPORT=1`). sha is **post-execstack-clear** (raw bazel output was `5f31141a…`). |

### x86_64 post-build step: clear the executable stack (REQUIRED)

The raw x86_64 bazel output ships `PT_GNU_STACK` = `RWE` (executable stack — a stray
asm object lacking `.note.GNU-stack`; the arm64 build is unaffected). The headless
ctest binaries link it fine (the kernel grants an exec stack at `exec`), but `flutter
test` / the app **`dlopen`** `libcarty_bridge.so`, which DT_NEEDs this `.so`, and glibc
**refuses to make a running process's stack executable** → `cannot enable executable
stack as shared object requires`. The library never executes stack code (the arm64
sibling proves the bit is spurious), so clear `PF_X` from `PT_GNU_STACK` after building:

```bash
# patchelf ≥ 0.18:
patchelf --clear-execstack litert-runtime/lib/x86_64/liblitert-lm.so
# or, with execstack (prelink):
execstack -c litert-runtime/lib/x86_64/liblitert-lm.so
# verify: readelf -l … | grep -A1 GNU_STACK  →  RW (not RWE)
```

(The vendored `.so` in the tree is already cleared; redo this only after a fresh build.)

Both export all **89** `litert_lm_*` C ABI symbols (engine/conversation lifecycle +
decode + `benchmark_info` — the source of the A(2) decode numbers). The `.so`s also
re-export ~25k internal symbols (zlib/FFT/tokenizer) because `-fvisibility=hidden` only
applies to `engine.cc`; harmless for FFI (`-Wl,-Bsymbolic` binds internal refs first).

## NixOS build prerequisite

`nix-ld` (loader shim) lets the prebuilt bazel/NDK ELFs start, but the build also needs
`/bin/bash` to exist, for two reasons: bazel_skylib `copy_file` shell actions, and ~24
bundled bazel scripts whose shebang is `#!/bin/bash` (the host cc-autoconfig path; the
android NDK crosstool skips them). Provided via a single pinned symlink in
`/etc/nixos/configuration.nix`:

```nix
systemd.tmpfiles.rules = [ "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash" ];
```

With that in place, the two `bazelisk build` commands above run as-is — no extra flags.
