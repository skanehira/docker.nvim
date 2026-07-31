#!/usr/bin/env bash
#
# Run the end-to-end scenarios of G_E2E.
#
# Exit codes: 0=every scenario passed / 1=some assertion failed / 2=docker is not available
#
# Creates the containers, images, and compose projects used for the test under a temporary
# directory, then drives the real docker from a headless Neovim to check each stage.
# The cleanup always runs, even when something fails.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

readonly PREFIX="dockernvim-e2e"
readonly IMAGE="${DOCKER_NVIM_E2E_IMAGE:-alpine}"

# 1. Make sure docker is available
if ! command -v docker >/dev/null 2>&1; then
  echo "e2e: docker command not found" >&2
  exit 2
fi
if ! docker version >/dev/null 2>&1; then
  echo "e2e: cannot connect to the docker daemon" >&2
  exit 2
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if ! docker pull "$IMAGE" >/dev/null 2>&1; then
    echo "e2e: cannot pull the test image $IMAGE" >&2
    exit 2
  fi
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/docker-nvim-e2e.XXXXXX")

# 5. Remove the resources used by the test.
# The same cleanup also runs before the setup, in case the previous run ended abnormally
# (leftovers make the setup fail on a name collision, and that failure can even make a
#  scenario pass by accident, in the form of an "already Exited" container).
remove_leftovers() {
  if [ -f "$WORKDIR/compose.yaml" ]; then
    (cd "$WORKDIR" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  fi
  if [ -f "$WORKDIR/proj2/compose.yaml" ]; then
    (cd "$WORKDIR/proj2" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  fi
  for name in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^${PREFIX}" || true); do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  for name in $(docker volume ls --format '{{.Name}}' 2>/dev/null | grep "^${PREFIX}" || true); do
    docker volume rm -f "$name" >/dev/null 2>&1 || true
  done
  for name in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep "^${PREFIX}" || true); do
    docker network rm "$name" >/dev/null 2>&1 || true
  done
}

cleanup() {
  local status=$?
  remove_leftovers
  rm -rf "$WORKDIR"
  exit "$status"
}
trap cleanup EXIT INT TERM

# Start by removing the leftovers of the previous run
remove_leftovers

# 2. Create the compose projects and the standalone containers used by the test.
# The list merges every project, so two projects are prepared to check both that
# "other projects are visible too" and that "an action only affects the project of its row".
cat > "$WORKDIR/compose.yaml" <<EOF
name: ${PREFIX}-proj
services:
  web:
    image: ${IMAGE}
    command: sleep 600
  never-started:
    image: ${IMAGE}
    command: sleep 600
EOF

mkdir -p "$WORKDIR/proj2"
cat > "$WORKDIR/proj2/compose.yaml" <<EOF
name: ${PREFIX}-proj2
services:
  api:
    image: ${IMAGE}
    command: sleep 600
EOF

# Swallowing a setup failure would let the scenarios pass by accident.
setup() {
  docker run -d --name "${PREFIX}-standalone" "$IMAGE" sleep 600 >/dev/null &&
    docker run -d --name "${PREFIX}-doomed" "$IMAGE" sleep 600 >/dev/null &&
    docker volume create "${PREFIX}-vol" >/dev/null &&
    docker network create "${PREFIX}-net" >/dev/null &&
    (cd "$WORKDIR" && docker compose up -d web >/dev/null 2>&1) &&
    (cd "$WORKDIR/proj2" && docker compose up -d api >/dev/null 2>&1)
}
if ! setup; then
  echo "e2e: failed to prepare the test resources" >&2
  exit 2
fi

# 3-4. Run the scenarios through in a headless Neovim
PLENARY_PATH=${PLENARY_PATH:-$HOME/.local/share/nvim/lazy/plenary.nvim}
export PLENARY_PATH
export DOCKER_NVIM_E2E_PREFIX="$PREFIX"
export DOCKER_NVIM_E2E_WORKDIR="$WORKDIR"
export DOCKER_NVIM_E2E_IMAGE="$IMAGE"

# Using `exec` would replace bash, drop the EXIT trap, and skip the cleanup.
cd "$REPO_ROOT" || exit 1
./scripts/run-busted.sh tests/e2e/e2e_spec.lua
