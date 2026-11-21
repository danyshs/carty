/*
 * carty_ortho.cpp — Geometric stage: orthorectification (one of the carty_bridge
 * translation units;.
 *
 * Turns a raw, oblique RGBA video frame into a stable top-down occupancy grid via
 * a planar (ground-plane Z=0) homography derived from CALIBRATED camera
 * intrinsics K and a fixed extrinsic pose (height + downward pitch). The math is
 * closed-form double-precision; OpenCV (when linked) does the resampling with
 * cv::warpPerspective, otherwise a bounded inverse-map sampler does. Both are
 * deterministic, so the same frame always yields a byte-identical grid — the
 * "stable 2D spatial coordinates" the pipeline relies on. This is
 * the no-LLM geometry seam; it owns the CartyOrthoMap lifecycle.
 */
#include "carty_bridge.h"
#include "carty_bridge_internal.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <limits>

#ifdef CARTY_HAVE_OPENCV
/* Geometric stage: OpenCV provides cv::warpPerspective for the orthorectifying
 * planar homography. Only core+imgproc are needed (no highgui/io). The hand-
 * rolled inverse-map sampler below the #else is the dependency-free fallback. */
#include <opencv2/core/base.hpp>          // cv::BORDER_CONSTANT
#include <opencv2/core/hal/interface.h>  // CV_8UC1/3/4, CV_64F
#include <opencv2/core/mat.hpp>          // cv::Mat
#include <opencv2/core/types.hpp>        // cv::Size, cv::Scalar
#include <opencv2/imgproc.hpp>
#endif

/* Fixed extrinsic pose. A handheld recording of a floor looks steeply downward;
 * a pitch >= 45deg keeps the ground-plane horizon off the top of the frame, so
 * every image corner back-projects to a finite ground point (no horizon
 * singularity). Camera height only scales the metric labels — it cancels in the
 * image->ground->image round trip — so the resampling is height-independent. */
#define CARTY_ORTHO_PITCH_RAD 1.0471975511965976 /* 60 deg below horizontal */
#define CARTY_ORTHO_CAM_HEIGHT 1.6                /* meters (label scale only) */

namespace {

/* Minimal row-major 3x3 double matrix — bounded, dependency-free linear algebra
 * for the homography. No heap, no loops over unknown bounds (Tiger Style). */
constexpr int kMatDim = 3;
struct Mat3 {
  double m[kMatDim * kMatDim];
};

/* element (row, col) */
double at(const Mat3 &matrix, int row, int col) { return matrix.m[(row * kMatDim) + col]; }

Mat3 mat3_mul(const Mat3 &lhs, const Mat3 &rhs) {
  Mat3 product;
  for (int row = 0; row < kMatDim; ++row) {
    for (int col = 0; col < kMatDim; ++col) {
      product.m[(row * kMatDim) + col] = (at(lhs, row, 0) * at(rhs, 0, col)) +
                                         (at(lhs, row, 1) * at(rhs, 1, col)) +
                                         (at(lhs, row, 2) * at(rhs, 2, col));
    }
  }
  return product;
}

/* Invert a 3x3 via cofactors. Aborts if singular (a degenerate calibration is a
 * programming error at the boundary, not recoverable data). */
Mat3 mat3_inverse(const Mat3 &matrix) {
  auto const elem = [&matrix](int row, int col) { return at(matrix, row, col); };
  const double c00 = (elem(1, 1) * elem(2, 2)) - (elem(1, 2) * elem(2, 1));
  const double c01 = (elem(1, 0) * elem(2, 2)) - (elem(1, 2) * elem(2, 0));
  const double c02 = (elem(1, 0) * elem(2, 1)) - (elem(1, 1) * elem(2, 0));
  const double det = (elem(0, 0) * c00) - (elem(0, 1) * c01) + (elem(0, 2) * c02);
  CARTY_ASSERT(det != 0.0 && det == det, "singular homography (bad intrinsics)");
  const double inv_det = 1.0 / det;
  return {{
      c00 * inv_det,
      -((elem(0, 1) * elem(2, 2)) - (elem(0, 2) * elem(2, 1))) * inv_det,
      ((elem(0, 1) * elem(1, 2)) - (elem(0, 2) * elem(1, 1))) * inv_det,
      -c01 * inv_det,
      ((elem(0, 0) * elem(2, 2)) - (elem(0, 2) * elem(2, 0))) * inv_det,
      -((elem(0, 0) * elem(1, 2)) - (elem(0, 2) * elem(1, 0))) * inv_det,
      c02 * inv_det,
      -((elem(0, 0) * elem(2, 1)) - (elem(0, 1) * elem(2, 0))) * inv_det,
      ((elem(0, 0) * elem(1, 1)) - (elem(0, 1) * elem(1, 0))) * inv_det,
  },};
}

/* Apply a projective transform to (in_x, in_y); writes the dehomogenised result and
 * returns the homogeneous w. The caller treats w <= 0 as "behind the camera". */
double mat3_project(const Mat3 &transform, double in_x, double in_y, double *out_x,
                    double *out_y) {
  const double proj_x = (at(transform, 0, 0) * in_x) + (at(transform, 0, 1) * in_y) +
                        at(transform, 0, 2);
  const double proj_y = (at(transform, 1, 0) * in_x) + (at(transform, 1, 1) * in_y) +
                        at(transform, 1, 2);
  const double proj_w = (at(transform, 2, 0) * in_x) + (at(transform, 2, 1) * in_y) +
                        at(transform, 2, 2);
  if (proj_w != 0.0) {
    *out_x = proj_x / proj_w;
    *out_y = proj_y / proj_w;
  } else {
    *out_x = 0.0;
    *out_y = 0.0;
  }
  return proj_w;
}

/* Ground->image planar homography G = K[r1 r2 t] for a camera at the fixed pose.
 * World: X right, Y forward on the ground, Z up. Camera (OpenCV axes) pitched
 * `p` below horizontal at height Hc. r1=(1,0,0), r2=(0,-sin p,cos p),
 * t=(0,Hc cos p,Hc sin p); fx=fy=max(w,h) (~square pixels), principal point at
 * the image centre. */
Mat3 carty_ground_to_image(int32_t width, int32_t height) {
  const double focal_x_px = static_cast<double>(width > height ? width : height);
  const double focal_y_px = focal_x_px;
  const double center_x_px = width * 0.5;
  const double center_y_px = height * 0.5;
  const double sin_pitch = std::sin(CARTY_ORTHO_PITCH_RAD);
  const double cos_pitch = std::cos(CARTY_ORTHO_PITCH_RAD);
  const double cam_height_m = CARTY_ORTHO_CAM_HEIGHT;

  const Mat3 intrinsics = {{focal_x_px, 0.0, center_x_px, 0.0, focal_y_px, center_y_px, 0.0,
                            0.0, 1.0,},};
  /* columns r1 | r2 | t */
  const Mat3 extrinsic_cols = {{1.0, 0.0, 0.0,
                                0.0, -sin_pitch, cam_height_m * cos_pitch,
                                0.0, cos_pitch, cam_height_m * sin_pitch,},};
  return mat3_mul(intrinsics, extrinsic_cols);
}

/* Metric ground footprint of the camera-local frame: the bounding box of the four image
 * corners back-projected onto the ground, so the whole visible floor maps into the grid. */
struct Footprint {
  double min_x, max_x, min_y, max_y;
};

/* a frame's size in pixels; one struct so width and height can't be swapped */
struct PixelDims {
  int32_t width;
  int32_t height;
};

Footprint ground_footprint(const Mat3 &image_to_ground, PixelDims dims) {
  constexpr int kCorners = 4;
  const double last_x = static_cast<double>(dims.width - 1);
  const double last_y = static_cast<double>(dims.height - 1);
  const double corners[kCorners][2] = {{0.0, 0.0}, {last_x, 0.0}, {last_x, last_y}, {0.0, last_y}};
  constexpr double kFar = std::numeric_limits<double>::max();
  Footprint box = {kFar, -kFar, kFar, -kFar};
  for (const auto &corner : corners) {
    double ground_x = 0.0;
    double ground_y = 0.0;
    const double proj_w = mat3_project(image_to_ground, corner[0], corner[1], &ground_x, &ground_y);
    CARTY_ASSERT(proj_w != 0.0 && ground_x == ground_x && ground_y == ground_y,
                 "corner back-projection degenerate");
    box.min_x = std::min(ground_x, box.min_x);
    box.max_x = std::max(ground_x, box.max_x);
    box.min_y = std::min(ground_y, box.min_y);
    box.max_y = std::max(ground_y, box.max_y);
  }
  CARTY_ASSERT(box.max_x > box.min_x && box.max_y > box.min_y, "degenerate ortho footprint");
  return box;
}

#ifndef CARTY_HAVE_OPENCV
/* Dependency-free inverse-map sampler: for each ortho cell, project to the source pixel
 * and bilinearly sample the grayscale (R+G+B average). Cells mapping behind the camera or
 * outside the image stay unobserved (0). */
void sample_ortho(const CartyFrame *buffer, PixelDims dims, int32_t channels,
                  const Mat3 &cell_to_image, const CartyOrthoMap *map) {
  constexpr double kGrayChannels = 3.0;  // R, G and B, alpha ignored
  const int32_t width = dims.width;
  const int32_t height = dims.height;
  const uint8_t *pixels = buffer->data;
  auto const gray_at = [&](int32_t pixel_x, int32_t pixel_y) -> double {
    const uint8_t *pixel =
        pixels + (((static_cast<size_t>(pixel_y) * width) + pixel_x) * channels);
    return (static_cast<double>(pixel[0]) + pixel[1] + pixel[2]) / kGrayChannels;
  };
  for (int32_t cell_y = 0; cell_y < map->height; ++cell_y) {
    for (int32_t cell_x = 0; cell_x < map->width; ++cell_x) {
      double src_x = 0.0;
      double src_y = 0.0;
      const double proj_w = mat3_project(cell_to_image, static_cast<double>(cell_x),
                                         static_cast<double>(cell_y), &src_x, &src_y);
      if (proj_w <= 0.0) {
        continue; /* behind the camera: unobserved */
      }
      if (src_x < 0.0 || src_y < 0.0 || src_x > width - 1.0 || src_y > height - 1.0) {
        continue; /* outside the source image: unobserved */
      }
      const int32_t src_x0 = static_cast<int32_t>(src_x);
      const int32_t src_y0 = static_cast<int32_t>(src_y);
      const int32_t src_x1 = src_x0 + 1 < width ? src_x0 + 1 : src_x0;
      const int32_t src_y1 = src_y0 + 1 < height ? src_y0 + 1 : src_y0;
      const double frac_x = src_x - src_x0;
      const double frac_y = src_y - src_y0;
      const double top = (gray_at(src_x0, src_y0) * (1.0 - frac_x)) +
                         (gray_at(src_x1, src_y0) * frac_x);
      const double bot = (gray_at(src_x0, src_y1) * (1.0 - frac_x)) +
                         (gray_at(src_x1, src_y1) * frac_x);
      const double gray = std::min(std::max((top * (1.0 - frac_y)) + (bot * frac_y), 0.0),
                                   static_cast<double>(UINT8_MAX));
      map->cells[(static_cast<size_t>(cell_y) * map->width) + cell_x] =
          static_cast<uint8_t>(std::lround(gray));
    }
  }
}
#endif

/* The owned occupancy grid, zeroed (all unobserved), carrying the metric footprint
 * (camera-local ground frame) so fusion can place each observed cell in the world. */
CartyOrthoMap *alloc_ortho_map(PixelDims dims, const Footprint &box) {
  CartyOrthoMap *map = static_cast<CartyOrthoMap *>(std::malloc(sizeof(CartyOrthoMap)));
  CARTY_ASSERT(map != nullptr, "ortho map handle allocation failed");
  const size_t cell_count = static_cast<size_t>(dims.width) * static_cast<size_t>(dims.height);
  map->cells = static_cast<uint8_t *>(std::calloc(cell_count, 1));
  CARTY_ASSERT(map->cells != nullptr, "ortho cell allocation failed");
  map->width = dims.width;
  map->height = dims.height;
  map->size = cell_count;
  map->min_x = box.min_x;
  map->max_x = box.max_x;
  map->min_y = box.min_y;
  map->max_y = box.max_y;
  return map;
}

}  // namespace

extern "C" CartyOrthoMap *carty_ortho_project(const CartyFrame *buffer, int32_t width,
                                              int32_t height, int32_t channels) {
  /* Boundary: crash immediately on any NULL/invalid handle (Tiger Style). */
  CARTY_ASSERT(buffer != nullptr, "null frame handle at boundary");
  CARTY_ASSERT(buffer->data != nullptr, "frame has null buffer");
  CARTY_ASSERT(width > 0 && width <= CARTY_FRAME_MAX_DIM, "width out of range");
  CARTY_ASSERT(height > 0 && height <= CARTY_FRAME_MAX_DIM, "height out of range");
  CARTY_ASSERT(channels == 3 || channels == 4, "channels must be 3 (RGB) or 4 (RGBA)");
  const size_t expect = static_cast<size_t>(width) *
                        static_cast<size_t>(height) *
                        static_cast<size_t>(channels);
  CARTY_ASSERT(buffer->size == expect, "pixel dims do not match frame size");

  /* Calibrated planar homographies, ground->image and its inverse. */
  const Mat3 ground_to_image = carty_ground_to_image(width, height);
  const Footprint box = ground_footprint(mat3_inverse(ground_to_image), {width, height});

  const int32_t ortho_width = CARTY_ORTHO_DIM;
  const int32_t ortho_height = CARTY_ORTHO_DIM;
  CARTY_ASSERT(ortho_width > 0 && ortho_width <= CARTY_ORTHO_MAX_DIM && ortho_height > 0 &&
                   ortho_height <= CARTY_ORTHO_MAX_DIM,
               "ortho grid out of bounds");

  /* ortho cell (cell_x, cell_y) -> ground (X,Y). Row 0 is the FAR edge (max_y), the
   * bottom row is NEAR (min_y), so the grid reads like a top-down map. */
  const double step_x_m = (box.max_x - box.min_x) / static_cast<double>(ortho_width - 1);
  const double step_y_m = -(box.max_y - box.min_y) / static_cast<double>(ortho_height - 1);
  const Mat3 cell_to_ground = {{step_x_m, 0.0, box.min_x,
                                0.0, step_y_m, box.max_y,
                                0.0, 0.0, 1.0,},};
  /* ortho cell -> image pixel (dst->src), i.e. the inverse warp map. */
  const Mat3 cell_to_image = mat3_mul(ground_to_image, cell_to_ground);

  CartyOrthoMap *map = alloc_ortho_map({ortho_width, ortho_height}, box);
  const size_t cell_count = map->size;

#ifdef CARTY_HAVE_OPENCV
  /* Resample with OpenCV: wrap the frame zero-copy, convert to grayscale, then
   * warpPerspective with WARP_INVERSE_MAP (cell_to_image is the dst->src map).
   * BORDER_CONSTANT 0 leaves off-image ortho cells unobserved. */
  const cv::Mat frame_view(height, width, channels == 4 ? CV_8UC4 : CV_8UC3,
                           buffer->data);
  cv::Mat gray;
  cv::cvtColor(frame_view, gray,
               channels == 4 ? cv::COLOR_RGBA2GRAY : cv::COLOR_RGB2GRAY);
  cv::Mat hmat(kMatDim, kMatDim, CV_64F);
  for (int row = 0; row < kMatDim; ++row) {
    for (int col = 0; col < kMatDim; ++col) {
      hmat.at<double>(row, col) = at(cell_to_image, row, col);
    }
  }
  cv::Mat ortho;
  cv::warpPerspective(gray, ortho, hmat, cv::Size(ortho_width, ortho_height),
                      cv::INTER_LINEAR | cv::WARP_INVERSE_MAP,
                      cv::BORDER_CONSTANT, cv::Scalar(0));
  CARTY_ASSERT(ortho.rows == ortho_height && ortho.cols == ortho_width &&
                   ortho.type() == CV_8UC1,
               "warpPerspective produced an unexpected ortho shape");
  for (int32_t row = 0; row < ortho_height; ++row) {
    std::memcpy(map->cells + (static_cast<size_t>(row) * ortho_width), ortho.ptr<uint8_t>(row),
                static_cast<size_t>(ortho_width));
  }
#else
  sample_ortho(buffer, {width, height}, channels, cell_to_image, map);
#endif

  /* Postconditions: owned grid, well-formed, bounded. */
  CARTY_ASSERT(map->cells != nullptr && map->size == cell_count &&
                   map->width == ortho_width && map->height == ortho_height,
               "ortho map invariant violated");
  return map;
}

extern "C" int32_t carty_ortho_map_width(const CartyOrthoMap *map) {
  CARTY_ASSERT(map != nullptr, "null ortho map handle at boundary");
  CARTY_ASSERT(map->width > 0, "ortho map has non-positive width");
  return map->width;
}

extern "C" int32_t carty_ortho_map_height(const CartyOrthoMap *map) {
  CARTY_ASSERT(map != nullptr, "null ortho map handle at boundary");
  CARTY_ASSERT(map->height > 0, "ortho map has non-positive height");
  return map->height;
}

extern "C" const uint8_t *carty_ortho_map_cells(const CartyOrthoMap *map) {
  CARTY_ASSERT(map != nullptr, "null ortho map handle at boundary");
  CARTY_ASSERT(map->cells != nullptr, "ortho map has null cells");
  return map->cells;
}

extern "C" size_t carty_ortho_map_size(const CartyOrthoMap *map) {
  CARTY_ASSERT(map != nullptr, "null ortho map handle at boundary");
  CARTY_ASSERT(map->size > 0, "ortho map has zero size");
  return map->size;
}

extern "C" void carty_ortho_map_extent(const CartyOrthoMap *map, double *min_x,
                                       double *max_x, double *min_y,
                                       double *max_y) {
  CARTY_ASSERT(map != nullptr, "null ortho map handle at boundary");
  CARTY_ASSERT(min_x != nullptr && max_x != nullptr && min_y != nullptr &&
                   max_y != nullptr,
               "null extent out-pointer at boundary");
  CARTY_ASSERT(map->max_x > map->min_x && map->max_y > map->min_y,
               "ortho map has a degenerate footprint extent");
  *min_x = map->min_x;
  *max_x = map->max_x;
  *min_y = map->min_y;
  *max_y = map->max_y;
}

extern "C" void carty_ortho_map_free(CartyOrthoMap *map) {
  CARTY_ASSERT(map != nullptr, "null ortho map handle at boundary");
  CARTY_ASSERT(map->cells != nullptr, "double free or corrupt ortho map");
  std::free(map->cells);
  /* Poison the handle so a use-after-free trips an assert instead of UB. */
  map->cells = nullptr;
  map->size = 0;
  map->width = 0;
  map->height = 0;
  std::free(map);
}
