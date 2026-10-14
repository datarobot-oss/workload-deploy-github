#!/usr/bin/env bash
# Stop the workload named by the manifest with `dr workload stop`.
#
# Environment: DATAROBOT_ENDPOINT, DATAROBOT_API_TOKEN, DR_WORKING_DIRECTORY
# (default .).
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_credentials

dir="${DR_WORKING_DIRECTORY:-.}"

log "dr workload stop --yes --dir $dir"
dr workload stop --yes --dir "$dir"
