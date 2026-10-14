#!/usr/bin/env bats
# Tests for scripts/install-dr-cli.sh. The download is a file:// URL, so nothing
# here touches the network.

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/install-dr-cli.sh"
  install_stubs
  export DR_CLI_INSTALL_DIR="$BATS_TEST_TMPDIR/install"
  export DR_CLI_DOWNLOAD_BASE="file://$BATS_TEST_TMPDIR/releases"
  export DR_CLI_CHECKSUMS="$BATS_TEST_TMPDIR/checksums.txt"
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github-path"
  : >"$DR_CLI_CHECKSUMS"
  : >"$GITHUB_PATH"
  unset DR_CLI_SHA256
}

@test "installs the release when its checksum is in the table" {
  make_release v9.9.9
  echo "$ASSET_SHA  $ASSET" >"$DR_CLI_CHECKSUMS"

  DR_CLI_VERSION=v9.9.9 run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -x "$DR_CLI_INSTALL_DIR/dr" ]
  [[ "$output" == *"stub dr v9.9.9"* ]]
}

@test "installs and prints one version line when dr --version is chatty" {
  make_release v9.9.9
  echo "$ASSET_SHA  $ASSET" >"$DR_CLI_CHECKSUMS"

  STUB_VERSION_NOISE=1 DR_CLI_VERSION=v9.9.9 run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"stub dr v9.9.9"* ]]
  [[ "$output" != *"99999"* ]]
}

@test "fails when the installed dr cannot run" {
  make_release v9.9.9
  echo "$ASSET_SHA  $ASSET" >"$DR_CLI_CHECKSUMS"
  printf '#!/usr/bin/env bash\nexit 3\n' >"$BATS_TEST_TMPDIR/release-src/dr"
  tar -czf "$BATS_TEST_TMPDIR/releases/v9.9.9/$ASSET" -C "$BATS_TEST_TMPDIR/release-src" dr
  echo "$(sha256_of "$BATS_TEST_TMPDIR/releases/v9.9.9/$ASSET")  $ASSET" >"$DR_CLI_CHECKSUMS"

  DR_CLI_VERSION=v9.9.9 run "$SCRIPT"

  [ "$status" -ne 0 ]
}

@test "adds the install directory to GITHUB_PATH" {
  make_release v9.9.9
  echo "$ASSET_SHA  $ASSET" >"$DR_CLI_CHECKSUMS"

  DR_CLI_VERSION=v9.9.9 run "$SCRIPT"

  [ "$(cat "$GITHUB_PATH")" = "$DR_CLI_INSTALL_DIR" ]
}

@test "takes the checksum from DR_CLI_SHA256 when the version is not in the table" {
  make_release v9.9.9

  DR_CLI_VERSION=v9.9.9 DR_CLI_SHA256="$ASSET_SHA" run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -x "$DR_CLI_INSTALL_DIR/dr" ]
}

@test "picks the arm64 asset on aarch64" {
  make_release v9.9.9 Linux_arm64
  echo "$ASSET_SHA  $ASSET" >"$DR_CLI_CHECKSUMS"

  UNAME_M=aarch64 DR_CLI_VERSION=v9.9.9 run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -x "$DR_CLI_INSTALL_DIR/dr" ]
}

@test "fails and installs nothing when the checksum does not match" {
  make_release v9.9.9
  echo "0000000000000000000000000000000000000000000000000000000000000000  $ASSET" >"$DR_CLI_CHECKSUMS"

  DR_CLI_VERSION=v9.9.9 run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum"* ]]
  [ ! -e "$DR_CLI_INSTALL_DIR/dr" ]
  [ ! -s "$GITHUB_PATH" ]
}

@test "fails and names dr_cli_sha256 when the version has no checksum" {
  make_release v9.9.9

  DR_CLI_VERSION=v9.9.9 run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"dr_cli_sha256"* ]]
  [ ! -e "$DR_CLI_INSTALL_DIR/dr" ]
}

@test "fails when the download fails" {
  DR_CLI_VERSION=v8.8.8 DR_CLI_SHA256=abc run "$SCRIPT"

  [ "$status" -ne 0 ]
  [ ! -e "$DR_CLI_INSTALL_DIR/dr" ]
}

@test "rejects an unsupported architecture" {
  UNAME_M=riscv64 DR_CLI_VERSION=v9.9.9 run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported architecture"* ]]
}

@test "rejects an unsupported operating system" {
  UNAME_S=Windows_NT DR_CLI_VERSION=v9.9.9 run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported operating system"* ]]
}

@test "the shipped checksum table covers the default version on Linux" {
  table="$BATS_TEST_DIRNAME/../scripts/dr-cli-checksums.txt"

  run grep -c -E '^[0-9a-f]{64}  dr_v[0-9.]+_(Linux_x86_64|Linux_arm64|Darwin_arm64|Darwin_x86_64)\.tar\.gz$' "$table"

  [ "$output" -ge 4 ]
}
