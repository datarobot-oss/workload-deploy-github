#!/usr/bin/env bats
# Tests for scripts/deploy.sh and scripts/stop.sh, run against a stub `dr`.

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/../scripts/deploy.sh"
  STOP="$BATS_TEST_DIRNAME/../scripts/stop.sh"
  install_stubs
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP"
  printf 'workloadId: wl-existing\nname: app\n' >"$APP/.datarobot.yaml"
  export DR_WORKING_DIRECTORY="$APP"
  export DR_SEARCH_ROOT="$BATS_TEST_TMPDIR"
  export DATAROBOT_ENDPOINT=https://app.example.com
  export DATAROBOT_API_TOKEN=token
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/github-summary"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  unset DR_DRY_RUN DR_PROMOTE DR_STUB_UP_EXIT DR_STUB_WORKLOAD_ID
}

@test "deploy runs up with --yes, --promote and the working directory" {
  run "$DEPLOY"

  [ "$status" -eq 0 ]
  grep -qx "workload up --yes --dir $APP --promote" "$DR_CALLS"
}

@test "deploy leaves out --promote when promote is false" {
  DR_PROMOTE=false run "$DEPLOY"

  [ "$status" -eq 0 ]
  grep -qx "workload up --yes --dir $APP" "$DR_CALLS"
}

@test "a dry run adds --dry-run to the same flags and writes no outputs" {
  DR_DRY_RUN=true run "$DEPLOY"

  [ "$status" -eq 0 ]
  grep -qx "workload up --yes --dir $APP --promote --dry-run" "$DR_CALLS"
  ! grep -q "workload endpoint" "$DR_CALLS"
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "deploy writes the workload id and the endpoint to GITHUB_OUTPUT" {
  DR_STUB_ENDPOINT=https://dr.example.com/workloads/wl-existing/ run "$DEPLOY"

  [ "$status" -eq 0 ]
  grep -qx "workload_id=wl-existing" "$GITHUB_OUTPUT"
  grep -qx "endpoint=https://dr.example.com/workloads/wl-existing/" "$GITHUB_OUTPUT"
}

@test "deploy passes on the exit code of up and writes no outputs when up fails" {
  DR_STUB_UP_EXIT=7 run "$DEPLOY"

  [ "$status" -eq 7 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "deploy fails before calling dr when the token is missing" {
  unset DATAROBOT_API_TOKEN

  run "$DEPLOY"

  [ "$status" -eq 1 ]
  [[ "$output" == *"DATAROBOT_API_TOKEN is not set"* ]]
  [ ! -s "$DR_CALLS" ]
}

@test "a deploy that rolls an existing workload does not ask to commit anything" {
  run "$DEPLOY"

  [ "$status" -eq 0 ]
  ! grep -q "Commit" "$GITHUB_STEP_SUMMARY"
}

@test "a deploy that creates a workload prints the whole manifest to commit" {
  printf 'name: app\nimportance: low\n' >"$APP/.datarobot.yaml"

  DR_STUB_WORKLOAD_ID=wl-created run "$DEPLOY"

  [ "$status" -eq 0 ]
  grep -q "Commit this" "$GITHUB_STEP_SUMMARY"
  grep -q "workloadId: wl-created" "$GITHUB_STEP_SUMMARY"
  grep -q "importance: low" "$GITHUB_STEP_SUMMARY"
  grep -qx "workload_id=wl-created" "$GITHUB_OUTPUT"
}

@test "a deploy that creates a workload without any manifest still prints the manifest" {
  rm "$APP/.datarobot.yaml"

  DR_STUB_WORKLOAD_ID=wl-created run "$DEPLOY"

  [ "$status" -eq 0 ]
  grep -q "workloadId: wl-created" "$GITHUB_STEP_SUMMARY"
  grep -q "name: app" "$GITHUB_STEP_SUMMARY"
}

@test "stop runs workload stop with --yes and the working directory" {
  run "$STOP"

  [ "$status" -eq 0 ]
  grep -qx "workload stop --yes --dir $APP" "$DR_CALLS"
}

@test "stop passes on the exit code of dr" {
  cat >"$BATS_TEST_TMPDIR/bin/dr" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF

  run "$STOP"

  [ "$status" -eq 9 ]
}

@test "stop fails before calling dr when the endpoint is missing" {
  unset DATAROBOT_ENDPOINT

  run "$STOP"

  [ "$status" -eq 1 ]
  [[ "$output" == *"DATAROBOT_ENDPOINT is not set"* ]]
  [ ! -s "$DR_CALLS" ]
}
