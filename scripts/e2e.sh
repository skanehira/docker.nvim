#!/usr/bin/env bash
#
# G_E2E の通しシナリオを実行する。
#
# 終了コード: 0=全シナリオ成功 / 1=いずれかの assert 失敗 / 2=docker が利用できない
#
# 検証用のコンテナ・イメージ・compose プロジェクトを一時ディレクトリに作り、
# headless の Neovim から実際の docker に対して操作して各段階を確かめる。
# 後始末は失敗しても必ず実行する。
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

readonly PREFIX="dockernvim-e2e"
readonly IMAGE="${DOCKER_NVIM_E2E_IMAGE:-alpine}"

# 1. docker が利用できることを確認する
if ! command -v docker >/dev/null 2>&1; then
  echo "e2e: docker コマンドが見つかりません" >&2
  exit 2
fi
if ! docker version >/dev/null 2>&1; then
  echo "e2e: docker デーモンへ接続できません" >&2
  exit 2
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if ! docker pull "$IMAGE" >/dev/null 2>&1; then
    echo "e2e: 検証用イメージ $IMAGE を取得できません" >&2
    exit 2
  fi
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/docker-nvim-e2e.XXXXXX")

# 5. 検証用のリソースを片付ける。
# 前回の実行が異常終了した場合に備え、セットアップ前にも同じ掃除を行う
# (残骸があると名前の衝突でセットアップが失敗し、しかもその失敗が
#  「既に Exited」という形でシナリオを偶然通してしまう)。
remove_leftovers() {
  if [ -f "$WORKDIR/compose.yaml" ]; then
    (cd "$WORKDIR" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
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

# 前回の残骸を掃除してから始める
remove_leftovers

# 2. 検証用の compose プロジェクトとスタンドアロンコンテナを作る
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

# セットアップの失敗を握り潰すと、シナリオが偶然通ってしまう。
setup() {
  docker run -d --name "${PREFIX}-standalone" "$IMAGE" sleep 600 >/dev/null &&
    docker run -d --name "${PREFIX}-doomed" "$IMAGE" sleep 600 >/dev/null &&
    docker volume create "${PREFIX}-vol" >/dev/null &&
    docker network create "${PREFIX}-net" >/dev/null &&
    (cd "$WORKDIR" && docker compose up -d web >/dev/null 2>&1)
}
if ! setup; then
  echo "e2e: 検証用リソースの用意に失敗しました" >&2
  exit 2
fi

# 3-4. headless の Neovim で通し実行する
PLENARY_PATH=${PLENARY_PATH:-$HOME/.local/share/nvim/lazy/plenary.nvim}
export PLENARY_PATH
export DOCKER_NVIM_E2E_PREFIX="$PREFIX"
export DOCKER_NVIM_E2E_WORKDIR="$WORKDIR"
export DOCKER_NVIM_E2E_IMAGE="$IMAGE"

# `exec` にすると bash が置き換わり EXIT trap が消えて後始末が走らない。
cd "$REPO_ROOT" || exit 1
./scripts/run-busted.sh tests/e2e/e2e_spec.lua
