/*
 * carty_frame.cpp — bridge-owned video frame buffers (one of the carty_bridge
 * translation units;.
 *
 * Owns the multi-MB pixel-buffer surface Dart shares zero-copy via FFI: alloc,
 * the borrowed data/size accessors, and the single free that the Dart
 * NativeFinalizer is bound to. Lives in its own TU because the frame lifecycle
 * is independent of inference and ortho geometry and is exercised on its own by
 * the tensor-passthrough memory-poison/leak gate.
 */
#include "carty_bridge.h"
#include "carty_bridge_internal.h"

#include <cstdint>
#include <cstdlib>

extern "C" CartyFrame *carty_frame_alloc(int32_t width, int32_t height,
                                         int32_t channels) {
  /* Preconditions: positive and bounded by construction. */
  CARTY_ASSERT(width > 0 && width <= CARTY_FRAME_MAX_DIM, "width out of range");
  CARTY_ASSERT(height > 0 && height <= CARTY_FRAME_MAX_DIM,
               "height out of range");
  CARTY_ASSERT(channels > 0 && channels <= CARTY_FRAME_MAX_CHANNELS,
               "channels out of range");

  /* size fits in size_t: 8192*8192*4 = 256 MiB, far below SIZE_MAX. */
  const size_t size = static_cast<size_t>(width) *
                      static_cast<size_t>(height) *
                      static_cast<size_t>(channels);
  CARTY_ASSERT(size > 0, "computed frame size is zero");

  CartyFrame *frame = static_cast<CartyFrame *>(std::malloc(sizeof(CartyFrame)));
  CARTY_ASSERT(frame != nullptr, "frame handle allocation failed");

  frame->data = static_cast<uint8_t *>(std::calloc(size, 1));
  CARTY_ASSERT(frame->data != nullptr, "frame buffer allocation failed");
  frame->size = size;

  /* Postconditions. */
  CARTY_ASSERT(frame->data != nullptr && frame->size == size,
               "frame invariant violated");
  return frame;
}

extern "C" uint8_t *carty_frame_data(const CartyFrame *frame) {
  CARTY_ASSERT(frame != nullptr, "null frame handle at boundary");
  CARTY_ASSERT(frame->data != nullptr, "frame has null buffer");
  return frame->data;
}

extern "C" size_t carty_frame_size(const CartyFrame *frame) {
  CARTY_ASSERT(frame != nullptr, "null frame handle at boundary");
  CARTY_ASSERT(frame->size > 0, "frame has zero size");
  return frame->size;
}

extern "C" void carty_frame_free(CartyFrame *frame) {
  CARTY_ASSERT(frame != nullptr, "null frame handle at boundary");
  CARTY_ASSERT(frame->data != nullptr, "double free or corrupt frame");
  std::free(frame->data);
  /* Poison the handle so a use-after-free trips an assert instead of UB. */
  frame->data = nullptr;
  frame->size = 0;
  std::free(frame);
}
