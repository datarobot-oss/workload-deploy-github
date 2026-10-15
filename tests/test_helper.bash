# Shared fixtures for the bats tests. Load with `load test_helper`.

# Put stubs for `dr` and `docker` first on PATH.
#
# The stub `dr` appends its arguments to $DR_CALLS. `workload up` fails with
# $DR_STUB_UP_EXIT when that is set, prints only a plan for --dry-run, and
# otherwise writes a manifest with workloadId $DR_STUB_WORKLOAD_ID unless the
# manifest in --dir already has one. `workload endpoint` prints
# $DR_STUB_ENDPOINT.
#
# The stub `docker` appends its arguments to $DOCKER_CALLS, one per line, and
# the DATAROBOT_ENDPOINT it sees to $DOCKER_CALLS.endpoint. It exits with
# $DOCKER_STUB_EXIT and never runs a container.
install_stubs() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export DR_CALLS="$BATS_TEST_TMPDIR/dr-calls"
  export DOCKER_CALLS="$BATS_TEST_TMPDIR/docker-calls"
  : >"$DR_CALLS"
  : >"$DOCKER_CALLS"

  cat >"$BATS_TEST_TMPDIR/bin/dr" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$DR_CALLS"
echo "$DATAROBOT_ENDPOINT" >>"$DR_CALLS.endpoint"
dir=.
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" = --dir ] && dir="${args[$((i + 1))]}"
done
case "$1 $2" in
"workload up")
  [ "${DR_STUB_UP_EXIT:-0}" -eq 0 ] || exit "$DR_STUB_UP_EXIT"
  case " $* " in *" --dry-run "*)
    echo "plan only"
    exit 0
    ;;
  esac
  if ! grep -qs '^workloadId:' "$dir/.datarobot.yaml"; then
    # Like the real CLI: add the ID at the top and keep the rest of the manifest.
    {
      printf 'workloadId: %s\n' "${DR_STUB_WORKLOAD_ID:-wl-new}"
      cat "$dir/.datarobot.yaml" 2>/dev/null || printf 'name: app\n'
    } >"$dir/.datarobot.yaml.new"
    mv "$dir/.datarobot.yaml.new" "$dir/.datarobot.yaml"
  fi
  ;;
"workload endpoint")
  echo "${DR_STUB_ENDPOINT:-https://dr.example.com/workloads/wl/}"
  ;;
esac
EOF

  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$DOCKER_CALLS"
echo "$DATAROBOT_ENDPOINT" >>"$DOCKER_CALLS.endpoint"
exit "${DOCKER_STUB_EXIT:-0}"
EOF

  chmod +x "$BATS_TEST_TMPDIR/bin/dr" "$BATS_TEST_TMPDIR/bin/docker"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
