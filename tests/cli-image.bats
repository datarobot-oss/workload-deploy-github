#!/usr/bin/env bats
# Tests for how scripts/common.sh runs the DataRobot CLI: `dr` and require_cli.
# The `docker` stub records its arguments and never runs a container.

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  COMMON="$BATS_TEST_DIRNAME/../scripts/common.sh"
  install_stubs
  WORKSPACE="$BATS_TEST_TMPDIR/workspace"
  mkdir -p "$WORKSPACE/app"
  cd "$WORKSPACE/app"
  export DR_SEARCH_ROOT="$WORKSPACE"
  export DATAROBOT_ENDPOINT=https://app.example.com/api/v2
  export DATAROBOT_API_TOKEN=s3cret-token-value
  unset DR_CLI_IMAGE
}

# Run one helper from common.sh in a fresh shell.
call() {
  bash -c 'source "$1"; shift; "$@"' _ "$COMMON" "$@"
}

@test "dr runs the dr on PATH when no image is set" {
  run call dr workload endpoint

  [ "$status" -eq 0 ]
  grep -qx "workload endpoint" "$DR_CALLS"
  [ ! -s "$DOCKER_CALLS" ]
}

@test "dr runs the CLI image with the arguments after the image" {
  DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:v0.14.1 run call dr workload up --yes

  [ "$status" -eq 0 ]
  [ ! -s "$DR_CALLS" ]
  [ "$(grep -x -A3 'ghcr.io/datarobot-oss/cli:v0.14.1' "$DOCKER_CALLS" | tr '\n' ' ')" = "ghcr.io/datarobot-oss/cli:v0.14.1 workload up --yes " ]
}

@test "dr runs the container as the runner user so the workspace stays writable" {
  DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:v0.14.1 run call dr workload up

  grep -qx -- "--user" "$DOCKER_CALLS"
  grep -qx "$(id -u):$(id -g)" "$DOCKER_CALLS"
}

@test "dr mounts the search root at the same path and starts in the current directory" {
  DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:v0.14.1 run call dr workload up

  root=$(cd "$WORKSPACE" && pwd -P)
  grep -qx -- "--volume" "$DOCKER_CALLS"
  grep -qx "$root:$root" "$DOCKER_CALLS"
  grep -qx -- "--workdir" "$DOCKER_CALLS"
  grep -qx "$(pwd -P)" "$DOCKER_CALLS"
}

@test "dr mounts GITHUB_WORKSPACE when there is no search root" {
  unset DR_SEARCH_ROOT

  GITHUB_WORKSPACE="$WORKSPACE" DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:v0.14.1 run call dr workload up

  root=$(cd "$WORKSPACE" && pwd -P)
  grep -qx "$root:$root" "$DOCKER_CALLS"
}

@test "dr hands the endpoint and the token to the container by name, not by value" {
  DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:v0.14.1 run call dr workload up

  grep -qx "DATAROBOT_ENDPOINT" "$DOCKER_CALLS"
  grep -qx "DATAROBOT_API_TOKEN" "$DOCKER_CALLS"
  ! grep -q "s3cret-token-value" "$DOCKER_CALLS"
}

@test "dr hands the proxy variables of the runner to the container by name" {
  HTTPS_PROXY=http://proxy.example:3128 no_proxy=internal.example DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:v0.14.1 run call dr workload up

  for name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    grep -qx "$name" "$DOCKER_CALLS"
  done
  ! grep -q "proxy.example" "$DOCKER_CALLS"
  ! grep -q "internal.example" "$DOCKER_CALLS"
}

@test "dr passes on the exit code of the container" {
  DOCKER_STUB_EXIT=7 DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:v0.14.1 run call dr workload up

  [ "$status" -eq 7 ]
}

@test "require_cli passes when no image is set" {
  run call require_cli

  [ "$status" -eq 0 ]
}

@test "require_cli accepts an image with a version tag" {
  DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:v0.14.1 run call require_cli

  [ "$status" -eq 0 ]
}

@test "require_cli accepts an image pinned by digest" {
  DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef run call require_cli

  [ "$status" -eq 0 ]
}

@test "require_cli accepts a mirror with a registry port" {
  DR_CLI_IMAGE=registry.example.com:5000/mirror/cli:v0.14.1 run call require_cli

  [ "$status" -eq 0 ]
}

@test "require_cli rejects the latest tag" {
  DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:latest run call require_cli

  [ "$status" -eq 1 ]
  [[ "$output" == *"latest"* ]]
}

@test "require_cli rejects an image with no tag" {
  DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli run call require_cli

  [ "$status" -eq 1 ]
  [[ "$output" == *"no tag"* ]]
}

@test "require_cli rejects an untagged image on a registry with a port" {
  DR_CLI_IMAGE=registry.example.com:5000/mirror/cli run call require_cli

  [ "$status" -eq 1 ]
  [[ "$output" == *"no tag"* ]]
}

@test "require_cli fails with a clear message when docker is missing" {
  DR_CLI_IMAGE=ghcr.io/datarobot-oss/cli:v0.14.1 run bash -c 'source "$1"; have() { return 1; }; require_cli' _ "$COMMON"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker"* ]]
}

# The default image of an action, read from the repo.
default_cli_image() {
  awk '
    $1 == "dr_cli_image:" { found = 1; next }
    found && $1 == "default:" { print $2; exit }
  ' "$BATS_TEST_DIRNAME/../$1"
}

@test "the default CLI image of the deploy action is tagged with a release, not latest" {
  image=$(default_cli_image action.yml)

  [[ "$image" == ghcr.io/datarobot-oss/cli:v* ]]
}

@test "the deploy and stop actions default to the same CLI image" {
  [ -n "$(default_cli_image action.yml)" ]
  [ "$(default_cli_image action.yml)" = "$(default_cli_image stop/action.yml)" ]
}
