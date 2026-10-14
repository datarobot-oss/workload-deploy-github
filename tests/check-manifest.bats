#!/usr/bin/env bats
# Tests for scripts/check-manifest.sh, the guard that stops CI from creating a
# new workload on every run.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-manifest.sh"
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP"
  # Stop the upward search at the temp directory, so the result does not depend
  # on the machine.
  export DR_SEARCH_ROOT="$BATS_TEST_TMPDIR"
  unset DR_WORKING_DIRECTORY DR_ALLOW_CREATE
}

@test "passes when the manifest has a workloadId" {
  printf 'workloadId: 6acea30927f030812dbcfe3a # managed by the CLI\nname: app\n' >"$APP/.datarobot.yaml"

  DR_WORKING_DIRECTORY="$APP" run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"6acea30927f030812dbcfe3a"* ]]
}

@test "finds the manifest in a parent of the working directory" {
  printf 'workloadId: wl-parent\n' >"$APP/.datarobot.yaml"
  mkdir -p "$APP/service/src"

  DR_WORKING_DIRECTORY="$APP/service/src" run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"wl-parent"* ]]
}

@test "fails when the manifest has no workloadId" {
  printf 'name: app\nimportance: low\n' >"$APP/.datarobot.yaml"

  DR_WORKING_DIRECTORY="$APP" run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"workloadId"* ]]
  [[ "$output" == *"allow_create"* ]]
}

@test "fails when the workloadId is empty" {
  printf 'workloadId:\nname: app\n' >"$APP/.datarobot.yaml"

  DR_WORKING_DIRECTORY="$APP" run "$SCRIPT"

  [ "$status" -eq 1 ]
}

@test "fails when the workloadId is only a comment" {
  printf '# workloadId: wl-old\nname: app\n' >"$APP/.datarobot.yaml"

  DR_WORKING_DIRECTORY="$APP" run "$SCRIPT"

  [ "$status" -eq 1 ]
}

@test "fails when there is no manifest" {
  DR_WORKING_DIRECTORY="$APP" run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"workloadId"* ]]
}

@test "allows a missing workloadId when allow_create is true" {
  printf 'name: app\n' >"$APP/.datarobot.yaml"

  DR_WORKING_DIRECTORY="$APP" DR_ALLOW_CREATE=true run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"creates a new workload"* ]]
}

@test "allows a missing manifest when allow_create is true" {
  DR_WORKING_DIRECTORY="$APP" DR_ALLOW_CREATE=true run "$SCRIPT"

  [ "$status" -eq 0 ]
}

@test "treats any allow_create value other than true as false" {
  printf 'name: app\n' >"$APP/.datarobot.yaml"

  DR_WORKING_DIRECTORY="$APP" DR_ALLOW_CREATE=yes run "$SCRIPT"

  [ "$status" -eq 1 ]
}
