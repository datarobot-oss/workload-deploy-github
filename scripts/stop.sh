#!/usr/bin/env bash
set -eu
# ================================================================== #
#  DataRobot Workload stop.                                          #
#                                                                    #
#  Resolves the workload the same way the deploy script does (by     #
#  name, from the manifest / workload_name input) and stops it.      #
#  Stopping is async and non-destructive: the workload is not        #
#  deleted and a later deploy brings it straight back.               #
#                                                                    #
#  Ported from the GitLab CI/CD component's on_stop job.             #
# ================================================================== #

# shellcheck source=scripts/common.sh
. "${SCRIPT_DIR:?SCRIPT_DIR must point at the action scripts directory}/common.sh"

# ---------- 0. Preflight + tooling -------------------------------- #
require_credentials
resolve_manifest
install_tooling

# ---------- 1. Resolve the workload name -------------------------- #
NAME="$(yq -r '.name' "$MANIFEST")"
[ -n "$NAME" ] && [ "$NAME" != "null" ] || die "Manifest is missing required field: name"
WORKLOAD_NAME="${DR_WORKLOAD_NAME:-$NAME}"

# ---------- 2. Find the workload and stop it ---------------------- #
WID="$(dr workload list --output-format json | jq -r --arg n "$WORKLOAD_NAME" '.workloads[]? | select(.name==$n) | .id' | head -1)"
if [ -z "$WID" ]; then
  log "No workload named '$WORKLOAD_NAME' found — nothing to stop."
  exit 0
fi

log "Stopping workload '$WORKLOAD_NAME' ($WID).."
dr workload stop "$WID"

# ---------- 3. Wait for it to reach 'stopped' --------------------- #
# The stop is asynchronous (stopping → stopped); confirm it settled.
DEADLINE=$(($(date +%s) + DR_WAIT_TIMEOUT))
while :; do
  ST="$(dr workload get "$WID" --output-format json | jq -r '.status // .data.status // "unknown"' | tr '[:upper:]' '[:lower:]')"
  case "$ST" in
  stopped)
    echo "  ✓ workload stopped"
    break
    ;;
  failed) die "Workload entered a failed state while stopping. Check: dr workload logs $WID" ;;
  *)
    [ "$(date +%s)" -lt "$DEADLINE" ] || die "Timed out waiting for the workload to stop."
    printf '  status: %s\r' "$ST"
    sleep 10
    ;;
  esac
done

printf '\n\033[32m✓ Stopped %s\033[0m — restart with a new deploy or `dr workload start %s`.\n\n' "$WORKLOAD_NAME" "$WID"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "## ✓ Stopped \`$WORKLOAD_NAME\` (\`$WID\`)" >>"$GITHUB_STEP_SUMMARY"
  echo "" >>"$GITHUB_STEP_SUMMARY"
  echo "Non-destructive — a later deploy or \`dr workload start $WID\` brings it back." >>"$GITHUB_STEP_SUMMARY"
fi
