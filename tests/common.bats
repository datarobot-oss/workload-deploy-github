#!/usr/bin/env bats
# Tests for scripts/common.sh. Each test runs the helpers in a fresh bash,
# because `die` calls `exit` and would end the test shell if sourced here.

bats_require_minimum_version 1.5.0

setup() {
  COMMON="$BATS_TEST_DIRNAME/../scripts/common.sh"
  cd "$BATS_TEST_TMPDIR"
  # find_manifest stops at this directory, so a stray manifest above the temp
  # directory cannot change the result.
  export DR_SEARCH_ROOT="$BATS_TEST_TMPDIR"
  unset DATAROBOT_ENDPOINT DATAROBOT_API_TOKEN
}

# Run one helper from common.sh in a fresh shell.
call() {
  bash -c 'source "$1"; shift; "$@"' _ "$COMMON" "$@"
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

@test "find_manifest prints the manifest in the given directory" {
  touch .datarobot.yaml
  run call find_manifest .
  [ "$status" -eq 0 ]
  [ "$output" = "$(pwd -P)/.datarobot.yaml" ]
}

@test "find_manifest searches upward from a subdirectory" {
  touch .datarobot.yaml
  mkdir -p service/src
  run call find_manifest service/src
  [ "$status" -eq 0 ]
  [ "$output" = "$(pwd -P)/.datarobot.yaml" ]
}

@test "find_manifest prefers the nearest manifest" {
  touch .datarobot.yaml
  mkdir service
  touch service/.datarobot.yaml
  run call find_manifest service
  [ "$output" = "$(pwd -P)/service/.datarobot.yaml" ]
}

@test "find_manifest fails when there is no manifest up to the search root" {
  mkdir empty
  run call find_manifest empty
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "find_manifest does not look above the search root" {
  touch .datarobot.yaml
  mkdir inner
  DR_SEARCH_ROOT="$(pwd -P)/inner" run call find_manifest inner
  [ "$status" -eq 1 ]
}

@test "find_manifest fails when the directory does not exist" {
  run call find_manifest no-such-directory
  [ "$status" -eq 1 ]
}

@test "manifest_workload_id prints the id and drops the trailing comment" {
  printf 'workloadId: abc123 # managed by the CLI\nname: app\n' >m.yaml
  run call manifest_workload_id m.yaml
  [ "$status" -eq 0 ]
  [ "$output" = "abc123" ]
}

@test "manifest_workload_id prints nothing when there is no workloadId" {
  printf 'name: app\n' >m.yaml
  run call manifest_workload_id m.yaml
  [ -z "$output" ]
}

@test "manifest_workload_id ignores an empty value" {
  printf 'workloadId:\nname: app\n' >m.yaml
  run call manifest_workload_id m.yaml
  [ -z "$output" ]
}

@test "manifest_workload_id ignores a commented-out line" {
  printf '# workloadId: abc123\nname: app\n' >m.yaml
  run call manifest_workload_id m.yaml
  [ -z "$output" ]
}

@test "manifest_workload_id ignores a nested key of the same name" {
  printf 'runtime:\n  workloadId: nested\n' >m.yaml
  run call manifest_workload_id m.yaml
  [ -z "$output" ]
}
