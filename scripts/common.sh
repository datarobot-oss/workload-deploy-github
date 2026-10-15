#!/usr/bin/env bash
# Helpers shared by the scripts in this directory. Source this file.

# Print a log line. `die` prints an error and exits 1.
log() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die() {
  printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# Fail with a message about credentials when the endpoint or the token is
# missing.
require_credentials() {
  [ -n "${DATAROBOT_ENDPOINT:-}" ] || die "DATAROBOT_ENDPOINT is not set. Pass the datarobot_endpoint input or set the variable."
  [ -n "${DATAROBOT_API_TOKEN:-}" ] || die "DATAROBOT_API_TOKEN is not set. Pass the datarobot_api_token input from a secret or set the variable."
}

# Check that the CLI can run. With DR_CLI_IMAGE set, Docker must be present and
# the image must have a release tag or a digest, not the latest tag.
require_cli() {
  [ -n "${DR_CLI_IMAGE:-}" ] || return 0
  have docker || die "Docker is not available. The action runs the DataRobot CLI from a container image, so it needs a Linux runner with Docker."
  # Check the last path component, so a registry port is not a tag.
  case "${DR_CLI_IMAGE##*/}" in
  *@*) ;;
  *:latest) die "dr_cli_image $DR_CLI_IMAGE uses the latest tag. Pin a release tag or a digest." ;;
  *:*) ;;
  *) die "dr_cli_image $DR_CLI_IMAGE has no tag. Pin a release tag or a digest." ;;
  esac
}

# Run the DataRobot CLI from PATH, or in the DR_CLI_IMAGE container when it is
# set. The container runs as the runner's user, so the files it writes stay
# writable, and mounts the search root at the same path, so --dir resolves the
# same way. The credentials and the proxy variables pass by name, so no value
# appears on the command line.
dr() {
  if [ -z "${DR_CLI_IMAGE:-}" ]; then
    command dr "$@"
    return
  fi
  local root
  root=$(cd "${DR_SEARCH_ROOT:-${GITHUB_WORKSPACE:-$PWD}}" && pwd -P) || return 1
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --volume "$root:$root" \
    --workdir "$(pwd -P)" \
    --env HOME=/tmp \
    --env DATAROBOT_ENDPOINT \
    --env DATAROBOT_API_TOKEN \
    --env HTTP_PROXY --env HTTPS_PROXY --env NO_PROXY \
    --env http_proxy --env https_proxy --env no_proxy \
    "$DR_CLI_IMAGE" "$@"
}

# Make DATAROBOT_ENDPOINT end in /api/v2, which the CLI requires. Accept the URL
# with or without the suffix and a trailing slash.
normalize_endpoint() {
  local endpoint="${DATAROBOT_ENDPOINT%/}"
  case "$endpoint" in
  */api/v2) ;;
  *) endpoint="$endpoint/api/v2" ;;
  esac
  DATAROBOT_ENDPOINT="$endpoint"
  export DATAROBOT_ENDPOINT
}

# Print the path of the nearest .datarobot.yaml, searching upward from $1 as the
# CLI does. Stop at DR_SEARCH_ROOT (default: the workspace), so a manifest
# outside the checkout is never used. Return 1 when there is none.
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

# Print the top-level workloadId of the manifest $1, or nothing. A
# commented-out, empty or nested key doesn't count.
manifest_workload_id() {
  sed -n -E 's/^workloadId:[[:space:]]*([^[:space:]#]+).*/\1/p' "$1" | head -n 1 | tr -d "'\""
}
