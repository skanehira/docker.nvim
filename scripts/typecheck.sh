#!/usr/bin/env bash
#
# Type check with lua-language-server.
#
# Resolve the dependency paths at run time before checking. Running without resolving them
# reports "no problems found" even when type errors exist, which silently degrades the gate
# from "can fail" into "always passes".
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

# The luassert types (assert.are.same and friends) are provided by plenary.
# .luarc.json holds the default path for the user's editor, but CI clones it elsewhere, so
# generate a config here with that path replaced by the one that actually exists.
PLENARY_PATH=${PLENARY_PATH:-$HOME/.local/share/nvim/lazy/plenary.nvim}
if [ ! -d "$PLENARY_PATH/lua" ]; then
  echo "typecheck: plenary.nvim not found at: $PLENARY_PATH" >&2
  echo "set PLENARY_PATH to the directory where plenary.nvim is checked out" >&2
  exit 1
fi

# The generated config is JSON, so paths whose value contains " or \ are not supported
# (they do not occur in practice).
case $PLENARY_PATH in
  *'"'*|*'\'*)
    echo "typecheck: PLENARY_PATH must not contain quotes or backslashes: $PLENARY_PATH" >&2
    exit 1
    ;;
esac

# `mktemp -t <name>` is a BSD-only form and fails with "too few X's" on GNU coreutils.
# Spell the template out so it works on both macOS and Linux (CI).
config=$(mktemp "${TMPDIR:-/tmp}/docker-nvim-luarc.XXXXXX")
trap 'rm -f "$config"' EXIT

PLENARY_LUA="$PLENARY_PATH/lua" perl -0777 -pe \
  's{"~/\.local/share/nvim/lazy/plenary\.nvim/lua"}{"$ENV{PLENARY_LUA}"}g' \
  "$REPO_ROOT/.luarc.json" > "$config"

# Confirm the replacement actually took effect (otherwise the luassert types cannot be
# resolved and assert.are.same is reported as undefined-field over and over).
if ! grep -qF "$PLENARY_PATH/lua" "$config"; then
  echo "typecheck: failed to inject plenary path into the generated config" >&2
  exit 1
fi

cd "$REPO_ROOT" || exit 1
exec lua-language-server --check . --checklevel=Warning --configpath="$config"
