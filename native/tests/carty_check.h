/* Shared checks for the native tests. A report line that can't be written counts as a
 * failure: a result nobody sees is not a pass. */
#ifndef CARTY_CHECK_H_
#define CARTY_CHECK_H_

#include <cstddef>
#include <cstdio>

inline int g_failures = 0;

/* One formatted line to out; a line cut short or not written at all fails the run. */
template <typename... Args>
void carty_sayf(std::FILE *out, const char *fmt, Args... args) {
  constexpr std::size_t kLineMax = 4096;
  char line[kLineMax];
  const int len = std::snprintf(line, sizeof(line), fmt, args...);
  if (len < 0 || static_cast<std::size_t>(len) >= sizeof(line) || std::fputs(line, out) < 0) {
    ++g_failures;
  }
}

/* passes print "ok:" unless quiet, for suites whose passes would flood the log */
inline bool carty_check(bool passed, const char *msg, bool quiet) {
  if (passed) {
    if (!quiet) {
      carty_sayf(stdout, "ok:   %s\n", msg);
    }
    return true;
  }
  ++g_failures;
  carty_sayf(stderr, "FAIL: %s\n", msg);
  return false;
}

/* The run's exit code: 0 only when every check passed and every line was written. */
inline int carty_finish(const char *pass_line) {
  if (g_failures == 0) {
    carty_sayf(stdout, "\n%s\n", pass_line);
  }
  if (g_failures == 0) {
    return 0;
  }
  carty_sayf(stderr, "\n%d CHECK(S) FAILED\n", g_failures);
  return 1;
}

/* Deterministic, position-dependent test byte. An LCG-style mix, so neighbouring
 * bytes differ and off-by-one, overlap or stale-buffer corruption shows up. */
inline unsigned char carty_test_byte(std::size_t offset) {
  constexpr std::size_t kMixMul = 131U;  // odd, so the low byte cycles through all 256
  constexpr std::size_t kMixAdd = 7U;
  constexpr std::size_t kByteMask = 0xFFU;
  return static_cast<unsigned char>(((offset * kMixMul) + kMixAdd) & kByteMask);
}

#define CHECK(cond, msg) carty_check(static_cast<bool>(cond), (msg), false)
#define CHECK_QUIET(cond, msg) carty_check(static_cast<bool>(cond), (msg), true)

#endif /* CARTY_CHECK_H_ */
