/* Shared frame builders for the suites that project or splat camera frames. */
#ifndef CARTY_FRAME_FIXTURE_H_
#define CARTY_FRAME_FIXTURE_H_

#include "carty_bridge.h"

#include <cstddef>
#include <cstdint>

namespace frame_fixture {

struct FrameDims {
  int32_t width_px, height_px, channels;
};

struct Rgb {
  uint8_t red, green, blue;
};

constexpr unsigned kFloorBase = 180;  // bright floor: 180..243
constexpr unsigned kTextureMask = 0x3F;
constexpr unsigned kBandDarken = 60;  // the lower half's darker band

inline uint8_t *pixel_at(uint8_t *pixels, FrameDims dims, size_t pixel_offset) {
  return pixels + (pixel_offset * static_cast<size_t>(dims.channels));
}

inline void put_pixel(uint8_t *pixel, FrameDims dims, Rgb colour) {
  pixel[0] = colour.red;
  pixel[1] = colour.green;
  pixel[2] = colour.blue;
  if (dims.channels == 4) {
    pixel[3] = UINT8_MAX;
  }
}

/* A deterministic, structured scene: a bright textured floor with a darker lower
 * band, so the orthorectified grid has real intensity variation to project. */
inline void paint_scene(uint8_t *pixels, FrameDims dims) {
  for (int32_t row = 0; row < dims.height_px; ++row) {
    for (int32_t col = 0; col < dims.width_px; ++col) {
      unsigned level =
          kFloorBase + ((static_cast<unsigned>(col) ^ static_cast<unsigned>(row)) & kTextureMask);
      if (row > dims.height_px / 2) {
        level -= kBandDarken;
      }
      const auto gray = static_cast<uint8_t>(level);
      const size_t offset = (static_cast<size_t>(row) * dims.width_px) + col;
      put_pixel(pixel_at(pixels, dims, offset), dims, {gray, gray, gray});
    }
  }
}

inline CartyFrame *make_scene_frame(FrameDims dims) {
  CartyFrame *frame = carty_frame_alloc(dims.width_px, dims.height_px, dims.channels);
  paint_scene(carty_frame_data(frame), dims);
  return frame;
}

/* every pixel one colour; caller frees with carty_frame_free */
inline CartyFrame *make_filled_frame(FrameDims dims, Rgb colour) {
  CartyFrame *frame = carty_frame_alloc(dims.width_px, dims.height_px, dims.channels);
  uint8_t *pixels = carty_frame_data(frame);
  const size_t pixel_count = static_cast<size_t>(dims.width_px) * dims.height_px;
  for (size_t offset = 0; offset < pixel_count; ++offset) {
    put_pixel(pixel_at(pixels, dims, offset), dims, colour);
  }
  return frame;
}

constexpr unsigned kGradientColStep = 4;  // any two distinct slopes give a non-uniform map
constexpr unsigned kGradientRowStep = 3;

/* a gray diagonal gradient; caller frees with carty_frame_free */
inline CartyFrame *make_gradient_frame(FrameDims dims) {
  CartyFrame *frame = carty_frame_alloc(dims.width_px, dims.height_px, dims.channels);
  if (frame == nullptr) {
    return nullptr;
  }
  uint8_t *pixels = carty_frame_data(frame);
  for (int32_t row = 0; row < dims.height_px; ++row) {
    for (int32_t col = 0; col < dims.width_px; ++col) {
      const unsigned level = (static_cast<unsigned>(col) * kGradientColStep) +
                             (static_cast<unsigned>(row) * kGradientRowStep);
      const auto gray = static_cast<uint8_t>(level & UINT8_MAX);
      const size_t offset = (static_cast<size_t>(row) * dims.width_px) + col;
      put_pixel(pixel_at(pixels, dims, offset), dims, {gray, gray, gray});
    }
  }
  return frame;
}

}  // namespace frame_fixture

#endif /* CARTY_FRAME_FIXTURE_H_ */
