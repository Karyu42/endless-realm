#!/usr/bin/env bash
# Usage: has-make-target.sh <target> [makefile]
# Exits 0 if the Makefile defines an explicit rule for <target>, 1 otherwise.
# Uses make's database dump (-p) with -q, so no recipe is ever executed.
set -uo pipefail
target="$1"
makefile="${2:-Makefile}"
[ -f "$makefile" ] || exit 1
db="$(make -f "$makefile" -pRrq : 2>/dev/null || true)"   # -q exits non-zero by design; we only want the dump
awk -v t="$target" -F: '
  /^# Not a target/ { skip=1; next }
  /^[^#\t.][^=]*:/  { if (!skip && $1 == t) found=1 }
  !/^#/             { skip=0 }
  END { exit found ? 0 : 1 }' <<< "$db"
