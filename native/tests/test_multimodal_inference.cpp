/*
 * test_multimodal_inference.cpp — "mock multimodal block" pass through
 * the tensor pipeline.
 *
 * WHAT THIS PROVES (without any LiteRT weights, which are not yet linked):
 *
 *   1. TENSOR PASSTHROUGH (multimodal block): an image-segment frame allocated
 *      and filled across the SAME FFI surface Dart uses, plus a text prompt and
 *      a normalized spatial bound, is pushed through carty_infer_map_update().
 *      With LiteRT absent the call must FAIL SAFELY — return CARTY_INFER_ENOMODEL,
 *      leave the output buffer NUL-terminated/empty, and NOT crash. This is the
 *      buffer+ABI contract the real inference path will sit on top of.
 *
 *   (The native structural JSON pre-gate carty_validate_map_update_json was
 *    retired —. The authoritative Dart parser MapUpdate.parse is
 *    now the SOLE extraction semantics; its malformed-input safety is covered by
 *    test/inference_test.dart.)
 *
 * Dependency-free (no gtest), matching test_bridge.cpp / test_tensor_passthrough.
 */
#include "carty_bridge.h"
#include "carty_check.h"

#include <cstdint>
#include <cstdio>
#include <cstring>



namespace {

/* Quiet like CHECK_QUIET, and a failure says what came back. */
void check_eq(long long actual, long long expected, const char *msg) {
  if (actual == expected) {
    return;
  }
  ++g_failures;
  carty_sayf(stderr, "FAIL: %s (got %lld, want %lld)\n", msg, actual, expected);
}
#define CHECK_EQ(actual, expected, msg) \
  check_eq(static_cast<long long>(actual), static_cast<long long>(expected), (msg))

constexpr int32_t kVisionSidePx = 224;  // a Gemma vision tower input is 224x224x3
constexpr int32_t kVisionChannels = 3;
constexpr unsigned char kPoison = 0xAB;  // detects un-terminated writes

inline uint8_t seg_byte(size_t offset) { return carty_test_byte(offset); }

/* the byte frame_idx of a clip carries at offset, so each frame differs (simulated motion) */
inline uint8_t clip_byte(size_t offset, int frame_idx) {
  return static_cast<uint8_t>(static_cast<unsigned>(seg_byte(offset)) + static_cast<unsigned>(frame_idx));
}

/* ---- 1. Mock multimodal block through the tensor pipeline ---------------- */
void test_multimodal_block_safe_fail(void) {
  /* A 224x224x3 image segment — the shape a Gemma vision tower input takes. */
  CartyFrame *segment = carty_frame_alloc(kVisionSidePx, kVisionSidePx, kVisionChannels);
  CHECK_QUIET(segment != nullptr, "image-segment frame allocated");
  const size_t seg_bytes = carty_frame_size(segment);
  uint8_t *pixels = carty_frame_data(segment);
  for (size_t i = 0; i < seg_bytes; ++i) {
    pixels[i] = seg_byte(i);
  }

  CartyModel *model = carty_model_load("/tmp/gemma4_e2b.tflite");
  CHECK_QUIET(model != nullptr, "model handle created (path stashed; weights stubbed)");

  char out[CARTY_MAP_UPDATE_MAX];
  std::memset(out, kPoison, sizeof(out));

  /* Normalized spatial region of interest (upper-left quadrant). */
  const int32_t status = carty_infer_map_update(model, segment, "Map this region.",
                                             0.0F, 0.0F, 0.5F, 0.5F, out,
                                             static_cast<int32_t>(sizeof(out)));

  /* LiteRT not linked => must fail SAFELY, not crash. */
  CHECK_EQ(status, CARTY_INFER_ENOMODEL, "multimodal infer fails safely (ENOMODEL)");
  CHECK_QUIET(out[0] == '\0', "output buffer left empty + NUL-terminated on safe fail");

  /* The image-segment bytes survived the call bit-for-bit (no corruption). */
  bool intact = true;
  const uint8_t *readback = carty_frame_data(segment);
  for (size_t i = 0; i < seg_bytes; ++i) {
    if (readback[i] != seg_byte(i)) {
      intact = false;
      break;
    }
  }
  CHECK_QUIET(intact, "image-segment tensor intact after passthrough (no poison)");

  carty_model_free(model);
  carty_frame_free(segment);
}

/* ---- 1b. Mock VIDEO block (frame sequence) through the tensor pipeline ----
 * A video is an ordered sequence of frames. The real pipeline will loop the
 * per-frame ABI; prove that loop is SAFE end-to-end without weights: every
 * frame fails safely (ENOMODEL), no buffer is corrupted, no crash, across a
 * short clip. Bounded by construction — a fixed, small frame count. */
void test_video_block_safe_fail(void) {
  const int kFrames = 4; /* short clip; bounded */
  CartyModel *model = carty_model_load("/tmp/gemma4_e2b.tflite");
  CHECK_QUIET(model != nullptr, "video: model handle created (weights stubbed)");

  char out[CARTY_MAP_UPDATE_MAX];
  for (int frame_idx = 0; frame_idx < kFrames; ++frame_idx) {
    CartyFrame *segment = carty_frame_alloc(kVisionSidePx, kVisionSidePx, kVisionChannels);
    CHECK_QUIET(segment != nullptr, "video: per-frame segment allocated");
    const size_t seg_bytes = carty_frame_size(segment);
    uint8_t *pixels = carty_frame_data(segment);
    for (size_t i = 0; i < seg_bytes; ++i) {
      pixels[i] = clip_byte(i, frame_idx);
    }

    std::memset(out, kPoison, sizeof(out)); /* poison between frames */
    const int32_t status = carty_infer_map_update(
        model, segment, "Track features across the clip.", 0.0F, 0.0F, 1.0F,
        1.0F, out, static_cast<int32_t>(sizeof(out)));

    CHECK_EQ(status, CARTY_INFER_ENOMODEL, "video: per-frame infer fails safely");
    CHECK_QUIET(out[0] == '\0', "video: per-frame output empty + NUL-terminated");

    bool intact = true;
    const uint8_t *readback = carty_frame_data(segment);
    for (size_t i = 0; i < seg_bytes; ++i) {
      if (readback[i] != clip_byte(i, frame_idx)) {
        intact = false;
        break;
      }
    }
    CHECK_QUIET(intact, "video: per-frame tensor intact after passthrough");
    carty_frame_free(segment);
  }
  carty_model_free(model);
}

}  // namespace

int main(void) {
  test_multimodal_block_safe_fail();
  test_video_block_safe_fail();

  return carty_finish("ALL MULTIMODAL INFERENCE TESTS PASSED");
}
