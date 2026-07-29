#!/usr/bin/env bash
#
# lua-language-server による型検査。
#
# 依存パスを実行時に解決してから検査する。解決できないまま実行すると、
# 型エラーがあっても "no problems found" で素通りしてしまい、
# ゲートが「失敗」ではなく「常時合格」へ静かに劣化する。
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

command -v lua-language-server >/dev/null 2>&1 \
  || { echo "typecheck: lua-language-server not found" >&2; exit 1; }

VIMRUNTIME=$(nvim --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c 'qa!' 2>/dev/null)
if [ -z "$VIMRUNTIME" ]; then
  echo "typecheck: could not resolve VIMRUNTIME (is nvim on PATH?)" >&2
  exit 1
fi
export VIMRUNTIME

# luassert の型 (assert.are.same など) は plenary が提供する。
# .luarc.json には利用者のエディタ向けに既定パスを書いてあるが、CI では
# clone 先が異なるため、ここで実際に存在するパスへ差し替えた設定を生成する。
PLENARY_PATH=${PLENARY_PATH:-$HOME/.local/share/nvim/lazy/plenary.nvim}
if [ ! -d "$PLENARY_PATH/lua" ]; then
  echo "typecheck: plenary.nvim not found at: $PLENARY_PATH" >&2
  echo "set PLENARY_PATH to the directory where plenary.nvim is checked out" >&2
  exit 1
fi

# 生成する設定は JSON なので、値に " や \ を含むパスは扱わない (現実には無い)。
case $PLENARY_PATH in
  *'"'*|*'\'*)
    echo "typecheck: PLENARY_PATH must not contain quotes or backslashes: $PLENARY_PATH" >&2
    exit 1
    ;;
esac

# `mktemp -t <name>` は BSD 専用形式で、GNU coreutils では "too few X's" で失敗する。
# テンプレートを明示して macOS と Linux (CI) の双方で動くようにする。
config=$(mktemp "${TMPDIR:-/tmp}/docker-nvim-luarc.XXXXXX")
trap 'rm -f "$config"' EXIT

PLENARY_LUA="$PLENARY_PATH/lua" perl -0777 -pe \
  's{"~/\.local/share/nvim/lazy/plenary\.nvim/lua"}{"$ENV{PLENARY_LUA}"}g' \
  "$REPO_ROOT/.luarc.json" > "$config"

# 差し替えが実際に効いたことを確認する (効いていないと luassert の型が解決できず、
# assert.are.same が undefined-field として大量に誤検出される)。
if ! grep -qF "$PLENARY_PATH/lua" "$config"; then
  echo "typecheck: failed to inject plenary path into the generated config" >&2
  exit 1
fi

cd "$REPO_ROOT" || exit 1
exec lua-language-server --check . --checklevel=Warning --configpath="$config"
