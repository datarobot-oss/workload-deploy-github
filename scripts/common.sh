#!/usr/bin/env bash
# Helpers shared by the scripts in this directory. Source this file.

# Print a log line. `die` prints to stderr and exits 1, so a step fails with a
# readable reason.
log() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die() {
  printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# The DataRobot CLI reads these two variables. The action sets them from its
# inputs, and this check turns a missing one into a message about credentials
# instead of a CLI error.
require_credentials() {
  [ -n "${DATAROBOT_ENDPOINT:-}" ] || die "DATAROBOT_ENDPOINT is not set. Pass the datarobot_endpoint input or set the variable."
  [ -n "${DATAROBOT_API_TOKEN:-}" ] || die "DATAROBOT_API_TOKEN is not set. Pass the datarobot_api_token input from a secret or set the variable."
}

# Print the path of the nearest .datarobot.yaml, searching upward from $1 the
# way the CLI does. The search stops at DR_SEARCH_ROOT, which defaults to the
# workspace in CI, so a manifest outside the checkout is never used. Return 1
# when there is none.
find_manifest() {
  local dir root
  dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  root="${DR_SEARCH_ROOT:-${GITHUB_WORKSPACE:-/}}"
  root=$(cd "$root" 2>/dev/null && pwd -P) || root=/
  while :; do
    if [ -f "$dir/.datarobot.yaml" ]; then
      printf '%s\n' "$dir/.datarobot.yaml"
      return 0
    fi
    if [ "$dir" = "$root" ] || [ "$dir" = / ]; then
      return 1
    fi
    dir=$(dirname "$dir")
  done
}

# Print the top-level workloadId of the manifest $1, or nothing when it has
# none. A commented-out, empty or nested key does not count.
manifest_workload_id() {
  sed -n -E 's/^workloadId:[[:space:]]*([^[:space:]#]+).*/\1/p' "$1" | head -n 1 | tr -d "'\""
}
