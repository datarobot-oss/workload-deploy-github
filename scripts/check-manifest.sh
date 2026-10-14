#!/usr/bin/env bash
# Fail unless the manifest names the workload to roll.
#
# `dr workload up` finds its workload through the workloadId in .datarobot.yaml.
# A CI checkout starts clean, so a manifest without the ID makes every run try
# to create a new workload. This guard turns that into an error. Set
# DR_ALLOW_CREATE=true for the one run that creates the workload.
#
# Environment: DR_WORKING_DIRECTORY (default .), DR_ALLOW_CREATE (default false).
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

dir="${DR_WORKING_DIRECTORY:-.}"

workload_id=""
if manifest=$(find_manifest "$dir"); then
  workload_id=$(manifest_workload_id "$manifest")
fi

if [ -n "$workload_id" ]; then
  log "Rolling workload $workload_id (from $manifest)"
  exit 0
fi

if [ "${DR_ALLOW_CREATE:-false}" = true ]; then
  log "The manifest has no workloadId, so this run creates a new workload. Commit the workloadId it writes, or the next run creates another one."
  exit 0
fi

die "No workloadId found in .datarobot.yaml (searched from '$dir' upward). Run 'dr workload up' once on a machine you control and commit the manifest, so CI rolls that workload. Without an ID, every run tries to create a new one. To create the workload from CI this once, set allow_create: true."
