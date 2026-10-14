# Shared fixtures for the bats tests. Load with `load test_helper`.

# Put stubs for `dr` and `uname` first on PATH.
#
# The stub `dr` appends its arguments to $DR_CALLS. `workload up` fails with
# $DR_STUB_UP_EXIT when that is set, prints only a plan for --dry-run, and
# otherwise writes a manifest with workloadId $DR_STUB_WORKLOAD_ID unless the
# manifest in --dir already has one. `workload endpoint` prints
# $DR_STUB_ENDPOINT.
#
# The stub `uname` reports $UNAME_S and $UNAME_M, so the platform is the same
# on every machine that runs the tests.
install_stubs() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export DR_CALLS="$BATS_TEST_TMPDIR/dr-calls"
  : >"$DR_CALLS"

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

  cat >"$BATS_TEST_TMPDIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
-s) echo "${UNAME_S:-Linux}" ;;
-m) echo "${UNAME_M:-x86_64}" ;;
esac
EOF

  chmod +x "$BATS_TEST_TMPDIR/bin/dr" "$BATS_TEST_TMPDIR/bin/uname"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# The SHA-256 of a file, as a bare hex string.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Build a fake release of the CLI under $DR_CLI_DOWNLOAD_BASE/<version>/.
# Usage: make_release <version> [<platform>]   (platform defaults to Linux_x86_64)
# Sets ASSET to the tarball name and ASSET_SHA to its SHA-256. The tarball holds
# one executable, `dr`, that prints a version line.
# shellcheck disable=SC2034  # ASSET and ASSET_SHA are read by the tests that call this.
make_release() {
  local version=$1 platform=${2:-Linux_x86_64} src
  ASSET="dr_${version}_${platform}.tar.gz"
  src="$BATS_TEST_TMPDIR/release-src"
  mkdir -p "$src" "$BATS_TEST_TMPDIR/releases/$version"
  # The stub prints a flood of extra lines when STUB_VERSION_NOISE is set.
  cat >"$src/dr" <<EOF
#!/usr/bin/env bash
echo "stub dr $version"
if [ -n "\${STUB_VERSION_NOISE:-}" ]; then
  seq 1 100000
fi
EOF
  chmod +x "$src/dr"
  tar -czf "$BATS_TEST_TMPDIR/releases/$version/$ASSET" -C "$src" dr
  ASSET_SHA=$(sha256_of "$BATS_TEST_TMPDIR/releases/$version/$ASSET")
}
