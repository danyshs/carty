/* test_ortho_prompt.cpp — Geometric→Semantic fusion.
 *
 * Tiger Style test-first gate for the two ADDITIVE symbols that wire the
 * top-down CartyOrthoMap into the semantic (LiteRT) stage WITHOUT touching the
 * frozen carty_infer_map_update signature:
 *
 *   - carty_ortho_to_spatial_prompt: serialize an occupancy grid into the fixed
 *     "Spatial Context" cartographic instruction + a bounded, DETERMINISTIC
 *     coarse occupancy summary (the text the text-only Gemma runtime consumes).
 *   - carty_infer_map_update_ortho:  drive Gemma from that prompt. Built here
 *     WITHOUT CARTY_HAVE_LITERT, so it must HONESTLY safe-fail ENOMODEL (no
 *     fabricated map) — mirroring the Dart `.so` reality.
 *
 * No framework: a tiny CHECK macro, matching test_ortho_project / test_spatial_graph.
 */
#include "carty_bridge.h"
#include "carty_check.h"
#include "carty_frame_fixture.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

/* each step builds on the last, so the first failure ends the step (and main stops) */
#undef CHECK
#define CHECK(cond, msg)           \
  do {                             \
    if (!CHECK_QUIET(cond, msg)) { \
      return false;                \
    }                              \
  } while (0)

namespace {

constexpr frame_fixture::FrameDims kMapFrame{64, 48, 4};

/* Build a deterministic, observably-non-empty ortho map from a gradient frame. */
CartyOrthoMap *make_map() {
  CartyFrame *frame = frame_fixture::make_gradient_frame(kMapFrame);
  if (frame == nullptr) {
    return nullptr;
  }
  CartyOrthoMap *map =
      carty_ortho_project(frame, kMapFrame.width_px, kMapFrame.height_px, kMapFrame.channels);
  carty_frame_free(frame);
  return map;
}

}  // namespace

namespace {

constexpr char kTestInstruction[] =
    "You are a cartographic AI. Output ONLY a strict map-update document: "
    "{\"ops\": [ ... ]}.";
constexpr char kPoison = 0x7F;  // any non-NUL byte, so an untouched buffer shows
constexpr size_t kTinyBufBytes = 16;

int32_t instruction_len() { return static_cast<int32_t>(std::strlen(kTestInstruction)); }

/* 1. Serialize: non-empty, NUL-terminated, carries the cartographic instruction
 *    and the GeoJSON target, plus the grid's dimensions. Writes the length to prompt_len. */
bool check_serialize(const CartyOrthoMap *map, char *prompt, int32_t *prompt_len) {
  std::memset(prompt, 0, CARTY_SPATIAL_PROMPT_MAX);
  const int32_t len = carty_ortho_to_spatial_prompt(map, kTestInstruction, instruction_len(),
                                                    prompt, CARTY_SPATIAL_PROMPT_MAX);
  CHECK(len > 0, "spatial prompt serialization returned a negative status");
  CHECK(prompt[len - 1] == '\0', "spatial prompt not NUL-terminated");
  CHECK(std::strlen(prompt) == static_cast<size_t>(len - 1), "embedded NUL in prompt");
  CHECK(std::strstr(prompt, "cartographic AI") != nullptr,
        "prompt missing the Spatial Context instruction");
  CHECK(std::strstr(prompt, "\"ops\"") != nullptr,
        "prompt missing the strict {\"ops\":[...]} output contract");
  CHECK(std::strstr(prompt, "occupancy grid") != nullptr,
        "prompt missing the occupancy-grid framing");
  carty_sayf(stdout, "spatial prompt (%d bytes incl NUL):\n%s\n--- end prompt ---\n", len, prompt);
  *prompt_len = len;
  return true;
}

/* 2. Determinism: two serializations of the same grid are byte-identical
 *    (stable text == stable spatial conditioning across runs). */
bool check_deterministic(const CartyOrthoMap *map, const char *prompt, int32_t prompt_len) {
  char again[CARTY_SPATIAL_PROMPT_MAX];
  std::memset(again, 0, sizeof(again));
  const int32_t again_len = carty_ortho_to_spatial_prompt(map, kTestInstruction, instruction_len(),
                                                          again, sizeof(again));
  CHECK(again_len == prompt_len, "spatial prompt length not deterministic");
  CHECK(std::memcmp(prompt, again, static_cast<size_t>(prompt_len)) == 0,
        "spatial prompt bytes not deterministic");
  carty_sayf(stdout, "%s\n", "ok: two serializations of the same grid are byte-identical");
  return true;
}

/* 3. Bounded by construction: a too-small buffer safe-fails ENOSPACE and leaves
 *    a defined (empty) buffer — never an overrun, never a partial write. */
bool check_undersized(const CartyOrthoMap *map) {
  char tiny[kTinyBufBytes];
  std::memset(tiny, kPoison, sizeof(tiny));
  const int32_t status = carty_ortho_to_spatial_prompt(
      map, kTestInstruction, instruction_len(), tiny, static_cast<int32_t>(sizeof(tiny)));
  CHECK(status == CARTY_INFER_ENOSPACE, "small buffer should return ENOSPACE");
  CHECK(tiny[0] == '\0', "ENOSPACE must leave the buffer defined-empty");
  carty_sayf(stdout, "%s\n", "ok: undersized buffer safe-fails ENOSPACE");
  return true;
}

/* 4. Fusion inference WITHOUT LiteRT linked == honest ENOMODEL, no fabrication
 *    (mirrors the Dart `.so`). The real-decode path is exercised by
 *    test_litert_forward (built WITH CARTY_HAVE_LITERT, runtime env exported).
 *    The model handle is a bare path holder here (no weights load off-LiteRT). */
bool check_no_model(const CartyOrthoMap *map) {
  CartyModel *model = carty_model_load("/dev/null/no-weights.litertlm");
  CHECK(model != nullptr, "carty_model_load returned null");
  char out[CARTY_MAP_UPDATE_MAX];
  std::memset(out, kPoison, sizeof(out));
  const int32_t status = carty_infer_map_update_ortho(model, map, kTestInstruction,
                                                      instruction_len(), out,
                                                      static_cast<int32_t>(sizeof(out)));
  carty_model_free(model);
  CHECK(status == CARTY_INFER_ENOMODEL, "ortho fusion without LiteRT must safe-fail ENOMODEL");
  CHECK(out[0] == '\0', "ENOMODEL must leave the output defined-empty");
  carty_sayf(stdout, "%s\n", "ok: ortho fusion without LiteRT safe-fails ENOMODEL (no fabrication)");
  return true;
}

bool run_steps(const CartyOrthoMap *map) {
  char prompt[CARTY_SPATIAL_PROMPT_MAX];
  int32_t prompt_len = 0;
  return check_serialize(map, prompt, &prompt_len) &&
         check_deterministic(map, prompt, prompt_len) && check_undersized(map) &&
         check_no_model(map);
}

}  // namespace

int main() {
  CartyOrthoMap *map = make_map();
  if (!CHECK_QUIET(map != nullptr, "carty_ortho_project returned null")) {
    return carty_finish("unreachable");
  }
  run_steps(map);
  /* 5. Clean free (run under ASan/LSan via native/build-asan). */
  carty_ortho_map_free(map);
  return carty_finish("ALL ORTHO PROMPT FUSION TESTS PASSED");
}
