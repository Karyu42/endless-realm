#!/usr/bin/env bash
# Backstop for the GUT post-run gate (client/tests/support/gut_post_run_gate.gd).
# Fails if the GUT log shows a test script that failed to load or parse, or if the
# run summary's "Scripts" count is lower than the number of test_*.gd files.
# Usage: check-gut-log.sh <gut.log> [tests dir, default client/tests]
set -uo pipefail
log="$1"
tests_dir="${2:-client/tests}"
if [ ! -s "$log" ]; then
  echo "::error::GUT log $log is missing or empty"
  exit 1
fi
plain="$(sed -e 's/\x1b\[[0-9;]*m//g' "$log")"
rc=0
pattern='SCRIPT ERROR:|Parse Error:|Failed to load script|Ignoring script .* because it does not extend GutTest|GUT GATE FAILED'
if hits="$(grep -nE "$pattern" <<<"$plain")"; then
  echo "::error::GUT log shows test scripts that failed to load or parse:"
  echo "$hits"
  rc=1
fi
files="$(find "$tests_dir" -type f -name 'test_*.gd' | wc -l)"
scripts="$(awk '/^Scripts[[:space:]]+[0-9]+/ {n=$2} END {print n}' <<<"$plain")"
if [ -z "$scripts" ]; then
  echo "::error::no 'Scripts N' line in the GUT run summary"
  rc=1
elif [ "$scripts" -lt "$files" ]; then
  echo "::error::GUT ran $scripts test scripts but there are $files test_*.gd files under $tests_dir"
  rc=1
fi
echo "GUT log check: $files test_*.gd files, GUT summary Scripts=${scripts:-?}"
exit "$rc"
