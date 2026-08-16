#!/usr/bin/env bash
#
# Self-hosting verification harness for macabre.
#
# Verifies the two self-hosting guarantees:
#   1. macabre (compiled to Python) can compile itself and passes its own test
#      suite when run through that Python output.
#   2. The Python-compiled compiler's output is byte-identical to the output
#      of the Erlang-compiled compiler.
#
# And times both builds so regressions in generated-code performance are easy
# to spot.
#
# Usage:
#   scripts/self_host.sh            # run the full harness
#   scripts/self_host.sh erlang     # only build+time with the Erlang compiler
#   scripts/self_host.sh python     # only build+time with the Python compiler
#
# The copy of the repo lives in /tmp/macabre-self (a temp dir is used because
# compiling macabre on its own working directory would wipe the build it runs
# from). Copy the directory to profile the generated Python compiler:
#
#   python3 -m cProfile -o /tmp/macabre_profile.out \
#     /tmp/macabre-self/build/dev/python /tmp/macabre-self
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK="${SELF_HOST_DIR:-/tmp/macabre-self}"

sync_copy() {
  if [ "${FRESH:-}" = "1" ]; then
    rm -rf "$WORK"
  fi
  mkdir -p "$WORK"
  # Re-copy the repo sources but keep build/packages: the git deps are cached
  # there with a .macabre-refs stamp, so a re-run only fetches what changed
  # instead of re-cloning everything over the network.
  rsync -a --delete --exclude build --exclude .git --exclude macabre \
    --exclude erl_crash.dump "$REPO"/ "$WORK"/
  rm -rf "$WORK/build/dev/python"
}

erlang_build() {
  echo "==> Building $WORK with the Erlang-compiled macabre"
  time ./macabre "$WORK"
}

python_build() {
  echo "==> Building $WORK with the Python-compiled macabre"
  time python3 "$WORK/build/dev/python" "$WORK"
}

compare_output() {
  echo "==> Comparing the Erlang vs Python compiler output"
  # Save the Python build's output outside the build tree (project.clean wipes
  # build/dev), then rebuild with Erlang so both outputs exist to diff.
  local saved="/tmp/macabre-python-output"
  rm -rf "$saved"
  cp -R "$WORK/build/dev/python" "$saved"
  find "$saved" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
  ./macabre "$WORK" >/dev/null
  diff -r "$WORK/build/dev/python" "$saved" \
    && echo "    Output is byte-identical" \
    || echo "    OUTPUT DIFFERS"
  rm -rf "$saved"
}

erlang_tests() {
  echo "==> Running the test suite via the Erlang-compiled macabre"
  ./macabre test "$WORK"
}

python_tests() {
  echo "==> Running the test suite via the Python-compiled macabre"
  python3 "$WORK/build/dev/python" "$WORK" test
}

case "${1:-all}" in
  all)
    sync_copy
    erlang_build
    python_build
    compare_output
    erlang_tests
    python_tests
    ;;
  erlang)
    sync_copy
    erlang_build
    ;;
  python)
    sync_copy
    erlang_build
    python_build
    ;;
  *)
    echo "Unknown target: $1" >&2
    exit 1
    ;;
esac
