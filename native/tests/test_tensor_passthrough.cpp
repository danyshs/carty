/*
 * test_tensor_passthrough.cpp — isolated "dummy tensor" pass-through test for
 * the Carty FFI bridge.
 *
 * PURPOSE (test-first, FFI boundary):
 *   Prove that a dummy byte tensor can be pushed across the SAME FFI surface
 *   Dart uses (carty_frame_alloc / carty_frame_data / carty_frame_size /
 *   carty_frame_free) and read back bit-for-bit with NO corruption, NO memory
 *   poisoning, and NO leak — completely isolated from the Flutter UI and from
 *   LiteRT (which is intentionally NOT linked yet; this is the buffer contract
 *   the future inference path will sit on top of).
 *
 *   A CartyFrame's owned buffer is exactly an NHWC uint8 tensor of
 *   shape [height, width, channels] laid out row-major — i.e. the shape a
 *   model input tensor (e.g. 224x224x3) takes. We treat width=W, height=H,
 *   channels=C as a tensor and verify the round-trip.
 *
 * MEMORY VERIFICATION:
 *   This binary is also compiled with -fsanitize=address (and LeakSanitizer,
 *   on by default with ASan) by the harness build step. ASan detects
 *   poisoning / out-of-bounds / use-after-free; LSan reports any leaked
 *   allocation at exit. A clean exit code under ASan is the leak/poison gate.
 *
 * CONFIDENCE / STABILITY:
 *   The full pass-through is repeated kIterations times over several tensor
 *   shapes. We report the observed pass rate; deterministic correct code
 *   yields 100%. The gate requires >= 95%.
 *
 * Dependency-free (no gtest) to keep the Nix build pure, matching
 * test_bridge.cpp's tiny CHECK harness.
 */
#include "carty_bridge.h"
#include "carty_check.h"

#include <cstdint>
#include <cstdio>
#include <cstring>



namespace {

inline uint8_t dummy_byte(size_t offset) { return carty_test_byte(offset); }

/* One full dummy-tensor pass-through through the FFI bridge.
 * Returns true iff every invariant held. No abort paths are taken on the
 * happy path (NULL/out-of-range are death tests, excluded by design). */
struct Shape {
  int32_t width, height, channels;
  const char *name;
};

bool tensor_passthrough_once(const Shape &shape) {
  const size_t expected = static_cast<size_t>(shape.width) *
                          static_cast<size_t>(shape.height) *
                          static_cast<size_t>(shape.channels);

  CartyFrame *tensor = carty_frame_alloc(shape.width, shape.height, shape.channels);
  if (tensor == nullptr) {
    return false;
  }

  bool held = true;

  /* Size must equal the tensor element count (uint8 elements). */
  held &= (carty_frame_size(tensor) == expected);

  /* Bridge guarantees zero-init: every element starts at 0. */
  uint8_t *data = carty_frame_data(tensor);
  if (data == nullptr) {
    carty_frame_free(tensor);
    return false;
  }
  for (size_t i = 0; i < expected; ++i) {
    if (data[i] != 0) { held = false; break; }
  }

  /* Write the dummy tensor through the BORROWED pointer (zero-copy path). */
  for (size_t i = 0; i < expected; ++i) {
    data[i] = dummy_byte(i);
  }

  /* Re-fetch the pointer (mirrors Dart re-deriving the asTypedList view) and
   * verify the pass-through is bit-for-bit intact — no poisoning, no overlap,
   * no truncation at the boundary. */
  const uint8_t *readback = carty_frame_data(tensor);
  for (size_t i = 0; i < expected; ++i) {
    if (readback[i] != dummy_byte(i)) { held = false; break; }
  }

  /* Endpoints exactly (cheap explicit boundary check). */
  held &= (readback[0] == dummy_byte(0));
  held &= (readback[expected - 1] == dummy_byte(expected - 1));

  carty_frame_free(tensor);
  return held;
}

}  // namespace

int main(void) {
  /* Tensor shapes (w, h, c): a tiny tensor, a typical model input
   * (224x224x3), and a 1080p RGBA video frame — the real workload. */
  const Shape shapes[] = {
      {8, 8, 3, "tiny 8x8x3"},
      {224, 224, 3, "model-input 224x224x3"},
      {1920, 1080, 4, "video-frame 1920x1080x4 (RGBA)"},
  };
  const int kShapes = static_cast<int>(sizeof(shapes) / sizeof(shapes[0]));
  const int kIterations = 1000; /* per shape — bounded by construction */

  long long total = 0;
  long long passed = 0;
  for (int shape_idx = 0; shape_idx < kShapes; ++shape_idx) {
    const Shape &shape = shapes[shape_idx];
    long long shape_pass = 0;
    for (int it = 0; it < kIterations; ++it) {
      ++total;
      if (tensor_passthrough_once(shape)) {
        ++passed;
        ++shape_pass;
      }
    }
    carty_sayf(stdout, "shape %-34s : %lld/%d pass-throughs OK\n", shape.name, shape_pass,
               kIterations);
  }

  const double rate = total > 0 ? (100.0 * static_cast<double>(passed) /
                                   static_cast<double>(total))
                                : 0.0;
  carty_sayf(stdout, "\ndummy-tensor pass-through confidence: %lld/%lld = %.2f%%\n", passed,
             total, rate);

  /* Gate: >= 95% pass rate AND zero hard CHECK failures. */
  constexpr double kGatePct = 95.0;
  CHECK_QUIET(rate >= kGatePct, "pass-through confidence >= 95%");
  CHECK_QUIET(passed == total, "all pass-throughs succeeded (bit-for-bit, no poison)");

  return carty_finish("ALL TENSOR PASS-THROUGH TESTS PASSED");
}
