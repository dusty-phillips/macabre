#!/usr/bin/env bash
#
# External-portability auditor for a Gleam package.
#
# Extracts every `@external(erlang, "module", "fun")` in the package's src and
# classifies each target module as either:
#   * portable  - maps onto Python's standard library (math, unicode, string,
#                 lists, maps, binary, os, re, ...). These are the externals a
#                 macabre port can shim with a thin @external(python, ...) layer.
#   * bespoke   - package-specific FFI (arc_*_ffi, custom NIF modules, OTP
#                 behaviours, ...). Porting these means reimplementing engine
#                 logic in Python, which is generally out of scope for the corpus.
#
# Usage:
#   scripts/audit_externals.sh <package-src-dir>
#
# Prints a summary and lists the distinct portable (module, fun) pairs so the
# actual porting workload is visible up front.
#
set -euo pipefail

SRC="$1"
[ -d "$SRC" ] || { echo "usage: audit_externals.sh <package-src-dir>" >&2; exit 2; }

# Modules we consider portable to Python's stdlib. Extend as needed.
PORTABLE='^(math|unicode|maps|binary|array|lists|string|erlang|os|re|io|file|path|base64|calendar|datetime|glue|gleam_stdlib|gleam_otp|gleam_erlang|gleam_javascript)$'

total=0
portable=0
bespoke=0
declare -A seen_portable
declare -A seen_bespoke

while IFS= read -r line; do
  mod="$(echo "$line" | sed -E 's/.*@external\(erlang, "([^"]*)".*/\1/')"
  fun="$(echo "$line" | sed -E 's/.*, "([^"]*)"\)/\1/')"
  total=$((total + 1))
  if echo "$mod" | grep -Eq "$PORTABLE"; then
    portable=$((portable + 1))
    seen_portable["$mod.$fun"]=1
  else
    bespoke=$((bespoke + 1))
    seen_bespoke["$mod.$fun"]=1
  fi
done < <(grep -rho '@external(erlang, "[^"]*", "[^"]*")' "$SRC" 2>/dev/null)

echo "External(erlang) audit of: $SRC"
echo "  total:    $total"
echo "  portable: $portable   (maps to Python stdlib)"
echo "  bespoke:  $bespoke    (package-specific / OTP)"
echo
if [ "${#seen_portable[@]:-0}" -gt 0 ]; then
  echo "Portable externals to shim (distinct module.fun):"
  for k in $(printf '%s\n' "${!seen_portable[@]}" | sort); do
    echo "  $k"
  done
fi
