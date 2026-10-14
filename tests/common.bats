#!/usr/bin/env bats
# Tests for scripts/common.sh. Each test runs the helpers in a fresh bash,
# because `die` calls `exit` and would end the test shell if sourced here.

bats_require_minimum_version 1.5.0

setup() {
  COMMON="$BATS_TEST_DIRNAME/../scripts/common.sh"
  # common.sh may create $HOME/.local/bin, so keep it out of the real home.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  cd "$BATS_TEST_TMPDIR"
  unset DATAROBOT_ENDPOINT DATAROBOT_API_TOKEN DR_MANIFEST
}

# Run one helper from common.sh in a fresh shell.
call() {
  bash -c 'source "$1"; shift; "$@"' _ "$COMMON" "$@"
}

# Print the MANIFEST that resolve_manifest picks, with its log line dropped.
resolved_manifest() {
  bash -c 'source "$1"; resolve_manifest >/dev/null; printf %s "$MANIFEST"' _ "$COMMON"
}

@test "die prints the message to stderr and exits 1" {
  run --separate-stderr call die "something broke"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"something broke"* ]]
}

@test "have is true for a command on PATH" {
  run call have bash
  [ "$status" -eq 0 ]
}

@test "have is false for a missing command" {
  run call have no-such-command-here
  [ "$status" -eq 1 ]
}

@test "require_credentials passes when both variables are set" {
  DATAROBOT_ENDPOINT=https://app.example.com DATAROBOT_API_TOKEN=token run call require_credentials
  [ "$status" -eq 0 ]
}

@test "require_credentials fails and names the endpoint when it is missing" {
  DATAROBOT_API_TOKEN=token run call require_credentials
  [ "$status" -eq 1 ]
  [[ "$output" == *"DATAROBOT_ENDPOINT is not set"* ]]
}

@test "require_credentials fails and names the token when it is missing" {
  DATAROBOT_ENDPOINT=https://app.example.com run call require_credentials
  [ "$status" -eq 1 ]
  [[ "$output" == *"DATAROBOT_API_TOKEN is not set"* ]]
}

@test "require_credentials treats an empty value as missing" {
  DATAROBOT_ENDPOINT="" DATAROBOT_API_TOKEN=token run call require_credentials
  [ "$status" -eq 1 ]
}

@test "resolve_manifest picks .datarobot.yaml" {
  touch .datarobot.yaml
  run resolved_manifest
  [ "$status" -eq 0 ]
  [ "$output" = ".datarobot.yaml" ]
}

@test "resolve_manifest falls back to .datarobot/workload.yaml" {
  mkdir .datarobot
  touch .datarobot/workload.yaml
  run resolved_manifest
  [ "$status" -eq 0 ]
  [ "$output" = ".datarobot/workload.yaml" ]
}

@test "resolve_manifest prefers .datarobot.yaml when both exist" {
  mkdir .datarobot
  touch .datarobot.yaml .datarobot/workload.yaml
  run resolved_manifest
  [ "$output" = ".datarobot.yaml" ]
}

@test "resolve_manifest uses DR_MANIFEST over the defaults" {
  touch .datarobot.yaml custom.yaml
  DR_MANIFEST=custom.yaml run resolved_manifest
  [ "$status" -eq 0 ]
  [ "$output" = "custom.yaml" ]
}

@test "resolve_manifest fails when DR_MANIFEST points at a missing file" {
  touch .datarobot.yaml
  DR_MANIFEST=missing.yaml run call resolve_manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"Manifest 'missing.yaml' not found"* ]]
}

@test "resolve_manifest fails when there is no manifest" {
  run call resolve_manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"No manifest found"* ]]
}
