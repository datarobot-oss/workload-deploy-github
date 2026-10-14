#!/usr/bin/env bash
# Install a pinned release of the DataRobot CLI and check its SHA-256.
#
# The expected checksum comes from DR_CLI_SHA256, or else from the table in
# dr-cli-checksums.txt. A version in neither fails the install, so the action
# never runs a binary it has not verified.
#
# Environment:
#   DR_CLI_VERSION        Release tag, for example v0.14.1. Required.
#   DR_CLI_SHA256         Checksum of the archive. Overrides the table.
#   DR_CLI_DOWNLOAD_BASE  Where releases are served, as <base>/<version>/<asset>.
#                         Defaults to the GitHub releases of datarobot-oss/cli.
#                         Point it at a mirror inside a restricted network.
#   DR_CLI_INSTALL_DIR    Where `dr` goes. Defaults to $RUNNER_TEMP/dr-cli.
#   DR_CLI_CHECKSUMS      The checksum table. Defaults to the one next to this script.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/common.sh
. "$script_dir/common.sh"

version="${DR_CLI_VERSION:?DR_CLI_VERSION is not set}"
base="${DR_CLI_DOWNLOAD_BASE:-https://github.com/datarobot-oss/cli/releases/download}"
install_dir="${DR_CLI_INSTALL_DIR:-${RUNNER_TEMP:-/tmp}/dr-cli}"
checksums="${DR_CLI_CHECKSUMS:-$script_dir/dr-cli-checksums.txt}"

case "$(uname -s)" in
Linux) os=Linux ;;
Darwin) os=Darwin ;;
*) die "Unsupported operating system: $(uname -s)." ;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch=x86_64 ;;
aarch64 | arm64) arch=arm64 ;;
*) die "Unsupported architecture: $(uname -m)." ;;
esac
asset="dr_${version}_${os}_${arch}.tar.gz"

expected="${DR_CLI_SHA256:-}"
if [ -z "$expected" ]; then
  expected=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$checksums")
fi
[ -n "$expected" ] || die "No checksum for $asset. Use a version listed in dr-cli-checksums.txt, or pass its SHA-256 as dr_cli_sha256."

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

log "Downloading the DataRobot CLI $version ($os $arch)"
curl -fsSL -o "$workdir/$asset" "$base/$version/$asset"

if have sha256sum; then
  actual=$(sha256sum "$workdir/$asset" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$workdir/$asset" | cut -d' ' -f1)
fi
[ "$actual" = "$expected" ] || die "The checksum of $asset does not match. Expected $expected, got $actual."

mkdir -p "$install_dir"
tar -xzf "$workdir/$asset" -C "$install_dir" dr
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$install_dir" >>"$GITHUB_PATH"
fi

# Capture the output first. Piping into `head` can fail the step with SIGPIPE
# under pipefail when the CLI prints more than one line.
version_output=$("$install_dir/dr" --version)
printf '%s\n' "${version_output%%$'\n'*}"
