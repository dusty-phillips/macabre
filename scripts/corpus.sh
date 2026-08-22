#!/usr/bin/env bash
#
# Corpus harness for macabre.
#
# Compiles a basket of external Gleam packages with macabre and runs each
# package's own test suite through the generated Python. This is the "expand
# the corpus" dashboard: it makes it obvious which packages build, which pass
# their tests, and where a codegen/transform gap is blocking a package.
#
# Packages are listed in scripts/corpus.txt, one per line:
#
#   <name>  <git-url-or-local-path>  <ref-or-branch>
#
# A line starting with `#` is a comment. For a local path the ref is ignored
# (and the package's existing build/ cache is reused, so repeat runs are fast).
# For a git url the ref is checked out; dependencies are fetched into the
# package's own build/ directory on first run.
#
# The macabre compiler used is the Erlang-compiled binary at the repo root
# (./macabre). That binary exercises macabre's *codegen* (it emits Python and
# runs the Python test suites); the host it runs on is irrelevant to the
# correctness being measured.
#
# Usage:
#   scripts/corpus.sh            # build + test every package in corpus.txt
#   scripts/corpus.sh glam       # only the package named "glam"
#
# Packages are processed in parallel: JOBS controls how many run at once
# (default 4). Each package has its own build/ directory and the compiler
# binary is read-only, so concurrent runs don't interfere; results are
# collected into per-package files and printed in corpus.txt order.
#
# Environment:
#   CORPUS_DIR   working root for cloned packages (default /tmp/macabre-corpus)
#   JOBS         number of packages to build/test concurrently (default 4)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
# Regenerate this escript after changing the compiler with:
#   gleam export escript
MACABRE="$REPO/macabre"
CORPUS_FILE="$HERE/corpus.txt"
WORK_ROOT="${CORPUS_DIR:-/tmp/macabre-corpus}"

mkdir -p "$WORK_ROOT"

row() {
  # name, build_status, test_status, seconds
  printf '%-28s %-10s %-12s %ss\n' "$1" "$2" "$3" "$4"
}

build_and_test() {
  local name="$1" location="$2" ref="$3"
  local dir
  case "$location" in
    /*)
      dir="$location"
      ;;
    *)
      dir="$WORK_ROOT/$name"
      if [ ! -d "$dir" ]; then
        git clone "$location" "$dir" >/dev/null 2>&1
      else
        git -C "$dir" fetch >/dev/null 2>&1
      fi
      git -C "$dir" checkout "$ref" >/dev/null 2>&1
      ;;
  esac

  local start build_status test_status
  start="$(date +%s)"
  if "$MACABRE" "$dir" >/dev/null 2>&1; then
    build_status=OK
  else
    build_status=FAIL
  fi

  if [ "$build_status" = OK ]; then
    # Packages with no test modules can't be tested; mark them distinctly
    # rather than letting the runner's "no entrypoint" error read as a FAIL.
    local test_count=0
    if [ -d "$dir/test" ]; then
      test_count="$(find "$dir/test" -name '*.gleam' 2>/dev/null | wc -l | tr -d ' ')"
    fi
    if [ "$test_count" -eq 0 ]; then
      test_status=NO_TESTS
    else
      # A test module's success is its exit status: gleeunit suites exit
      # non-zero on failure, and plain `main`-style test modules (e.g.
      # `repeatedly_test`) exit 0 without printing "no failures". Grepping for
      # that text misclassified the latter.
      # A test suite that hangs (e.g. one that blocks on stdin in a
      # non-interactive build) is killed by `timeout` and counted as a FAIL
      # rather than stalling the whole corpus run.
      if timeout 300 "$MACABRE" test "$dir" >/dev/null 2>&1; then
        test_status=PASS
      else
        test_status=FAIL
      fi
    fi
  else
    test_status=SKIP
  fi
  local end
  end="$(date +%s)"
  row "$name" "$build_status" "$test_status" "$((end - start))"
}

echo "Corpus run: $(date)"
printf '%-28s %-10s %-12s %s\n' "PACKAGE" "BUILD" "TESTS" "TIME"
echo "--------------------------------------------------------------"

only="${1:-}"
JOBS="${JOBS:-4}"

# Run one package's build+test with its output row captured to a file, so
# parallel jobs don't interleave and rows can be printed in corpus.txt order.
run_one() {
  local name="$1" location="$2" ref="$3"
  build_and_test "$name" "$location" "$ref" > "$WORK_ROOT/.row-$name" 2>&1
}

while read -r line; do
  # strip comments and blank lines
  case "$line" in
    ''|\#*) continue ;;
  esac
  # shellcheck disable=SC2086
  set -- $line
  name="$1"; location="$2"; ref="${3:-main}"
  if [ -n "$only" ] && [ "$name" != "$only" ]; then
    continue
  fi
  # Simple job-slot gate: wait while at least JOBS children are running.
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do
    sleep 0.5
  done
  run_one "$name" "$location" "$ref" &
done < "$CORPUS_FILE"
wait

echo "--------------------------------------------------------------"
# Print rows in corpus.txt order for a stable dashboard.
while read -r line; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  # shellcheck disable=SC2086
  set -- $line
  name="$1"
  if [ -n "$only" ] && [ "$name" != "$only" ]; then
    continue
  fi
  cat "$WORK_ROOT/.row-$name"
done < "$CORPUS_FILE"
