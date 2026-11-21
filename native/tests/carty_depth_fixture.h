/* Shared fixture for the depth-accretion suites: an 8x8x8 grid of 0.5 m cells, fed a
 * 4x4 depth image through a pinhole centred on the image. Every suite puts its one
 * hit at pixel (u=1, v=1); at 2 m that lands in voxel band 5, row 0, col 3. */
#ifndef CARTY_DEPTH_FIXTURE_H_
#define CARTY_DEPTH_FIXTURE_H_

#include "carty_bridge.h"

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace depth_fixture {

constexpr int32_t kGridSide = 8;     // cells per side, and height bands
constexpr double kCellM = 0.5;       // cell edge and band height
constexpr int32_t kImageSidePx = 4;
constexpr size_t kImagePixels = static_cast<size_t>(kImageSidePx) * kImageSidePx;

constexpr CartyPose kIdentityPose{{
    1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1,
},};
// centre (1.5, 1.5) of a 4x4 image, focal 2 px
constexpr CartyIntrinsics kIntrinsics{2.0, 2.0, 1.5, 1.5};

constexpr int8_t kLogOddsOcc = 20;     // CARTY_FUSE_L_OCC: one full-weight fold
constexpr uint8_t kConfBelowMin = 100;  // under CARTY_FUSE_CONF_MIN (128): dropped
constexpr uint16_t kHitRangeMm = 2000;
constexpr uint16_t kNearRangeMm = 1000;  // collinear with the hit, one metre closer

struct PixelPos {
  int32_t u_px, v_px;
};
constexpr PixelPos kHitPixel{1, 1};

constexpr size_t pixel_index(PixelPos pixel) {
  return (static_cast<size_t>(pixel.v_px) * kImageSidePx) + static_cast<size_t>(pixel.u_px);
}

struct Voxel {
  int32_t band, row, col;
};
constexpr size_t voxel_index(Voxel voxel) {
  return (static_cast<size_t>((voxel.band * kGridSide) + voxel.row) * kGridSide) +
         static_cast<size_t>(voxel.col);
}
constexpr size_t kHitVoxel = voxel_index({5, 0, 3});  // kHitPixel at kHitRangeMm, identity pose

inline CartyWorldGrid *make_grid() {
  const CartyGridShape shape{kGridSide, kGridSide, kCellM, kCellM};
  return carty_world_grid_create(&shape);
}

/* one depth (and optional confidence) image with a single non-hole pixel */
struct DepthImage {
  uint16_t range_mm[kImagePixels];
  uint8_t conf[kImagePixels];
};
struct PixelSample {
  PixelPos pixel;
  uint16_t range_mm;
  uint8_t confidence;
};
inline void set_single_pixel(DepthImage *image, PixelSample sample) {
  std::memset(image, 0, sizeof(*image));
  image->range_mm[pixel_index(sample.pixel)] = sample.range_mm;
  image->conf[pixel_index(sample.pixel)] = sample.confidence;
}

/* fold through the fixture's pinhole; conf may be null (flat weight) */
inline int32_t fold(CartyWorldGrid *grid, const uint16_t *range_mm, const uint8_t *conf,
                    const CartyPose &pose, int64_t keyframe_id) {
  return carty_world_grid_accrete_from_depth(grid, range_mm, kImageSidePx, kImageSidePx, conf,
                                             &kIntrinsics, &pose, keyframe_id);
}

inline int64_t count_nonzero(const CartyWorldGrid *grid) {
  const int8_t *cells = carty_world_grid_cells(grid);
  const size_t cell_count = carty_world_grid_size(grid);
  int64_t nonzero = 0;
  for (size_t i = 0; i < cell_count; ++i) {
    if (cells[i] != 0) {
      ++nonzero;
    }
  }
  return nonzero;
}

}  // namespace depth_fixture

#endif /* CARTY_DEPTH_FIXTURE_H_ */
