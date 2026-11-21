#!/usr/bin/env bash
# The lint gate. clang-tidy (config: .clang-tidy) over every tracked native source in
# both Geometric-stage builds, with and without OpenCV; the LiteRT-only code under the
# LiteRT defines, plus a -Werror syntax compile of it (the .so isn't linked here); and
# flutter analyze with infos fatal over every tracked Dart file.
# Exits non-zero on any finding, and on any stage that saw no files. Runs on macOS's
# bash 3.2: no mapfile or namerefs, and an empty array is never expanded under set -u.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

tidy=${CLANG_TIDY:-$(command -v clang-tidy || echo /opt/homebrew/opt/llvm/bin/clang-tidy)}
[ -x "$tidy" ] || { echo "lint: no clang-tidy (set CLANG_TIDY)" >&2; exit 2; }
cxx=${CXX:-c++}
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# a stage that linted nothing is a broken gate, not a clean one
require_files() {
  if [ "$2" -eq 0 ]; then
    echo "lint: $1 saw 0 files" >&2
    fail=1
  fi
}

# one file's findings into its own log; a crash reads as a finding, never as clean
lint_one() {
  local dir=$1 file=$2
  shift 2
  local status=0
  "$tidy" --quiet "$file" "$@" > "$dir/${file//\//_}.log" 2>&1 || status=$?
  if [ "$status" -ne 0 ] && ! grep -qE ': (error|warning):' "$dir/${file//\//_}.log"; then
    echo "$file: error: clang-tidy exited $status with no finding" >> "$dir/${file//\//_}.log"
  fi
}
export -f lint_one
export tidy

# lines of a command's output into the named array (bash 3.2 has no mapfile)
read_lines() {
  local line
  eval "$1=()"
  while IFS= read -r line; do
    eval "$1+=(\"\$line\")"
  done
}

# tidy_stage NAME N ARGS(N of them, passed after each file) FILES...
tidy_stage() {
  local name=$1 nargs=$2
  shift 2
  local post_args=("${@:1:nargs}")
  shift "$nargs"
  local stage_files=("$@")
  require_files "$name" "${#stage_files[@]}"
  [ "${#stage_files[@]}" -eq 0 ] && return
  mkdir -p "$work/$name"
  printf '%s\0' "${stage_files[@]}" |
    xargs -0 -P "$jobs" -I{} bash -c 'lint_one "$@"' _ "$work/$name" {} ${post_args[@]+"${post_args[@]}"}
  local found
  found=$(cat "$work/$name"/*.log | grep -E ': (error|warning):' | sort -u || true)
  local count=0
  [ -n "$found" ] && count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
  echo "lint: $name: ${#stage_files[@]} files, $count findings"
  if [ "$count" -ne 0 ]; then
    printf '%s\n' "$found" >&2
    fail=1
  fi
}

# tracked sources a compile database holds; the LiteRT tests are in neither
in_db() {
  local db=$1
  shift
  for f in "$@"; do
    if grep -qF "\"$PWD/$f\"" "$db"; then echo "$f"; fi
  done
}

# -- native: one tree per Geometric-stage path; the OpenCV tree must find it, never fall back
cmake -S native -B native/build-lint -DCMAKE_DISABLE_FIND_PACKAGE_OpenCV=ON >/dev/null
cmake -S native -B native/build-lint-opencv -DCMAKE_REQUIRE_FIND_PACKAGE_OpenCV=ON >/dev/null
read_lines sources < <(git ls-files 'native/src/*.cpp' 'native/tests/*.cpp')
require_files native "${#sources[@]}"
read_lines plain < <(in_db native/build-lint/compile_commands.json ${sources[@]+"${sources[@]}"})
read_lines opencv < <(in_db native/build-lint-opencv/compile_commands.json ${sources[@]+"${sources[@]}"})
tidy_stage no-opencv 2 -p native/build-lint ${plain[@]+"${plain[@]}"}
tidy_stage opencv 2 -p native/build-lint-opencv ${opencv[@]+"${opencv[@]}"}

# -- LiteRT: every src file has a CARTY_HAVE_LITERT branch, and two tests need the runtime
litert_flags=(-std=c++17 -DCARTY_HAVE_LITERT -Inative/include -Inative/src -Inative/tests
              -Ilitert-runtime/include)
read_lines litert < <(git ls-files 'native/src/*.cpp' native/tests/test_litert_forward.cpp \
                       native/tests/test_inprocess_decode.cpp)
tidy_stage litert $((${#litert_flags[@]} + 1)) -- "${litert_flags[@]}" ${litert[@]+"${litert[@]}"}
compiled=0
for f in ${litert[@]+"${litert[@]}"}; do
  if "$cxx" -fsyntax-only -Wall -Wextra -Wpedantic -Werror "${litert_flags[@]}" "$f"; then
    compiled=$((compiled + 1))
  else
    fail=1
  fi
done
echo "lint: litert syntax: $compiled of ${#litert[@]} files compile"

# -- every tracked source is linted by at least one stage
staged=" ${plain[*]-} ${opencv[*]-} ${litert[*]-} "
for f in ${sources[@]+"${sources[@]}"}; do
  case "$staged" in
    *" $f "*) ;;
    *) echo "lint: $f is in no stage" >&2; fail=1 ;;
  esac
done

# -- Dart: tracked files only, so a local scratch file can't fail or pass the gate
read_lines dart_files < <(git ls-files '*.dart')
require_files dart "${#dart_files[@]}"
analysis=$(flutter analyze --fatal-infos --fatal-warnings ${dart_files[@]+"${dart_files[@]}"} 2>&1 || true)
if grep -q 'No issues found!' <<<"$analysis"; then
  echo "lint: dart: ${#dart_files[@]} files, 0 findings"
else
  printf '%s\n' "$analysis" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "lint: FAILED" >&2
  exit 1
fi
echo "lint: clean"
