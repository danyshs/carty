/*
 * carty_model.cpp — Gemma 4 E2B model handle, the shared IN-PROCESS LiteRT-LM
 * decode driver, and the ROI text inference entry point (one of the carty_bridge
 * translation units;.
 *
 * This TU owns the model side of the seam: the session-scoped engine handle
 * (carty_model_load/free, which loads the 2.4 GB weights ONCE and holds the
 * LiteRtLmEngine resident for the whole session), the single proven
 * in-process decode driver (carty_generate_inprocess, shared with the ortho-fusion
 * path in carty_bridge.cpp via the internal header), and carty_infer_map_update.
 * It is the ONLY place that touches the LiteRT-LM C ABI; keeping that in one file
 * is the point of the split. Route 1 (2026-06-19) replaced the former fork/exec
 * subprocess driver here with the resident in-process engine.
 */
#include "carty_bridge.h"
#include "carty_bridge_internal.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifdef CARTY_HAVE_LITERT
/* The vendored LiteRT-LM C ABI (litert-runtime/include/engine.h) — the in-process
 * Engine/Session API. Pulled in solely for the CARTY_HAVE_LITERT build. */
#include "engine.h"
#define CARTY_LITERT_PROMPT_MAX 4096
#define CARTY_DECODE_MAX_TOKENS 256
/* Bound on the turn-wrapped prompt: the caller's prompt (<= CARTY_SPATIAL_PROMPT_MAX
 * for the ortho path, <= CARTY_LITERT_PROMPT_MAX for the ROI path) plus the fixed
 * <|turn> marker scaffold. Checked explicitly before formatting (Tiger Style). */
#define CARTY_TURN_WRAP_MAX (CARTY_SPATIAL_PROMPT_MAX + 64)
#endif

extern "C" CartyModel *carty_model_load(const char *model_path) {
  CARTY_ASSERT(model_path != nullptr, "null model path at boundary");
  CARTY_ASSERT(model_path[0] != '\0', "empty model path");

  CartyModel *model = static_cast<CartyModel *>(std::malloc(sizeof(CartyModel)));
  CARTY_ASSERT(model != nullptr, "model handle allocation failed");

  /* Stash the path (kept for diagnostics + the asserts the inference entry points
   * make on model->model_path). */
  size_t const path_len = std::strlen(model_path) + 1;
  model->model_path =
      static_cast<char *>(std::malloc(path_len));
  CARTY_ASSERT(model->model_path != nullptr, "model path allocation failed");
  std::memcpy(model->model_path, model_path, path_len); // path_len counts the NUL

  model->engine = nullptr;
  model->settings = nullptr;

#ifdef CARTY_HAVE_LITERT
  /* Load the engine ONCE here and hold it resident for the whole session — the
   * 2.4 GB weight mmap must not recur per call. This is
   * DELIBERATELY tolerant of failure: the public contract (carty_bridge.h) says
   * carty_model_load does NOT validate the file or abort on load failure — many
   * tests pass a bogus path expecting a non-null handle that safe-fails ENOMODEL
   * at decode. So a null engine/settings is a valid DEGRADED state, never a crash.
   * CPU backend, no vision/audio (text corrector path). */
  LiteRtLmEngineSettings *settings =
      litert_lm_engine_settings_create(model->model_path, "cpu", nullptr, nullptr);
  if (settings != nullptr) {
    LiteRtLmEngine *engine = litert_lm_engine_create(settings);
    if (engine != nullptr) {
      model->engine = engine;
      model->settings = settings; /* kept alive for the engine's lifetime */
    } else {
      litert_lm_engine_settings_delete(settings); /* load failed → stay degraded */
    }
  }
#endif

  CARTY_ASSERT(model->model_path != nullptr, "model invariant violated");
  return model;
}

extern "C" void carty_model_free(CartyModel *model) {
  CARTY_ASSERT(model != nullptr, "null model handle at boundary");
  CARTY_ASSERT(model->model_path != nullptr, "model has null path");
#ifdef CARTY_HAVE_LITERT
  /* Release the resident engine + settings (engine first; settings outlived it). */
  if (model->engine != nullptr) {
    litert_lm_engine_delete(static_cast<LiteRtLmEngine *>(model->engine));
    model->engine = nullptr;
  }
  if (model->settings != nullptr) {
    litert_lm_engine_settings_delete(
        static_cast<LiteRtLmEngineSettings *>(model->settings));
    model->settings = nullptr;
  }
#endif
  std::free(model->model_path);
  model->model_path = nullptr;
  std::free(model);
}

#ifdef CARTY_HAVE_LITERT
/* Decode prompt_text against the RESIDENT Gemma 4 E2B engine in `model`,
 * in-process, writing the model's raw generated text into output_buf. Shared by
 * every inference entry point (the ROI text path below AND the ortho-fusion path
 * in carty_bridge.cpp) so the single proven decode recipe lives in exactly one
 * place. We NEVER fabricate on failure — a null resident engine (degraded build /
 * load failure) is a safe ENOMODEL, a runtime fault is a safe ENOMODEL, an empty
 * generation is ENOMODEL, a too-small caller buffer is ENOSPACE. Bounded by
 * construction (Tiger Style): a fresh session per call (no cross-call KV-cache
 * bleed between independent corrector invocations), capped output tokens, and a
 * bounded turn-wrap buffer. prompt_text must be a NUL-terminated string the caller
 * already assembled. Declared (not static) in carty_bridge_internal.h so the
 * fusion TU can call this one definition.
 *
 * Recipe (verified against the v0.13.1 source the .so was built from; see
 *): generate_content (one-shot prompt→full
 * response, returns RAW text via responses_get_response_text_at) with
 * apply_prompt_template=false and the model's own <|turn> markers hand-formatted
 * here. NOT the Conversation API — its only accessor returns a JSON envelope the
 * bridge must not parse natively; Dart's MapUpdate.parse is the
 * sole parser). The default sampler (TYPE_UNSPECIFIED) is one of only two CPU
 * choices the runtime implements; never request TopK/Greedy on the CPU build. */
int32_t carty_generate_inprocess(const CartyModel *model, const char *prompt_text,
                                 char *output_buf, int32_t output_buf_size) {
  CARTY_ASSERT(model != nullptr, "null model to in-process generate");
  CARTY_ASSERT(prompt_text != nullptr, "null prompt to in-process generate");
  CARTY_ASSERT(output_buf != nullptr, "null output buffer to in-process generate");
  CARTY_ASSERT(output_buf_size > 0, "non-positive output size to in-process generate");
  output_buf[0] = '\0';

  if (model->engine == nullptr) {
    return CARTY_INFER_ENOMODEL; /* no resident weights: honest safe-fail */
  }
  LiteRtLmEngine *engine = static_cast<LiteRtLmEngine *>(model->engine);

  /* Wrap the caller's prompt in this model's own turn markers (the runtime
   * prepends BOS). Bounded: refuse rather than truncate if it would overrun. */
  char wrapped[CARTY_TURN_WRAP_MAX];
  const int wrapped_len = std::snprintf(wrapped, sizeof(wrapped),
                                        "<|turn>user\n%s<turn|>\n<|turn>model\n", prompt_text);
  if (wrapped_len < 0 || wrapped_len >= static_cast<int>(sizeof(wrapped))) {
    return CARTY_INFER_ENOSPACE;
  }

  /* Fresh session per call so independent corrector invocations never share KV
   * cache. apply_prompt_template MUST be false for this model (the in-session
   * templating uses deprecated proto templates with no <|turn> markers → empty
   * output); we supply the markers ourselves above. */
  LiteRtLmSessionConfig *cfg = litert_lm_session_config_create();
  if (cfg == nullptr) {
    return CARTY_INFER_ENOMODEL;
  }
  litert_lm_session_config_set_max_output_tokens(cfg, CARTY_DECODE_MAX_TOKENS);
  litert_lm_session_config_set_apply_prompt_template(cfg, false);

  LiteRtLmSession *session = litert_lm_engine_create_session(engine, cfg);
  if (session == nullptr) {
    litert_lm_session_config_delete(cfg);
    return CARTY_INFER_ENOMODEL;
  }

  LiteRtLmInputData input;
  input.type = kLiteRtLmInputDataTypeText;
  input.data = wrapped;
  input.size = std::strlen(wrapped);

  LiteRtLmResponses *responses =
      litert_lm_session_generate_content(session, &input, 1);

  int32_t result = CARTY_INFER_ENOMODEL; /* default: safe-fail, no fabrication */
  if (responses != nullptr &&
      litert_lm_responses_get_num_candidates(responses) >= 1) {
    const char *text = litert_lm_responses_get_response_text_at(responses, 0);
    if (text != nullptr && text[0] != '\0') {
      const size_t gen_len = std::strlen(text);
      if (static_cast<int32_t>(gen_len) + 1 > output_buf_size) {
        result = CARTY_INFER_ENOSPACE;
      } else {
        std::memcpy(output_buf, text, gen_len + 1); /* incl NUL */
        result = static_cast<int32_t>(gen_len) + 1; /* bytes written incl NUL */
      }
    }
  }

  if (responses != nullptr) {
    litert_lm_responses_delete(responses);
  }
  litert_lm_session_delete(session);
  litert_lm_session_config_delete(cfg);
  return result;
}
#endif /* CARTY_HAVE_LITERT */

extern "C" int32_t carty_infer_map_update(const CartyModel *model,
                                          const CartyFrame *image_segment,
                                          const char *text_prompt, float bx0,
                                          float by0, float bx1, float by1,
                                          char *output_buf,
                                          int32_t output_buf_size) {
  /* Boundary: crash immediately on any NULL handle / buffer (Tiger Style). */
  CARTY_ASSERT(model != nullptr, "null model handle at boundary");
  CARTY_ASSERT(model->model_path != nullptr, "model has null path");
  CARTY_ASSERT(image_segment != nullptr, "null image segment at boundary");
  CARTY_ASSERT(image_segment->data != nullptr, "image segment has null buffer");
  CARTY_ASSERT(text_prompt != nullptr, "null text prompt at boundary");
  CARTY_ASSERT(output_buf != nullptr, "null output buffer at boundary");
  CARTY_ASSERT(output_buf_size > 0, "output buffer size must be positive");

  /* Spatial bounds: a precondition (the Dart layer validates before crossing).
   * Use std::isfinite via NaN-self-compare to keep it dependency-free. */
  CARTY_ASSERT(bx0 == bx0 && by0 == by0 && bx1 == bx1 && by1 == by1,
               "spatial bounds must be finite");
  CARTY_ASSERT(bx0 >= 0.0F && by0 >= 0.0F && bx1 <= 1.0F && by1 <= 1.0F,
               "spatial bounds must be in [0,1]");
  CARTY_ASSERT(bx0 <= bx1 && by0 <= by1, "spatial bounds must be ordered");

  /* Always leave the buffer in a defined, safe state. */
  output_buf[0] = '\0';

#ifdef CARTY_HAVE_LITERT
  /* Real forward pass: assemble the caller instruction + normalized ROI into a
   * prompt and decode against the RESIDENT engine in-process
   * (carty_generate_inprocess). image_segment pixels are a documented multimodal
   * follow-up; the text-only path ignores them today. */
  (void)image_segment;
  char prompt[CARTY_LITERT_PROMPT_MAX];
  const int prompt_len = std::snprintf(
      prompt, sizeof(prompt),
      "%s\n(map region of interest: [%.4f,%.4f]-[%.4f,%.4f])\n", text_prompt,
      bx0, by0, bx1, by1);
  CARTY_ASSERT(prompt_len > 0, "prompt formatting failed");
  return carty_generate_inprocess(model, prompt, output_buf, output_buf_size);
#else
  /* LiteRT is intentionally NOT linked yet (built without CARTY_HAVE_LITERT): the
   * bridge owns no weights, so the only honest result is a SAFE failure. We do
   * NOT fabricate output — the orchestration scaffold (prompt layout, FFI ABI,
   * Dart parser) is exercised; the tensor forward pass is the documented seam. */
  (void)image_segment;
  (void)text_prompt;
  (void)bx0;
  (void)by0;
  (void)bx1;
  (void)by1;
  return CARTY_INFER_ENOMODEL;
#endif
}
