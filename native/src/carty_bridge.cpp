/*
 * carty_bridge.cpp — implementation of the Carty native bridge C ABI.
 *
 * Tiger Style: assertions are live invariants in ALL builds, so
 * we use CARTY_ASSERT (which always aborts) rather than <cassert>'s assert(),
 * which the compiler strips under NDEBUG.
 */
#include "carty_bridge.h"
#include "carty_bridge_internal.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>

/* This translation unit holds the bridge "core": the version string and the
 * Geometric->Semantic FUSION entry points (carty_ortho_to_spatial_prompt +
 * carty_infer_map_update_ortho). Frame buffers, the model handle + ROI
 * inference, and ortho projection live in carty_frame.cpp / carty_model.cpp /
 * carty_ortho.cpp; the shared structs, CARTY_ASSERT, and the LiteRT subprocess
 * driver come from carty_bridge_internal.h. */

extern "C" const char *carty_version(void) {
  const char *version = CARTY_VERSION_STRING;
  /* Postconditions. */
  CARTY_ASSERT(version != nullptr, "version string is null");
  CARTY_ASSERT(version[0] != '\0', "version string is empty");
  return version;
}

namespace {

/* fixed coarse resolution of the text grid: kCoarseSide x kCoarseSide glyphs */
constexpr int32_t kCoarseSide = 16;
constexpr char kRamp[] = " .:-=+*#%@"; /* 10 levels; [0]=' '=unobserved */
constexpr int32_t kRampTop = static_cast<int32_t>(sizeof(kRamp) - 2); /* '@' index */

/* One glyph for coarse block (block_x, block_y): its cells' mean occupancy on the ramp.
 * Integer block-averaging keeps the prompt byte-deterministic. */
char coarse_glyph(const CartyOrthoMap *map, int32_t block_x, int32_t block_y) {
  const int32_t map_width = map->width;
  const int32_t map_height = map->height;
  const int32_t cell_x_begin =
      static_cast<int32_t>(static_cast<int64_t>(block_x) * map_width / kCoarseSide);
  const int32_t cell_y_begin =
      static_cast<int32_t>(static_cast<int64_t>(block_y) * map_height / kCoarseSide);
  // a map narrower than the coarse grid still gives every block one cell
  const int32_t cell_x_end = std::min(
      std::max(static_cast<int32_t>(static_cast<int64_t>(block_x + 1) * map_width / kCoarseSide),
               cell_x_begin + 1),
      map_width);
  const int32_t cell_y_end = std::min(
      std::max(static_cast<int32_t>(static_cast<int64_t>(block_y + 1) * map_height / kCoarseSide),
               cell_y_begin + 1),
      map_height);
  uint64_t block_sum = 0;
  int32_t block_count = 0;
  for (int32_t cell_y = cell_y_begin; cell_y < cell_y_end; ++cell_y) {
    for (int32_t cell_x = cell_x_begin; cell_x < cell_x_end; ++cell_x) {
      block_sum += map->cells[(static_cast<size_t>(cell_y) * map_width) + cell_x];
      block_count++;
    }
  }
  if (block_count == 0) {
    return ' ';
  }
  const int32_t mean = static_cast<int32_t>(block_sum / static_cast<uint64_t>(block_count));
  if (mean == 0) {
    return ' ';
  }
  const int32_t level = 1 + ((mean * (kRampTop - 1)) / UINT8_MAX);
  return kRamp[std::min(std::max(level, 1), kRampTop)];
}

}  // namespace

extern "C" int32_t carty_ortho_to_spatial_prompt(const CartyOrthoMap *map,
                                                 const char *instruction,
                                                 int32_t instruction_len,
                                                 char *out_buf,
                                                 int32_t out_buf_size) {
  /* Boundary: crash immediately on any NULL/invalid handle (Tiger Style). */
  CARTY_ASSERT(map != nullptr, "null ortho map handle at boundary");
  CARTY_ASSERT(map->cells != nullptr, "ortho map has null cells");
  CARTY_ASSERT(map->width > 0 && map->height > 0, "ortho map has non-positive dims");
  CARTY_ASSERT(map->size == static_cast<size_t>(map->width) *
                               static_cast<size_t>(map->height),
               "ortho map size invariant violated");
  CARTY_ASSERT(out_buf != nullptr, "null output buffer at boundary");
  CARTY_ASSERT(out_buf_size > 0, "output buffer size must be positive");
  CARTY_ASSERT(instruction != nullptr, "null instruction at boundary");
  CARTY_ASSERT(instruction_len >= 0, "negative instruction length at boundary");
  out_buf[0] = '\0';

  /* Pass 1: observed footprint + mean intensity (bounded over the fixed grid). */
  size_t observed = 0;
  uint64_t sum = 0;
  for (size_t i = 0; i < map->size; ++i) {
    const uint8_t cell_value = map->cells[i];
    if (cell_value != 0) {
      observed++;
    }
    sum += cell_value;
  }
  const double obs_pct = 100.0 * static_cast<double>(observed) /
                         static_cast<double>(map->size);
  const double mean = static_cast<double>(sum) / static_cast<double>(map->size);

  /* Build into a bounded local buffer, then copy iff it fits the caller's buffer.
   * The coarse downsample renders the grid's structure as text the (text-only)
   * runtime can read. */
  char tmp[CARTY_SPATIAL_PROMPT_MAX];
  int off = std::snprintf(
      tmp, sizeof(tmp),
      "%.*s\n\nSpatial Context — top-down occupancy grid:\n"
      "  source grid: %dx%d cells; observed footprint: %.1f%% of cells; "
      "mean intensity: %.1f/255.\n"
      "  coarse %dx%d occupancy map (' '=unobserved, '@'=most occupied):\n",
      instruction_len, instruction, map->width, map->height, obs_pct, mean, kCoarseSide,
      kCoarseSide);
  if (off < 0 || off >= static_cast<int>(sizeof(tmp))) {
    return CARTY_INFER_ENOSPACE;
  }

  for (int32_t block_y = 0; block_y < kCoarseSide; ++block_y) {
    /* Each row: 2-space indent + kCoarseSide glyphs + newline. Bound-check before write. */
    if (off + 2 + kCoarseSide + 1 >= static_cast<int>(sizeof(tmp))) {
      return CARTY_INFER_ENOSPACE;
    }
    tmp[off++] = ' ';
    tmp[off++] = ' ';
    for (int32_t block_x = 0; block_x < kCoarseSide; ++block_x) {
      tmp[off++] = coarse_glyph(map, block_x, block_y);
    }
    tmp[off++] = '\n';
  }
  CARTY_ASSERT(off < static_cast<int>(sizeof(tmp)), "spatial prompt overran tmp");
  tmp[off] = '\0';

  const int32_t needed = off + 1; /* incl NUL */
  if (needed > out_buf_size) {
    return CARTY_INFER_ENOSPACE;
  }
  std::memcpy(out_buf, tmp, static_cast<size_t>(needed));

  /* Postconditions: NUL-terminated, carries the instruction + grid framing. */
  CARTY_ASSERT(out_buf[needed - 1] == '\0', "spatial prompt not NUL-terminated");
  return needed;
}

extern "C" int32_t carty_infer_map_update_ortho(const CartyModel *model,
                                                const CartyOrthoMap *map,
                                                const char *instruction,
                                                int32_t instruction_len,
                                                char *output_buf,
                                                int32_t output_buf_size) {
  /* Boundary: crash immediately on any NULL handle / buffer (Tiger Style). */
  CARTY_ASSERT(model != nullptr, "null model handle at boundary");
  CARTY_ASSERT(model->model_path != nullptr, "model has null path");
  CARTY_ASSERT(map != nullptr, "null ortho map handle at boundary");
  CARTY_ASSERT(map->cells != nullptr, "ortho map has null cells");
  CARTY_ASSERT(output_buf != nullptr, "null output buffer at boundary");
  CARTY_ASSERT(output_buf_size > 0, "output buffer size must be positive");
  CARTY_ASSERT(instruction != nullptr, "null instruction at boundary");
  CARTY_ASSERT(instruction_len >= 0, "negative instruction length at boundary");
  output_buf[0] = '\0';

#ifdef CARTY_HAVE_LITERT
  /* Condition the decode on the occupancy grid: serialize the Spatial Context
   * prompt, then decode against the resident engine in-process. The grid summary
   * is bounded by construction, so serialization cannot fail here, but propagate
   * any negative status honestly rather than fabricating. */
  char prompt[CARTY_SPATIAL_PROMPT_MAX];
  const int32_t prompt_len = carty_ortho_to_spatial_prompt(map, instruction,
                                                           instruction_len, prompt,
                                                           sizeof(prompt));
  if (prompt_len < 0) {
    return prompt_len;
  }
  return carty_generate_inprocess(model, prompt, output_buf, output_buf_size);
#else
  /* LiteRT not linked (e.g. Android cross-build before the JNI path, or a stripped
   * host build): the bridge owns no reachable runtime, so the only honest result
   * is a SAFE failure — never a fabricated map (mirrors carty_infer_map_update). */
  (void)map;
  (void)instruction;
  (void)instruction_len;
  return CARTY_INFER_ENOMODEL;
#endif
}
