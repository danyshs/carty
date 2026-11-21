/*
 * test_bridge.cpp — dependency-free unit tests for the Carty native bridge.
 *
 * The test is written before/with the implementation and must
 * pass before the symbol is considered done. No external test framework is used
 * (keeps the Nix build pure); a tiny CHECK macro tallies failures.
 *
 * Note: the crash-at-boundary paths (e.g. passing NULL, out-of-range dims) call
 * std::abort() by design and so cannot be exercised in-process without fork();
 * they are validated by code review here and will get a death-test in a later
 * phase. This file covers the happy-path contract and buffer round-tripping.
 */
#include "carty_bridge.h"
#include "carty_check.h"

#include <cstdint>
#include <cstdio>
#include <cstring>



namespace {
// any two distinct non-zero bytes: they must read back after a zero-initialised alloc
constexpr uint8_t kFirstMarker = 0xAB;
constexpr uint8_t kLastMarker = 0xCD;
}  // namespace

int main(void) {
  /* carty_version; a null here would crash every check after it */
  const char *version = carty_version();
  if (!CHECK(version != nullptr, "carty_version returns non-null")) {
    return carty_finish("unreachable");
  }
  CHECK(std::strlen(version) > 0, "carty_version returns non-empty string");

  /* carty_frame_alloc / size / data — use a realistic 1080p RGBA frame. */
  const int32_t width_px = 1920;
  const int32_t height_px = 1080;
  const int32_t channels = 4;
  const size_t expected = static_cast<size_t>(width_px) * height_px * channels;

  CartyFrame *frame = carty_frame_alloc(width_px, height_px, channels);
  CHECK(frame != nullptr, "carty_frame_alloc returns non-null handle");
  CHECK(carty_frame_size(frame) == expected, "carty_frame_size == w*h*channels");

  uint8_t *data = carty_frame_data(frame);
  if (!CHECK(data != nullptr, "carty_frame_data returns non-null buffer")) {
    return carty_finish("unreachable");
  }
  CHECK(data[0] == 0 && data[expected - 1] == 0,
        "frame buffer is zero-initialised");

  /* Round-trip: writes through the borrowed pointer are visible on re-fetch. */
  data[0] = kFirstMarker;
  data[expected - 1] = kLastMarker;
  CHECK(carty_frame_data(frame)[0] == kFirstMarker, "write/read first byte round-trips");
  CHECK(carty_frame_data(frame)[expected - 1] == kLastMarker,
        "write/read last byte round-trips");

  carty_frame_free(frame);
  CHECK(true, "carty_frame_free completed without abort");

  return carty_finish("ALL TESTS PASSED");
}
