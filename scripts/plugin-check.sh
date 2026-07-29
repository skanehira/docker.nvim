#!/usr/bin/env bash
#
# plugin/*.lua は利用者の Neovim が起動時に必ず source するが、テストからは
# require されないため、読み込みエラーがテストにも lint にも型検査にも掛からない。
# 「利用者環境では壊れているのに CI は全 green」を防ぐため、実際に起動して確認する。
#
# 判定は stderr が空であること。v:errmsg では vim.schedule / vim.defer_fn /
# VimEnter autocmd の中で起きたエラーを取りこぼす (stderr には出るが v:errmsg は空のまま)。
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

MINIMAL_INIT=${MINIMAL_INIT:-$REPO_ROOT/tests/minimal_init.lua}
if [ ! -f "$MINIMAL_INIT" ]; then
  echo "plugin-check: minimal init not found: $MINIMAL_INIT" >&2
  exit 1
fi

cd "$REPO_ROOT" || exit 1

# 遅延実行 (vim.schedule / defer_fn / VimEnter) のエラーも拾えるよう、
# 終了前に少しだけイベントループを回す。
err=$(nvim --headless -u "$MINIMAL_INIT" -c 'sleep 300m' -c 'qa!' 2>&1 >/dev/null)
status=$?

if [ -n "$err" ]; then
  echo "plugin-check: loading plugin/*.lua produced errors:" >&2
  printf '%s\n' "$err" >&2
  exit 1
fi

if [ "$status" -ne 0 ]; then
  echo "plugin-check: nvim exited with status $status" >&2
  exit "$status"
fi

exit 0
