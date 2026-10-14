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
  grep -qs '^workloadId:' "$dir/.datarobot.yaml" ||
    printf 'workloadId: %s\nname: app\n' "${DR_STUB_WORKLOAD_ID:-wl-new}" >"$dir/.datarobot.yaml"
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
  printf '#!/usr/bin/env bash\necho "stub dr %s"\n' "$version" >"$src/dr"
  chmod +x "$src/dr"
  tar -czf "$BATS_TEST_TMPDIR/releases/$version/$ASSET" -C "$src" dr
  ASSET_SHA=$(sha256_of "$BATS_TEST_TMPDIR/releases/$version/$ASSET")
}
