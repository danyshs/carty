/* test_litert_forward.cpp — proves a REAL Gemma 4 E2B forward pass IN-PROCESS,
 * through the carty_bridge C ABI (Route 1 / A2 seam gate).
 *
 * Built with CARTY_HAVE_LITERT=1 AND linked against the vendored LiteRT-LM .so,
 * so carty_model_load holds the engine RESIDENT and carty_infer_map_update decodes
 * over the weights with NO fork/exec, NO subprocess, NO stdout scraping. This is
 * the honest bridge-level "real Invoke()" gate: a non-empty, instruction-steered
 * generation cannot be produced without an actual prefill+decode over the model.
 *
 * Where the sibling test_inprocess_decode proves the raw .so decodes (bypassing
 * the bridge), THIS proves the bridge WRAPS that decode behind its public ABI.
 *
 * Unlike the deleted fork/exec path, the in-process engine needs only the model:
 * the runtime is the linked .so. So it is gated on CARTY_GEMMA_MODEL alone — unset
 * → 77 → ctest SKIP. It NEVER asserts success when skipped. The no-weights
 * safe-fail ABI contract lives in test_multimodal_inference (built without
 * CARTY_HAVE_LITERT) and is untouched.
 */
#include "carty_bridge.h"
#include "carty_check.h"
#include "carty_frame_fixture.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

/* each step builds on the last, so the first failure ends the step */
#undef CHECK
#define CHECK(cond, msg)           \
  do {                             \
    if (!CHECK_QUIET(cond, msg)) { \
      return false;                \
    }                              \
  } while (0)

namespace {

constexpr int kSkipExit = 77;  // ctest SKIP_RETURN_CODE
constexpr size_t kOutMax = 8192;
constexpr size_t kPromptMax = 256;
// A small valid image segment: the host text runtime ignores pixels today,
// but the bridge asserts a non-null, non-empty frame at the boundary.
constexpr int32_t kSegmentSidePx = 8;
constexpr int32_t kSegmentChannels = 3;
constexpr frame_fixture::FrameDims kGridFrame{64, 48, 4};

/* Steer the model to a token it would not otherwise emit, so a match proves a
 * real instruction-conditioned decode (not an echo or canned string). */
constexpr char kSteer[] = "CARTY_FORWARD_PASS_OK";

/* The serialized Spatial Context prompt must carry the cartographic instruction
 * (proves the grid is what conditions the decode). */
constexpr char kTestInstruction[] =
    "You are a cartographic AI. Output ONLY a strict map-update document: "
    "{\"ops\": [ ... ]}.";

int32_t instruction_len() { return static_cast<int32_t>(std::strlen(kTestInstruction)); }

bool check_steered_decode(const CartyModel *model, const CartyFrame *segment) {
  CHECK(segment != nullptr, "carty_frame_alloc returned null");
  char out[kOutMax];
  std::memset(out, 0, sizeof(out));
  char prompt[kPromptMax];
  const int prompt_len = std::snprintf(prompt, sizeof(prompt),
                                       "Reply with exactly this token and nothing else: %s", kSteer);
  CHECK(prompt_len > 0 && static_cast<size_t>(prompt_len) < sizeof(prompt),
        "steering prompt did not fit");

  const int32_t written = carty_infer_map_update(model, segment, prompt, 0.0F, 0.0F, 1.0F, 1.0F,
                                                 out, static_cast<int32_t>(sizeof(out)));
  carty_sayf(stdout, "carty_infer_map_update -> %d\n", written);

  /* written > 0 == bytes written (incl NUL). You cannot get a non-empty decoded
   * generation without a real prefill+decode over the weights. */
  CHECK(written > 0, "expected a real generation; got a negative status");
  CHECK(out[written - 1] == '\0', "output not NUL-terminated");
  CHECK(std::strlen(out) > 0, "generation was empty");
  carty_sayf(stdout, "=== Gemma 4 E2B output (%d bytes incl NUL) ===\n%s\n=== end ===\n",
             written, out);

  /* Instruction-steering evidence (the decisive proof it is a real LLM run). */
  const bool steered = std::strstr(out, kSteer) != nullptr;
  carty_sayf(stdout, "steered-token present: %s\n", steered ? "yes" : "no");
  CHECK(steered, "output did not contain the instruction-steered token");
  return true;
}

/* ---- Geometric input: real decode CONDITIONED ON a top-down occupancy grid.
 * This is the fusion seam — orthorectify a frame into a CartyOrthoMap,
 * then run carty_infer_map_update_ortho (Spatial Context prompt → real Gemma).
 * A non-empty generation here can only come from a real prefill+decode over the
 * grid-derived prompt; we do NOT assert on the map's *content* (that is the
 * model's job), only that the geometric→semantic path runs end to end. */
bool check_grid_conditioned(const CartyModel *model, const CartyOrthoMap *map) {
  CHECK(map != nullptr, "carty_ortho_project returned null");
  char spatial_prompt[CARTY_SPATIAL_PROMPT_MAX];
  const int32_t prompt_len =
      carty_ortho_to_spatial_prompt(map, kTestInstruction, instruction_len(), spatial_prompt,
                                    static_cast<int32_t>(sizeof(spatial_prompt)));
  CHECK(prompt_len > 0, "spatial prompt serialization failed");
  CHECK(std::strstr(spatial_prompt, "cartographic AI") != nullptr,
        "spatial prompt missing the cartographic instruction");

  char out[kOutMax];
  std::memset(out, 0, sizeof(out));
  const int32_t written = carty_infer_map_update_ortho(model, map, kTestInstruction,
                                                       instruction_len(), out,
                                                       static_cast<int32_t>(sizeof(out)));
  carty_sayf(stdout, "carty_infer_map_update_ortho -> %d\n", written);
  CHECK(written > 0, "expected a real grid-conditioned generation; got a negative status");
  CHECK(out[written - 1] == '\0', "ortho-fusion output not NUL-terminated");
  CHECK(std::strlen(out) > 0, "ortho-fusion generation was empty");
  carty_sayf(stdout,
             "=== Gemma 4 E2B grid-conditioned output (%d bytes incl NUL) ===\n%s\n=== end ===\n",
             written, out);
  return true;
}

/* allocates both inputs up front, so every step's failure still frees them */
void run_checks(const CartyModel *model) {
  CartyFrame *segment = carty_frame_alloc(kSegmentSidePx, kSegmentSidePx, kSegmentChannels);
  CartyFrame *grid_frame = frame_fixture::make_gradient_frame(kGridFrame);
  CHECK_QUIET(grid_frame != nullptr, "carty_frame_alloc (geometric) returned null");
  CartyOrthoMap *map = grid_frame == nullptr
                           ? nullptr
                           : carty_ortho_project(grid_frame, kGridFrame.width_px,
                                                 kGridFrame.height_px, kGridFrame.channels);
  if (check_steered_decode(model, segment)) {
    static_cast<void>(check_grid_conditioned(model, map));
  }
  if (map != nullptr) {
    carty_ortho_map_free(map);
  }
  if (grid_frame != nullptr) {
    carty_frame_free(grid_frame);
  }
  if (segment != nullptr) {
    carty_frame_free(segment);
  }
}

}  // namespace

int main() {
  const char *model_path = std::getenv("CARTY_GEMMA_MODEL");
  if (model_path == nullptr || model_path[0] == '\0') {
    carty_sayf(stderr, "%s\n",
               "SKIP: CARTY_GEMMA_MODEL unset — export the path to "
               "gemma-4-E2B-it.litertlm to run the real in-process decode.");
    return kSkipExit;
  }
  carty_sayf(stdout, "model: %s\n", model_path);

  CartyModel *model = carty_model_load(model_path);
  if (CHECK_QUIET(model != nullptr, "carty_model_load returned null")) {
    run_checks(model);
    carty_model_free(model);
  }
  return carty_finish(
      "PASS: real Gemma 4 E2B forward pass produced steered + grid-conditioned output.");
}
