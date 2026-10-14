#!/usr/bin/env bash
# ================================================================== #
#  Shared helpers for the DataRobot Workload deploy / stop actions.  #
#                                                                    #
#  Sourced by deploy.sh and stop.sh. Provides logging, credential    #
#  preflight, manifest resolution, and tooling (curl/jq/yq/git/dr)   #
#  installation — the pieces both scripts need before they diverge.  #
# ================================================================== #

# Pretty, unambiguous log lines. `die` prints to stderr and exits 1 so a
# GitHub Actions step fails loudly with a readable reason.
log() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die() {
  printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- Preflight: required credentials ----------------------- #
# The DataRobot CLI reads DATAROBOT_ENDPOINT and DATAROBOT_API_TOKEN from the
# environment. The action wires them in from inputs/secrets, but check here so
# the failure message is about credentials, not a downstream CLI error.
require_credentials() {
  [ -n "${DATAROBOT_ENDPOINT:-}" ] || die "DATAROBOT_ENDPOINT is not set. Pass it via the action's 'datarobot_endpoint' input or a DATAROBOT_ENDPOINT env var."
  [ -n "${DATAROBOT_API_TOKEN:-}" ] || die "DATAROBOT_API_TOKEN is not set. Pass it via the action's 'datarobot_api_token' input (from a repository secret) or a DATAROBOT_API_TOKEN env var."
}

# ---------- Resolve the manifest ---------------------------------- #
# Honour an explicit path (DR_MANIFEST), else auto-detect the two supported
# locations in order. Sets the global MANIFEST.
resolve_manifest() {
  MANIFEST="${DR_MANIFEST:-}"
  if [ -z "$MANIFEST" ]; then
    if [ -f .datarobot.yaml ]; then
      MANIFEST=.datarobot.yaml
    elif [ -f .datarobot/workload.yaml ]; then
      MANIFEST=.datarobot/workload.yaml
    else
      die "No manifest found. Add a .datarobot.yaml (or .datarobot/workload.yaml) to the repo root, or set the 'manifest' input."
    fi
  fi
  [ -f "$MANIFEST" ] || die "Manifest '$MANIFEST' not found."
  log "Using manifest: $MANIFEST"
}

# ---------- Install tooling (curl, jq, yq, git, dr) --------------- #
# GitHub-hosted ubuntu runners ship curl/jq/git/yq already, but self-hosted
# runners and container jobs may not — so install what's missing, supporting
# both apk (Alpine containers) and apt-get (Ubuntu).
install_tooling() {
  if ! have curl || ! have jq || ! have yq || ! have git; then
    log "Installing prerequisites (curl, jq, yq, git).."
    if have apk; then
      apk add --no-cache curl jq yq git ca-certificates >/dev/null
    elif have apt-get; then
      $SUDO apt-get update -qq && $SUDO apt-get install -y -qq curl jq git ca-certificates >/dev/null
      have yq || { curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o "$BIN_DIR/yq" && chmod +x "$BIN_DIR/yq"; }
    else
      die "Unsupported runner: need apk or apt-get, or use a runner/image with curl, jq, yq and git preinstalled."
    fi
  fi

  if ! have dr; then
    log "Installing the DataRobot CLI (${DR_CLI_VERSION:-latest}).."
    curl -fsSL https://cli.datarobot.com/install | INSTALL_DIR="$BIN_DIR" sh -s -- "${DR_CLI_VERSION:-latest}" >/dev/null
  fi
  export PATH="$BIN_DIR:$HOME/.local/bin:$PATH"
  have dr || die "DataRobot CLI installation failed."
  dr --version | head -1
}

# Use sudo for apt only when we are not already root (GitHub-hosted runners run
# steps as a passwordless-sudo user; containers usually run as root). Install
# binaries somewhere already on PATH and writable.
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi
if [ -w /usr/local/bin ] || [ "$(id -u)" = "0" ]; then
  BIN_DIR="/usr/local/bin"
else
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
fi
