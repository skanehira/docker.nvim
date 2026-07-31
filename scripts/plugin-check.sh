#!/usr/bin/env bash
#
# plugin/*.lua is always sourced by the user's Neovim at startup, but it is never required
# from the tests, so a load error is caught by neither the tests, the lint, nor the type
# check. To prevent "broken in the user's environment while CI is all green", start nvim
# for real and check.
#
# The verdict is that stderr is empty. v:errmsg would miss the errors raised inside
# vim.schedule / vim.defer_fn / a VimEnter autocmd (they reach stderr while v:errmsg stays
# empty).
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

MINIMAL_INIT=${MINIMAL_INIT:-$REPO_ROOT/tests/minimal_init.lua}
if [ ! -f "$MINIMAL_INIT" ]; then
  echo "plugin-check: minimal init not found: $MINIMAL_INIT" >&2
  exit 1
fi

cd "$REPO_ROOT" || exit 1

# Spin the event loop for a moment before quitting, so the errors from deferred execution
# (vim.schedule / defer_fn / VimEnter) are picked up too.
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
