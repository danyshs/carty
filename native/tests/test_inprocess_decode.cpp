/* test_inprocess_decode.cpp — proves a REAL Gemma 4 E2B decode IN-PROCESS, by
 * calling the vendored LiteRT-LM C ABI (litert-runtime/include/engine.h) directly
 * against the host-linkable liblitert-lm.so.
 *
 * This is the Route 1 gate at its purest: NO fork/exec, NO subprocess, NO stdout
 * scraping — the engine is created, a session prefilled, and a decode run, all
 * inside this process. It deliberately bypasses carty_bridge so it isolates one
 * question only: "does the vendored in-process runtime + weights decode?" (The
 * bridge-level wrapping is proven separately by test_litert_forward.)
 *
 * Like the bridge-level test_litert_forward (which now also decodes in-process,
 * through the carty_bridge ABI), this path needs ONLY the model — the runtime is
 * the linked .so, no separate runtime binary. So it is gated on CARTY_GEMMA_MODEL
 * alone — unset → 77 → ctest SKIP. It NEVER asserts success when skipped, and
 * NEVER fabricates output. (This test bypasses the bridge; test_litert_forward
 * proves the bridge wrapping.)
 */
#include "engine.h"
#include "carty_check.h"

#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>

/* each step builds on the last, so the first failure ends the step */
#undef CHECK
#define CHECK(cond, msg)           \
  do {                             \
    if (!CHECK_QUIET(cond, msg)) { \
      return false;                \
    }                              \
  } while (0)

namespace {

constexpr int kSkipExit = 77;      // ctest SKIP_RETURN_CODE
constexpr int kErrorLogLevel = 4;  // runtime levels: 0=VERBOSE … 4=ERROR
constexpr int kDecimalBase = 10;
constexpr int kMaxOutputTokens = 256;
constexpr size_t kPromptMax = 256;
constexpr char kSteer[] = "CARTY_INPROCESS_OK";

/* Keep the runtime quiet (it is log-chatty at INFO): ERROR and above, unless
 * CARTY_LOG_LEVEL names a level, for diagnosing. */
int runtime_log_level() {
  const char *log_env = std::getenv("CARTY_LOG_LEVEL");
  if (log_env == nullptr) {
    return kErrorLogLevel;
  }
  char *end = nullptr;
  const long level = std::strtol(log_env, &end, kDecimalBase);
  const bool parsed = end != log_env && *end == '\0' && level >= 0 && level <= kErrorLogLevel;
  return parsed ? static_cast<int>(level) : kErrorLogLevel;
}

/* everything the decode holds; close_runtime frees what was made, newest first */
struct Runtime {
  LiteRtLmEngineSettings *settings;
  LiteRtLmEngine *engine;
  LiteRtLmSessionConfig *cfg;
  LiteRtLmSession *session;
};

/* Engine settings: CPU backend, no vision/audio. The engine owns the 2.4 GB
 * weight load — done ONCE here, the whole point of in-process. */
bool open_runtime(const char *model_path, Runtime *runtime) {
  runtime->settings = litert_lm_engine_settings_create(model_path, "cpu", nullptr, nullptr);
  CHECK(runtime->settings != nullptr, "engine_settings_create returned null");
  runtime->engine = litert_lm_engine_create(runtime->settings);
  CHECK(runtime->engine != nullptr, "engine_create returned null (model load failed)");

  /* Sampler choice is DELIBERATE, verified against the v0.13.1 source the .so was
   * built from (official source is the only authority):
   *   runtime/components/sampler_factory.cc CreateCpuSampler() implements TOP_P
   *   only; TYPE_UNSPECIFIED returns no external sampler ("the LLM Executor handles
   *   the sampling logic"); TOP_K and GREEDY hit the default branch → UNIMPLEMENTED.
   * We leave the sampler at its default (TYPE_UNSPECIFIED — engine_settings.cc
   * SessionConfig::CreateDefault), so the executor samples internally. This is the
   * ONLY two valid CPU choices (UNSPECIFIED or TOP_P); never request TopK/Greedy on
   * the CPU build. */
  runtime->cfg = litert_lm_session_config_create();
  CHECK(runtime->cfg != nullptr, "session_config_create returned null");
  litert_lm_session_config_set_max_output_tokens(runtime->cfg, kMaxOutputTokens);
  /* apply_prompt_template MUST be false for this model, and we format the turn
   * markers ourselves below. This is the verified recipe (proved by an A/B against
   * the real weights): the C ABI's in-session templating wraps the prompt with the
   * DEPRECATED simple prefix/suffix proto templates (runtime/core/session_utils.cc
   * ApplyPromptTemplates → SessionConfig::GetPromptTemplates().user()/model()),
   * which are NOT populated with this Gemma-4 model's `<|turn>` markers — so with
   * the flag ON the plain prompt reaches the model with no turn structure and it
   * emits an immediate EOS (a non-null but EMPTY response, 0 streamed tokens).
   * Feeding the model's own markers with the flag OFF yields a correct decode.
   * Production note: carty_bridge (Route 1, shipped) uses exactly this recipe —
   * generate_content + apply_prompt_template=false + these markers — NOT the
   * Conversation API. The Conversation API applies the model's real jinja template
   * by role, but its only accessor (json_response_get_string) returns a JSON
   * envelope the bridge would have to parse natively, which
   * forbids (Dart's MapUpdate.parse is the sole parser). Template-by-role is a
   * deferred corrector-quality follow-up. See */
  litert_lm_session_config_set_apply_prompt_template(runtime->cfg, false);

  runtime->session = litert_lm_engine_create_session(runtime->engine, runtime->cfg);
  CHECK(runtime->session != nullptr, "engine_create_session returned null");
  return true;
}

void close_runtime(const Runtime &runtime) {
  if (runtime.session != nullptr) {
    litert_lm_session_delete(runtime.session);
  }
  if (runtime.cfg != nullptr) {
    litert_lm_session_config_delete(runtime.cfg);
  }
  if (runtime.engine != nullptr) {
    litert_lm_engine_delete(runtime.engine);
  }
  if (runtime.settings != nullptr) {
    litert_lm_engine_settings_delete(runtime.settings);
  }
}

bool check_response(const LiteRtLmResponses *responses) {
  CHECK(responses != nullptr, "generate_content returned null");
  CHECK(litert_lm_responses_get_num_candidates(responses) >= 1,
        "generate_content produced no candidates");
  const char *text = litert_lm_responses_get_response_text_at(responses, 0);
  CHECK(text != nullptr, "response text at index 0 is null");
  CHECK(std::strlen(text) > 0, "decoded response was empty");
  carty_sayf(stdout, "=== Gemma 4 E2B in-process decode ===\n%s\n=== end ===\n", text);
  const bool steered = std::strstr(text, kSteer) != nullptr;
  carty_sayf(stdout, "steered-token present: %s\n", steered ? "yes" : "no");
  CHECK(steered, "decoded output did not contain the instruction-steered token");
  return true;
}

/* Steer to a token the model would not otherwise emit, so a match proves a real
 * instruction-conditioned decode rather than an echo or canned string. The
 * `<|turn>user … <turn|> <|turn>model` markers are this model's own turn template
 * (read from its metadata in the engine-load log); the runtime prepends BOS. */
bool decode_steered(LiteRtLmSession *session) {
  char prompt[kPromptMax];
  const int prompt_len = std::snprintf(prompt, sizeof(prompt),
                                       "<|turn>user\nReply with exactly this token and nothing else: "
                                       "%s<turn|>\n<|turn>model\n",
                                       kSteer);
  CHECK(prompt_len > 0 && static_cast<size_t>(prompt_len) < sizeof(prompt),
        "steering prompt did not fit");

  LiteRtLmInputData input;
  input.type = kLiteRtLmInputDataTypeText;
  input.data = prompt;
  input.size = static_cast<size_t>(prompt_len);

  /* Use generate_content — the C ABI's one-shot prompt→full-response entry point.
   * This is the sanctioned text-generation path: the runtime's own end-to-end test
   * (c/engine_test.cc TEST(EngineCTest, GenerateContent)) drives text out THIS way
   * and asserts strlen>0. The lower-level run_prefill+run_decode pair is NOT a
   * text-generation API here — the C ABI's run_decode wraps the no-arg C++
   * RunDecode() (no DecodeConfig loop), and no upstream test produces text through
   * it; pairing them manually yields an empty response. generate_content is also
   * exactly Carty's shape: one symbolic-map prompt in → one {"ops":…} response out. */
  LiteRtLmResponses *responses = litert_lm_session_generate_content(session, &input, 1);
  const bool passed = check_response(responses);
  if (responses != nullptr) {
    litert_lm_responses_delete(responses);
  }
  return passed;
}

}  // namespace

int main() {
  const char *model_path = std::getenv("CARTY_GEMMA_MODEL");
  if (model_path == nullptr || model_path[0] == '\0') {
    carty_sayf(stderr, "%s\n",
               "SKIP: CARTY_GEMMA_MODEL unset — export the path to "
               "gemma-4-E2B-it.litertlm to run the real in-process decode.");
    return kSkipExit;
  }
  carty_sayf(stdout, "model: %s\n", model_path);
  litert_lm_set_min_log_level(runtime_log_level());

  Runtime runtime{nullptr, nullptr, nullptr, nullptr};
  if (open_runtime(model_path, &runtime)) {
    static_cast<void>(decode_steered(runtime.session));
  }
  close_runtime(runtime);
  return carty_finish("PASS: real Gemma 4 E2B decode ran fully in-process (no subprocess).");
}
