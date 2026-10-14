#!/usr/bin/env bash
# Deploy the app with `dr workload up` and report the workload.
#
# A dry run passes the same flags plus --dry-run, so the plan matches what the
# apply does. After a real run the script writes workload_id and endpoint to
# GITHUB_OUTPUT and a summary to GITHUB_STEP_SUMMARY.
#
# Environment: DATAROBOT_ENDPOINT, DATAROBOT_API_TOKEN, DR_WORKING_DIRECTORY
# (default .), DR_PROMOTE (default true), DR_DRY_RUN (default false).
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_credentials
normalize_endpoint

dir="${DR_WORKING_DIRECTORY:-.}"

args=(workload up --yes --dir "$dir")
if [ "${DR_PROMOTE:-true}" = true ]; then
  args+=(--promote)
fi
if [ "${DR_DRY_RUN:-false}" = true ]; then
  args+=(--dry-run)
fi

id_before=""
if manifest=$(find_manifest "$dir"); then
  id_before=$(manifest_workload_id "$manifest")
fi

log "dr ${args[*]}"
dr "${args[@]}"

if [ "${DR_DRY_RUN:-false}" = true ]; then
  exit 0
fi

manifest=$(find_manifest "$dir") || die "dr workload up finished, but there is no .datarobot.yaml under $dir."
workload_id=$(manifest_workload_id "$manifest")
[ -n "$workload_id" ] || die "dr workload up finished, but $manifest has no workloadId."
endpoint=$(dr workload endpoint --dir "$dir")

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "workload_id=$workload_id"
    echo "endpoint=$endpoint"
  } >>"$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### DataRobot workload deployed"
    echo
    echo "- Workload: \`$workload_id\`"
    echo "- Endpoint: $endpoint"
    if [ -z "$id_before" ]; then
      echo
      echo "> **Commit this \`.datarobot.yaml\`.** This run created the workload, and the checkout is discarded. Without the \`workloadId\` line, the next run creates another workload."
      echo
      echo '```yaml'
      cat "$manifest"
      echo '```'
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi

log "Workload $workload_id is at $endpoint"
