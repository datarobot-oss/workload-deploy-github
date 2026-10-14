#!/usr/bin/env bash
# Run the bats suite. Needs bats-core (https://github.com/bats-core/bats-core).
# Extra arguments go to bats, for example `tests/run.sh --filter resolve_manifest`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec bats --print-output-on-failure "$@" tests
