#!/usr/bin/env bash
set -eu
# ================================================================== #
#  DataRobot Workload deploy — Code-to-Workload (C2W).               #
#                                                                    #
#  Reads the manifest, builds the repo into a container image        #
#  server-side, and creates (or zero-downtime rolling-replaces) the  #
#  workload. The manifest is the single source of truth.             #
#                                                                    #
#  Ported from the GitLab CI/CD component templates/deploy.yml.      #
# ================================================================== #

# shellcheck source=scripts/common.sh
. "${SCRIPT_DIR:?SCRIPT_DIR must point at the action scripts directory}/common.sh"

# ---------- 0. Preflight + tooling -------------------------------- #
require_credentials
resolve_manifest
install_tooling

# ---------- 1. Parse the manifest --------------------------------- #
NAME="$(yq -r '.name' "$MANIFEST")"
[ -n "$NAME" ] && [ "$NAME" != "null" ] || die "Manifest is missing required field: name"
PORT="$(yq -r '.build.port' "$MANIFEST")"
[ -n "$PORT" ] && [ "$PORT" != "null" ] || die "Manifest is missing required field: build.port (must be >= 1024)"
IMPORTANCE="$(yq -r '.importance // "low"' "$MANIFEST")"
DOCKERFILE="$(yq -r '.build.dockerfile // "./Dockerfile"' "$MANIFEST")"
HEALTH="$(yq -r '.build.health // "/healthz"' "$MANIFEST")"
REPLICAS="$(yq -r '.runtime.replicas // 1' "$MANIFEST")"
CPU="$(yq -r '.runtime.cpu // 0.5' "$MANIFEST")"
MEM="$(yq -r '.runtime.memory // "512MB"' "$MANIFEST")"

# The deploy target's identity. Defaults to the manifest name; override via the
# workload_name input to give each environment/branch its own workload. The
# same name is always rolled in place, so repeat pushes to the same target land
# on the same workload (never a duplicate).
WORKLOAD_NAME="${DR_WORKLOAD_NAME:-$NAME}"
log "Deploying workload '$WORKLOAD_NAME' (importance=$IMPORTANCE, port=$PORT, replicas=$REPLICAS, cpu=$CPU, memory=$MEM)"

# ---------- 2. Render the artifact spec from the manifest --------- #
jq -n --arg name "${WORKLOAD_NAME}-artifact" --argjson port "$PORT" \
      --arg df "$DOCKERFILE" --arg health "$HEALTH" '{
  name: $name, type: "service",
  spec: { containerGroups: [ { name: "default", containers: [ {
    name: "main", imageUri: "placeholder:latest", primary: true, port: $port,
    imageBuildConfig: { dockerfile: { source: "provided", path: $df } },
    readinessProbe: { path: $health, port: $port, initialDelaySeconds: 10,
      periodSeconds: 10, timeoutSeconds: 5, failureThreshold: 6, scheme: "HTTP" },
    livenessProbe: { path: $health, port: $port, initialDelaySeconds: 30,
      periodSeconds: 15, timeoutSeconds: 5, failureThreshold: 3, scheme: "HTTP" }
  } ] } ] }
}' > artifact.spec.json

# ---------- 3. Create artifact, upload source, build image -------- #
log "Creating draft artifact.."
OUT="$(dr artifact create --spec-file artifact.spec.json --output-format json)"
AID="$(echo "$OUT" | jq -r '.id // .artifactId // .data.id // empty')"
[ -n "$AID" ] || { echo "$OUT"; die "Could not parse artifact id."; }
echo "  artifact: $AID"

log "Uploading source (respects .dockerignore / .wapiignore).."
dr artifact code init "$AID" --yes --dir .
dr artifact code sync --yes --dir .

log "Building the container image server-side.."
OUT="$(dr artifact build create "$AID" --output-format json)"
BID="$(echo "$OUT" | jq -r '.buildIds[0] // .id // .data.buildIds[0] // .data[0].id // empty')"
[ -n "$BID" ] || { echo "$OUT"; die "Could not parse build id."; }
echo "  build: $BID"

DEADLINE=$(( $(date +%s) + DR_WAIT_TIMEOUT ))
while :; do
  ST="$(dr artifact build get "$BID" --output-format json | jq -r '.status // .data.status // "unknown"' | tr '[:lower:]' '[:upper:]')"
  case "$ST" in
    COMPLETED) echo "  ✓ build completed"; break ;;
    FAILED)    echo "  build log tail:"; dr artifact build logs "$BID" 2>/dev/null | tail -40 || true; die "Image build FAILED." ;;
    *)         [ "$(date +%s)" -lt "$DEADLINE" ] || die "Timed out waiting for image build."; printf '  status: %s\r' "$ST"; sleep 10 ;;
  esac
done

# ---------- 4. Create the workload, or roll the existing one ------ #
# Find an existing workload with this exact name — that is how the deploy stays
# idempotent without any cached state between runs.
WID="$(dr workload list --output-format json | jq -r --arg n "$WORKLOAD_NAME" '.workloads[]? | select(.name==$n) | .id' | head -1)"
AID_PRELOCKED="false"

if [ -z "$WID" ]; then
  log "No existing workload named '$WORKLOAD_NAME' — creating it.."
  jq -n --arg name "$WORKLOAD_NAME" --arg imp "$IMPORTANCE" --arg aid "$AID" \
        --argjson replicas "$REPLICAS" --argjson cpu "$CPU" --arg mem "$MEM" '{
    name: $name, importance: $imp, artifactId: $aid,
    runtime: { containerGroups: [ { name: "default", replicaCount: $replicas,
      containers: [ { name: "main", resourceAllocation: { cpu: $cpu, memory: $mem } } ] } ] }
  }' > workload.spec.json
  OUT="$(dr workload create --spec-file workload.spec.json --output-format json)"
  WID="$(echo "$OUT" | jq -r '.id // .workloadId // .data.id // empty')"
  [ -n "$WID" ] || { echo "$OUT"; die "Could not parse workload id."; }
  OLD_AID=""
else
  log "Found existing workload '$WORKLOAD_NAME' ($WID) — rolling onto the new image.."
  # dr CLI has no replacement verb yet, so call the REST endpoint directly.
  # Normalize the endpoint to a bare .../api/v2 (the CLI accepts either form).
  API="${DATAROBOT_ENDPOINT%/}"; API="${API%/api/v2}/api/v2"
  OLD_AID="$(dr workload get "$WID" --output-format json | jq -r '.artifactId // .data.artifactId // empty')"

  # The replacement endpoint rejects the request (422, "Artifact status
  # mismatch") unless the new artifact's lock status matches the current one's.
  # A workload's artifact is locked as soon as it has ever gone healthy, so
  # every redeploy after the first must lock the new artifact *before* swapping
  # it in — we can no longer wait for a confirmed-healthy rollout first. This
  # forfeits the auto-prune safety net (see step 6) for that redeploy: if it
  # never becomes healthy, the new artifact is already locked and can't be
  # deleted.
  if [ -n "$OLD_AID" ]; then
    OLD_STATUS="$(dr artifact get "$OLD_AID" --output-format json | jq -r '.status // .data.status // empty' | tr '[:upper:]' '[:lower:]')"
    if [ "$OLD_STATUS" = "locked" ]; then
      log "Locking artifact $AID to match the current (locked) artifact before replacing.."
      dr artifact lock "$AID" >/dev/null || die "Could not lock artifact $AID before replacement."
      AID_PRELOCKED="true"
      echo "  ✓ artifact locked"
    fi
  fi
  BODY="$(jq -n --arg aid "$AID" --argjson replicas "$REPLICAS" --argjson cpu "$CPU" --arg mem "$MEM" '{
    artifactId: $aid, strategy: "rolling",
    runtime: { containerGroups: [ { name: "default", replicaCount: $replicas,
      containers: [ { name: "main", resourceAllocation: { cpu: $cpu, memory: $mem } } ] } ] }
  }')"
  CODE="$(curl -sS -o /tmp/repl.out -w '%{http_code}' -X POST "$API/workloads/$WID/replacement/" \
    -H "Authorization: Bearer $DATAROBOT_API_TOKEN" -H "Content-Type: application/json" -d "$BODY")"
  case "$CODE" in
    200|201|202) : ;;
    *) cat /tmp/repl.out; die "Replacement request failed (HTTP $CODE)." ;;
  esac
  # Wait for the rolling swap to finish: the endpoint returns 404 when none is active.
  DEADLINE=$(( $(date +%s) + DR_WAIT_TIMEOUT ))
  sleep 5
  while :; do
    CODE="$(curl -sS -o /tmp/repl.out -w '%{http_code}' "$API/workloads/$WID/replacement/" \
      -H "Authorization: Bearer $DATAROBOT_API_TOKEN")"
    [ "$CODE" = "404" ] && { echo "  ✓ rolling replacement complete"; break; }
    RST="$(jq -r '.status // .data.status // "in-progress"' /tmp/repl.out 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    case "$RST" in
      *fail*|*error*) cat /tmp/repl.out; die "Rolling replacement failed." ;;
    esac
    [ "$(date +%s)" -lt "$DEADLINE" ] || die "Timed out waiting for rolling replacement."
    printf '  replacement: %s\r' "$RST"; sleep 10
  done
fi
echo "  workload: $WID"

# ---------- 5. Wait until the workload is healthy ----------------- #
log "Waiting for workload '$WORKLOAD_NAME' to become running.."
DEADLINE=$(( $(date +%s) + DR_WAIT_TIMEOUT ))
while :; do
  ST="$(dr workload get "$WID" --output-format json | jq -r '.status // .data.status // "unknown"' | tr '[:upper:]' '[:lower:]')"
  case "$ST" in
    running)           echo "  ✓ workload running"; break ;;
    failed|terminated) die "Workload is $ST. Check: dr workload logs $WID" ;;
    *)                 [ "$(date +%s)" -lt "$DEADLINE" ] || die "Timed out waiting for workload."; printf '  status: %s\r' "$ST"; sleep 10 ;;
  esac
done

# ---------- 6. Lock the artifact now the workload is healthy ------ #
# A draft artifact is impermanent — the platform reclaims drafts, which stops
# the workload. Locking promotes it to an immutable, versioned artifact that
# keeps running. Locking is one-way, so on a first deploy (or a redeploy onto a
# still-draft predecessor) we only do it after a confirmed-healthy rollout.
# Redeploys onto an already-locked predecessor were locked earlier (step 4).
if [ "$AID_PRELOCKED" != "true" ]; then
  log "Locking artifact $AID (draft artifacts don't keep running).."
  dr artifact lock "$AID" >/dev/null || die "Workload is healthy but locking artifact $AID failed; it may be reclaimed. Check: dr artifact get $AID"
  echo "  ✓ artifact locked"
fi

# ---------- 7. Resolve URLs and export them ----------------------- #
# The live endpoint (where the workload serves traffic).
ENDPOINT="$(dr workload get "$WID" --output-format json | jq -r '.endpoint // .data.endpoint // empty')"
[ -n "$ENDPOINT" ] && [ "$ENDPOINT" != "null" ] || ENDPOINT="$(dr workload endpoint "$WID" 2>/dev/null || true)"
# The DataRobot console (management UI) for this workload. Derive the app host
# from the endpoint you were given (strip any /api/v2 suffix).
APP_HOST="${DATAROBOT_ENDPOINT%/}"; APP_HOST="${APP_HOST%/api/v2}"
CONSOLE_URL="$APP_HOST/console-nextgen/workloads/$WID/overview"

# Expose the values as GitHub Actions step outputs so later steps/jobs can
# consume them (smoke tests, notifications, promotion gates, environment URL).
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "workload_id=$WID"
    echo "workload_name=$WORKLOAD_NAME"
    echo "endpoint=$ENDPOINT"
    echo "console_url=$CONSOLE_URL"
    echo "artifact_id=$AID"
  } >> "$GITHUB_OUTPUT"
fi

# ---------- 8. Print a prominent summary -------------------------- #
printf '\n\033[32m'
printf '╔══════════════════════════════════════════════════════════════════════╗\n'
printf '║  ✓ Deployed  %-57s ║\n' "$WORKLOAD_NAME"
printf '╚══════════════════════════════════════════════════════════════════════╝\n'
printf '\033[0m'
printf '  \033[1mEndpoint (live app):\033[0m  %s\n' "${ENDPOINT:-<unavailable>}"
printf '  \033[1mManage in DataRobot:\033[0m  %s\n' "$CONSOLE_URL"
printf '  \033[1mWorkload id:\033[0m          %s\n\n' "$WID"

# Rich summary on the GitHub Actions run page (the GitHub analog of GitLab's
# job-log banner + "View deployment" button).
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## ✓ Deployed \`$WORKLOAD_NAME\`"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| **Endpoint (live app)** | ${ENDPOINT:-<unavailable>} |"
    echo "| **Manage in DataRobot** | [$CONSOLE_URL]($CONSOLE_URL) |"
    echo "| **Workload id** | \`$WID\` |"
    echo "| **Artifact id** | \`$AID\` |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# ---------- 9. Best-effort cleanup -------------------------------- #
# The predecessor is normally locked now (every healthy deploy locks its
# artifact), so this is a no-op for it — locked artifacts can't be deleted. It
# still cleans up an unlocked draft left by a predecessor from before locking,
# or from a deploy that never reached healthy.
if [ "$DR_PRUNE_OLD_ARTIFACT" = "true" ] && [ -n "${OLD_AID:-}" ] && [ "$OLD_AID" != "$AID" ]; then
  log "Pruning previous draft artifact $OLD_AID (best-effort).."
  dr artifact delete "$OLD_AID" --yes >/dev/null 2>&1 || echo "  (skipped — locked or already removed)"
fi
