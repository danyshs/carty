/*
 * carty_bridge_internal.h — bridge-private declarations shared across the
 * carty_bridge translation units.
 *
 * This header exists ONLY because the bridge implementation was split along its
 * natural seams (frame buffers / model + inference / ortho projection / fusion;
 *) into separate .cpp files that still share three things:
 *   1. the always-on CARTY_ASSERT macro (crash-at-boundary, Tiger Style),
 *   2. the concrete struct layouts behind the opaque public handles
 *      (CartyFrame / CartyModel / CartyOrthoMap) — a struct defined in one TU
 *      must be visible to the TUs that read its fields, and
 *   3. the single in-process LiteRT-LM decode driver (carty_generate_inprocess),
 *      used by BOTH inference entry points (the ROI text path in carty_model.cpp
 *      and the ortho-fusion path in carty_bridge.cpp).
 *
 * It is DELIBERATELY NOT in native/include/ — it is not part of the public C
 * ABI Dart links (carty_bridge.h is the only public surface).
 * Nothing here changes the ABI; it is a translation-unit-split artifact.
 */
#ifndef CARTY_BRIDGE_INTERNAL_H_
#define CARTY_BRIDGE_INTERNAL_H_

#include "carty_bridge.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

/* Always-on assertion. Crashes immediately at the boundary on violation.
 * Tiger Style: assertions are live invariants in ALL builds, so
 * this always aborts rather than <cassert>'s assert(), which the compiler
 * strips under NDEBUG. Defined here so every split TU shares one definition. */
[[noreturn]] inline void carty_assert_fail(const char *msg, const char *file, int line,
                                         const char *func) {
  // abort follows whatever fprintf returns, and no caller is left to tell
  // NOLINTNEXTLINE(cert-err33-c)
  std::fprintf(stderr, "CARTY_ASSERT failed: %s\n  at %s:%d (%s)\n", msg, file, line, func);
  std::abort();
}

inline void carty_assert(bool held, const char *msg, const char *file, int line,
                         const char *func) {
  if (held) {
    return;
  }
  carty_assert_fail(msg, file, line, func);
}

// every message is a string literal, so passing it on every call costs nothing
#define CARTY_ASSERT(cond, msg) \
  carty_assert(static_cast<bool>(cond), (msg), __FILE__, __LINE__, __func__)

#define CARTY_VERSION_STRING "0.2.0"

/* Concrete layout behind the opaque CartyFrame handle (defined in
 * carty_frame.cpp; read by the ortho + inference TUs). */
struct CartyFrame {
  uint8_t *data; /* owned pixel buffer */
  size_t size;   /* width*height*channels, in bytes */
};

/* Concrete layout behind the opaque CartyModel handle (defined in
 * carty_model.cpp). Holds the LiteRT-LM engine RESIDENT for the whole session:
 * the 2.4 GB weight load happens ONCE in carty_model_load, never per call
 * ("engine in-process for the whole session"). The engine pointers
 * are void* (opaque LiteRtLmEngine* / LiteRtLmEngineSettings*) so engine.h is not
 * forced into the non-inference TUs that include this header; carty_model.cpp is
 * the only TU that casts and uses them, under CARTY_HAVE_LITERT. They are null in
 * a degraded build (no LiteRT linked) or when the resident load failed — decode
 * then safe-fails ENOMODEL, never fabricates (Tiger Style). */
struct CartyModel {
  char *model_path;
  void *engine;   /* LiteRtLmEngine*: resident, loaded once; null = degraded */
  void *settings; /* LiteRtLmEngineSettings*: kept alive for the engine's lifetime */
};

/* Concrete layout behind the opaque CartyOrthoMap handle (defined in
 * carty_ortho.cpp; read by the fusion TU). The metric footprint extent
 * (min/max in the camera-LOCAL ground frame, +x right / +y forward) is the
 * back-projected-corner bbox carty_ortho_project computes; it is retained here so
 * fusion can recover each observed cell's real-world position (carty_ortho_map_extent). */
struct CartyOrthoMap {
  int32_t width, height;
  uint8_t *cells; /* owned, row-major width*height occupancy bytes */
  size_t size;    /* width*height */
  double min_x, max_x, min_y, max_y; /* metric footprint (camera-local ground) */
};

/* Concrete layout behind the opaque CartyWorldGrid handle (defined in
 * carty_fusion.cpp). The persistent, world-anchored 2.5D voxel-column grid for ONE
 * capture segment: n*n*h int8 log-odds of observation/coverage evidence (row-major,
 * band-major: idx=(band*n+gy)*n+gx), an origin anchored to the first keyframe, and
 * a bounded set of incorporated keyframe ids for literal dedup. Bounded by
 * construction (CARTY_GRID_MAX_*); see carty_bridge.h for the coordinate convention. */
struct CartyWorldGrid {
  int32_t n, h;                          /* ground cells/side, height bands */
  double res_m, band_m;                  /* metres per ground cell / per band */
  double origin_x, origin_y, origin_z;   /* world point at cell (0,0,band0) */
  int anchored;                          /* 0 until first accrete sets origin */
  int8_t *cells;                         /* owned, n*n*h log-odds */
  size_t size;                           /* n*n*h */
  uint8_t *color;                        /* owned, n*n*3 RGB of the floor band:
                                          * the real camera color each ground cell
                                          * was observed with (top-down photo-map),
                                          * 0 where unobserved. Captured only by the
                                          * raw-frame splat (accrete_from_frame),
                                          * which is the one path that has pixels. */
  int64_t seen_ids[CARTY_GRID_SEEN_MAX]; /* incorporated keyframe ids (dedup) */
  int32_t seen_count;
};

#ifdef CARTY_HAVE_LITERT
/* Decode prompt_text against the RESIDENT Gemma 4 E2B engine held in `model`,
 * IN-PROCESS (no fork/exec), writing the model's raw generated text into
 * output_buf. Shared by every inference entry point (the ROI text path in
 * carty_model.cpp AND the ortho-fusion path in carty_bridge.cpp) so the single
 * proven decode recipe — generate_content + apply_prompt_template=false + the
 * model's own <|turn> markers (NOT the Conversation API, whose only accessor
 * returns a JSON envelope the bridge must not parse) — lives in
 * exactly one place. Defined in carty_model.cpp. Returns bytes written incl NUL,
 * or a negative CARTY_INFER_* status (ENOMODEL if the resident engine is null /
 * the decode produced nothing; ENOSPACE if output_buf is too small) — never
 * fabricates. Only declared when CARTY_HAVE_LITERT is set. */
int32_t carty_generate_inprocess(const CartyModel *model, const char *prompt_text,
                                 char *output_buf, int32_t output_buf_size);
#endif

#endif /* CARTY_BRIDGE_INTERNAL_H_ */
