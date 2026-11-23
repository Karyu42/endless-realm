#!/usr/bin/env bash
# Usage: skip-notice.sh "<reason>"   -> emits "skipped: <reason>" as a notice + job summary line.
set -euo pipefail
msg="skipped: $1"
echo "::notice title=${GITHUB_JOB:-job} skipped::${msg}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "### ${GITHUB_JOB:-job}: ${msg}" >> "$GITHUB_STEP_SUMMARY"; fi
