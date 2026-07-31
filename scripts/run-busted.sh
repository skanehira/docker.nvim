#!/usr/bin/env bash
#
# Start plenary's busted harness and verify that the tests actually ran.
#
# Trusting the exit code alone would make all of the following look like a "success":
#   - the spec file exists but defines no it(...)
#   - the tests are pending (plenary counts pending toward the Success count as well, so
#     the output after a run cannot tell an all-pending run apart from a successful one)
#   - the scanned target contains no spec file at all (deleted, renamed, or moved elsewhere)
# Every goal verification step (DESIGN_DETAIL_APP.md chapter 9) depends on this exit code,
# so failing to tell "nothing ran" apart from a success makes the acceptance checks hollow.
#
# What this script does NOT guarantee (stated explicitly to avoid misunderstanding):
#   - it cannot judge whether a spec really verifies the implementation it covers.
#     A spec containing only `assert.are.same(1, 1)` passes as well. That is the
#     responsibility of review-tdd and review-adversarial, and a shell exit code
#     is no substitute for it
#   - code written to fool the harness, such as calling os.exit from inside a spec, is
#     only blocked as far as the static checks reach (check_spec_sanity below)
#   - the deletion of only some of the specs cannot be detected (the spec count and the
#     summary count decrease together)
#
# Usage: run-busted.sh <directory | *_spec.lua>
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

TARGET=${1:?usage: run-busted.sh <dir-or-spec-file>}
MINIMAL_INIT=${MINIMAL_INIT:-$REPO_ROOT/tests/minimal_init.lua}

# When minimal_init cannot be read, nvim starts while ignoring -u, PlenaryBusted* stays an
# undefined command, and the headless nvim never exits (no response = CI cannot detect it).
# The guard inside minimal_init only works once it is loaded, so check it here first.
if [ ! -f "$MINIMAL_INIT" ]; then
  echo "run-busted: minimal init not found: $MINIMAL_INIT" >&2
  exit 1
fi

if [ ! -e "$TARGET" ]; then
  echo "run-busted: target not found: $TARGET" >&2
  exit 1
fi

for tool in nvim perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "run-busted: required tool not found: $tool" >&2; exit 1; }
done

# The spec files contained in the target. plenary prints one summary block per spec file,
# so this count is the expected value.
if [ -d "$TARGET" ]; then
  specs=$(find "$TARGET" -type f -name '*_spec.lua' | sort)
else
  specs=$TARGET
fi
spec_count=$(printf '%s' "$specs" | grep -c . || true)

# Finding no spec under the scanned target means the tests were deleted, renamed, or moved
# into a directory outside the scan. Failing to tell that apart from green would hide a
# regression, so fail instead.
if [ "$spec_count" -eq 0 ]; then
  echo "run-busted: no *_spec.lua found under $TARGET" >&2
  exit 1
fi

# Static checks before the run. Confirm the assumptions on the spec side before trusting
# the output of the harness.
for spec in $specs; do
  if ! grep -qE '(^|[^[:alnum:]_])it[[:space:]]*\(' "$spec"; then
    echo "run-busted: $spec defines no test (no it(...) found)" >&2
    exit 1
  fi
  # When a spec ends the process itself, the child process disappears before plenary prints
  # the real summary, leaving only a fake one. A test has no reason to call os.exit.
  if grep -qE '(^|[^[:alnum:]_.])os\.exit[[:space:]]*\(' "$spec"; then
    echo "run-busted: $spec calls os.exit, which prevents the harness from reporting real results" >&2
    exit 1
  fi
  # plenary counts pending toward both the Pending lines and the Success count, so even an
  # all-pending spec reaches Success >= 1 and slips past the checks made after the run. On
  # top of that, rules/core/tdd.md forbids "skipping a test with the intent of adding it
  # later", so reject it statically before the run.
  if grep -qE '(^|[^[:alnum:]_.])pending[[:space:]]*\(' "$spec"; then
    echo "run-busted: $spec uses pending(); skipped tests are not allowed (see rules/core/tdd.md)" >&2
    exit 1
  fi
done

out=$(nvim --headless -u "$MINIMAL_INIT" \
  -c "PlenaryBustedDirectory $TARGET {minimal_init = '$MINIMAL_INIT', sequential = true}" 2>&1)
status=$?
printf '%s\n' "$out"

[ "$status" -eq 0 ] || exit "$status"

plain=$(printf '%s' "$out" | perl -pe 's/\e\[[0-9;]*m//g')
# plenary prints its summary with `print("Success: ", n)`, and Lua's print inserts a tab
# between the arguments. Using that tab as the marker keeps a string such as `Success: 3`
# printed by a test body from being miscounted as a summary.
summary_count=$(printf '%s\n' "$plain" | perl -ne '$n++ if /^Success:[ ]*\t\d+/; END { print $n + 0 }')

# When the number of summary lines does not match the number of spec files, either a file
# was missed by the scan or a test body printed a fake summary line. Neither may be treated
# as a success.
if [ "$summary_count" -ne "$spec_count" ]; then
  echo "run-busted: expected $spec_count summary block(s) for $spec_count spec file(s), got $summary_count" >&2
  exit 1
fi

# Fail as soon as one spec passed no test at all. Looking at the total instead would hide
# an empty spec behind the passing count of another spec.
if printf '%s\n' "$plain" | perl -ne 'exit 1 if /^Success:[ ]*\t0(\D|$)/' ; then
  :
else
  echo "run-busted: a spec file ran zero passing tests; every spec must run at least one test" >&2
  exit 1
fi

exit 0
