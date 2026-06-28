#!/usr/bin/env bash
# Smoke test for spawn.sh's build_inner_launch (Headroom integration). Verifies
# the inner-launch command string in all three states with NO tmux/worktree side
# effects, by driving spawn.sh's `--print-inner-launch` self-test hook under a
# hermetic PATH whose only non-coreutil entry is a stub `headroom` we control.
# Mirrors scripts/agy-smoke-test.sh's note()/check()/exit "$fail" convention.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SPAWN="$HERE/../.claude/skills/committee-loop/spawn.sh"
ARGS="--dangerously-skip-permissions --effort high"
fail=0
note()  { printf '%s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then note "PASS: $3"; else note "FAIL: $3"; note "  got:  $1"; note "  want: $2"; fail=1; fi; }

[ -f "$SPAWN" ] || { note "FAIL: $SPAWN not found"; exit 1; }
grep -q 'build_inner_launch' "$SPAWN" \
  || { note "FAIL: build_inner_launch not present in spawn.sh (expected RED before implementation)"; exit 1; }

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT INT TERM
# Hermetic PATH: coreutils for spawn.sh's dirname/pwd, plus our controllable stub dir.
BASEPATH="$STUB:/usr/bin:/bin"

# Case 1: headroom installed -> wrapped
printf '#!/bin/sh\nexit 0\n' > "$STUB/headroom"; chmod +x "$STUB/headroom"
got=$(PATH="$BASEPATH" bash "$SPAWN" --print-inner-launch "$ARGS")
check "$got" "headroom wrap claude -- $ARGS" "headroom installed -> wrapped launch"

# Case 2: opt-out via COMMITTEE_HEADROOM=OFF (case-insensitive) -> bare claude
got=$(PATH="$BASEPATH" COMMITTEE_HEADROOM=OFF bash "$SPAWN" --print-inner-launch "$ARGS")
check "$got" "claude $ARGS" "COMMITTEE_HEADROOM=OFF -> bare claude (case-insensitive, headroom present)"

# Case 3: headroom NOT installed -> bare claude.
# Hermeticity guard: if a system headroom is still reachable WITHOUT the stub
# (e.g. installed in /usr/bin), this case can't run hermetically — skip it with a
# NOTE instead of emitting a false FAIL (codex/gemini committee finding).
rm -f "$STUB/headroom"
if PATH="$BASEPATH" command -v headroom >/dev/null 2>&1; then
  note "SKIP: headroom reachable via system PATH without the stub — Case 3 not hermetic here"
else
  got=$(PATH="$BASEPATH" bash "$SPAWN" --print-inner-launch "$ARGS")
  check "$got" "claude $ARGS" "headroom absent -> bare claude"
fi

[ "$fail" = 0 ] && note "ALL SMOKE CHECKS PASSED" || note "SMOKE CHECKS FAILED"
exit "$fail"
