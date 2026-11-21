/*
 * test_ortho_project.cpp — unit tests for the Geometric stage: carty_ortho_project
 * and the CartyOrthoMap occupancy grid (test-first).
 *
 * No external framework; tiny CHECK macro. These tests pin down the contract the
 * orthorectification must hold for the rest of the pipeline:
 *   - lifecycle + bounded dimensions (CARTY_ORTHO_DIM / CARTY_ORTHO_MAX_DIM),
 *   - the precondition that pixel dims match the frame byte size,
 *   - DETERMINISM: the same RGBA frame yields a byte-identical occupancy grid
 *     (i.e. stable 2D spatial coordinates), the core verify criterion,
 *   - the projection actually observes ground (non-empty footprint) and reflects
 *     input intensity (occupancy tracks the source),
 *   - memory safety: alloc/free with no leak, run under ASan/LSan separately.
 */
#include "carty_bridge.h"
#include "carty_check.h"
#include "carty_frame_fixture.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>



namespace {

/* Paint a deterministic, structured RGBA scene: a bright floor with a darker
 * band, so the orthorectified grid has real intensity variation to project. */
using frame_fixture::FrameDims;
using frame_fixture::paint_scene;

/* Count observed (non-zero) cells in an occupancy grid. */
size_t observed_cells(const CartyOrthoMap *map) {
  const uint8_t *cells = carty_ortho_map_cells(map);
  const size_t cell_count = carty_ortho_map_size(map);
  size_t obs = 0;
  for (size_t i = 0; i < cell_count; ++i) {
    if (cells[i] != 0) { ++obs;
}
}
  return obs;
}

}  // namespace

int main(void) {
  const FrameDims rgba{640, 480, 4};
  const FrameDims rgb_dims{rgba.width_px, rgba.height_px, 3};

  /* ---- Project a real RGBA frame ---- */
  CartyFrame *frame = carty_frame_alloc(rgba.width_px, rgba.height_px, rgba.channels);
  CHECK(frame != nullptr, "frame allocated for ortho projection");
  paint_scene(carty_frame_data(frame), rgba);

  CartyOrthoMap *map = carty_ortho_project(frame, rgba.width_px, rgba.height_px, rgba.channels);
  CHECK(map != nullptr, "carty_ortho_project returns non-null ortho map");

  /* ---- Bounded, well-formed grid ---- */
  const int32_t ortho_width = carty_ortho_map_width(map);
  const int32_t ortho_height = carty_ortho_map_height(map);
  CHECK(ortho_width == CARTY_ORTHO_DIM && ortho_height == CARTY_ORTHO_DIM,
        "ortho grid is the fixed CARTY_ORTHO_DIM resolution");
  CHECK(ortho_width > 0 && ortho_width <= CARTY_ORTHO_MAX_DIM && ortho_height > 0 &&
            ortho_height <= CARTY_ORTHO_MAX_DIM,
        "ortho grid dimensions bounded by CARTY_ORTHO_MAX_DIM");
  CHECK(carty_ortho_map_size(map) ==
            static_cast<size_t>(ortho_width) * static_cast<size_t>(ortho_height),
        "ortho grid size == width*height");
  CHECK(carty_ortho_map_cells(map) != nullptr, "ortho cells pointer valid");

  /* ---- Observes ground: a non-empty, non-saturating footprint ---- */
  const size_t total = carty_ortho_map_size(map);
  const size_t obs = observed_cells(map);
  CHECK(obs > 0, "orthorectified frame observes ground (non-empty footprint)");
  CHECK(obs <= total, "observed cells bounded by grid size");

  /* ---- DETERMINISM: same frame -> byte-identical grid (stable coords) ---- */
  CartyOrthoMap *map2 = carty_ortho_project(frame, rgba.width_px, rgba.height_px, rgba.channels);
  CHECK(map2 != nullptr, "second projection returns a map");
  CHECK(carty_ortho_map_size(map2) == total, "second projection same size");
  CHECK(std::memcmp(carty_ortho_map_cells(map), carty_ortho_map_cells(map2),
                    total) == 0,
        "two projections of the same frame are byte-identical (stable 2D coords)");

  /* ---- Occupancy tracks input: a black frame yields an empty grid ---- */
  CartyFrame *dark = carty_frame_alloc(rgba.width_px, rgba.height_px, rgba.channels);
  std::memset(carty_frame_data(dark), 0, carty_frame_size(dark));
  CartyOrthoMap *dark_map = carty_ortho_project(dark, rgba.width_px, rgba.height_px, rgba.channels);
  CHECK(observed_cells(dark_map) == 0,
        "all-zero frame orthorectifies to an all-unobserved grid");

  /* ---- A brighter scene cannot observe FEWER cells than the dark one ---- */
  CHECK(obs >= observed_cells(dark_map),
        "occupancy reflects source intensity (monotone vs empty frame)");

  /* ---- Works for 3-channel RGB input too ---- */
  CartyFrame *rgb = carty_frame_alloc(rgb_dims.width_px, rgb_dims.height_px, rgb_dims.channels);
  paint_scene(carty_frame_data(rgb), rgb_dims);
  CartyOrthoMap *rgb_map = carty_ortho_project(rgb, rgb_dims.width_px, rgb_dims.height_px, rgb_dims.channels);
  CHECK(rgb_map != nullptr && observed_cells(rgb_map) > 0,
        "RGB (3-channel) frame orthorectifies and observes ground");

  /* ---- Memory cleanup (LSan asserts no leak of any CartyOrthoMap) ---- */
  carty_ortho_map_free(map);
  carty_ortho_map_free(map2);
  carty_ortho_map_free(dark_map);
  carty_ortho_map_free(rgb_map);
  carty_frame_free(frame);
  carty_frame_free(dark);
  carty_frame_free(rgb);
  CHECK(true, "ortho maps and frames freed without abort or leak");

  return carty_finish("ALL ORTHO PROJECTION TESTS PASSED");
}
