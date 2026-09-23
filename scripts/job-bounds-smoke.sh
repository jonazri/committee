#!/usr/bin/env bash
# Isolated integration smoke for committee-loop admission control + per-job
# cgroup bounds, driving the real spawn.sh end to end:
#   - a throwaway git repo, HOME and tmux socket (never the user's servers);
#   - a stub `claude` (renders the ready footer; allocates past MemoryMax only
#     when the test drops a trigger file in its worktree);
#   - real `systemd-run --user --scope` units with tiny caps.
# Asserts: cap N rejects job N+1 (rc 75, explanatory message, no worktree);
# each job runs in `committee-job-<job id>.scope`; the job that exceeds
# MemoryMax is OOM-killed alone while its sibling survives; the watcher reports
# TMUX_DIED with the worktree preserved; the freed slot admits a re-spawn.
# Requires Linux with a systemd user session, tmux, git, python3.
# Mirrors scripts/headroom-launch-smoke.sh's note()/check()/exit "$fail" convention.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SPAWN="$HERE/../.claude/skills/committee-loop/spawn.sh"
fail=0
note()  { printf '%s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then note "PASS: $3"; else note "FAIL: $3"; note "  got:  $1"; note "  want: $2"; fail=1; fi; }

for t in systemd-run systemctl journalctl tmux git python3; do
  command -v "$t" >/dev/null 2>&1 || { note "SKIP: $t not available"; exit 0; }
done
systemd-run --user --scope --quiet --collect -p MemoryMax=256M -- true >/dev/null 2>&1 \
  || { note "SKIP: systemd-run --user --scope unusable here"; exit 0; }

TMP=$(mktemp -d)
SOCK="committee-smoke-$$"
REAL_PATH="$PATH"
cleanup() {
  command tmux -L "$SOCK" kill-server 2>/dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"
  rm -rf "${XDG_RUNTIME_DIR:?}/committee-loop-admission/$SOCK"
  for wt in "$TMP"/origin-committee-loop-*; do
    [ -d "$wt" ] && git -C "$TMP/origin" worktree remove --force "$wt" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# --- hermetic HOME, stub CLIs, throwaway origin repo ---
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/plugins/ralph-loop" "$HOME/.claude/skills/committee" \
  "$HOME/.claude/plugins/superpowers/skills/receiving-code-review" "$TMP/bin"
for t in kiro-cli codex agy; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"; chmod +x "$TMP/bin/$t"; done
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = --help ] && { echo "  --effort <level>"; exit 0; }
( while [ ! -f .go-hog ]; do sleep 0.5; done
  exec python3 -c 'import time; b = bytearray(512 * 1024 * 1024); time.sleep(120)' ) &
printf 'bypass permissions on\n'
while IFS= read -r line || sleep 1; do
  printf '\033[2J\033[H'
  [ -n "$line" ] && printf '[Pasted text #1]\n'
  printf 'bypass permissions on\n'
done
STUB
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$REAL_PATH"
export COMMITTEE_HEADROOM=off COMMITTEE_LOOP_SOCKET="$SOCK" COMMITTEE_MAX_JOBS=2 \
  COMMITTEE_JOB_MEMORY_MAX=128M COMMITTEE_JOB_MEMORY_SWAP_MAX=0 \
  COMMITTEE_JOB_CPU_QUOTA=50% COMMITTEE_JOB_TASKS_MAX=256

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN"
git -C "$ORIGIN" config user.name smoke; git -C "$ORIGIN" config user.email smoke@example.invalid
echo base > "$ORIGIN/README.md"; git -C "$ORIGIN" add README.md; git -C "$ORIGIN" commit -qm base
for f in sibling hog third respawn; do echo "# $f" > "$ORIGIN/$f.md"; done

spawn() {  # spawn <target> <manifest-out> ; returns spawn.sh's rc, stderr to <manifest-out>.err
  (cd "$ORIGIN" && bash "$SPAWN" "$1") > "$2" 2> "$2.err"
}
mval() { grep "^$2=" "$1" | head -1 | cut -d= -f2-; }
since=$(date '+%Y-%m-%d %H:%M:%S')

# --- AC2: cap N=2 admits two jobs, rejects the third deterministically ---
spawn sibling.md "$TMP/a.manifest"; check "$?" 0 "job A (sibling) admitted and spawned"
spawn hog.md "$TMP/b.manifest"; check "$?" 0 "job B (hog) admitted and spawned"
A_UNIT=$(mval "$TMP/a.manifest" JOB_UNIT); B_UNIT=$(mval "$TMP/b.manifest" JOB_UNIT)
A_SESSION=$(mval "$TMP/a.manifest" SESSION); B_SESSION=$(mval "$TMP/b.manifest" SESSION)
B_WT=$(mval "$TMP/b.manifest" WORKTREE_PATH); B_WATCHER=$(mval "$TMP/b.manifest" WATCHER_SCRIPT)
note "job A: session=$A_SESSION unit=$A_UNIT"
note "job B: session=$B_SESSION unit=$B_UNIT"
wts_before=$(git -C "$ORIGIN" worktree list | wc -l)
spawn third.md "$TMP/c.manifest"; rc=$?
check "$rc" 75 "job C rejected at cap 2 with rc 75"
note "job C stderr: $(cat "$TMP/c.manifest.err")"
grep -q 'admission rejected — 2/2 committee jobs already running' "$TMP/c.manifest.err"; check "$?" 0 "rejection message says why"
check "$(git -C "$ORIGIN" worktree list | wc -l)" "$wts_before" "rejected job created no worktree"
spawn third.md "$TMP/c2.manifest"; check "$?" 75 "rejection is deterministic on retry"

# --- AC4: per-job attribution ---
check "$A_UNIT" "committee-job-${A_SESSION#committee-loop-}.scope" "job A unit name carries its job id"
check "$B_UNIT" "committee-job-${B_SESSION#committee-loop-}.scope" "job B unit name carries its job id"
systemctl --user is-active --quiet "$A_UNIT"; check "$?" 0 "job A scope active"
systemctl --user is-active --quiet "$B_UNIT"; check "$?" 0 "job B scope active"
check "$(systemctl --user show "$B_UNIT" -p MemoryMax --value)" "134217728" "job B MemoryMax applied (128M)"
check "$(systemctl --user show "$B_UNIT" -p CPUQuotaPerSecUSec --value)" "500ms" "job B CPUQuota applied (50%)"
check "$(systemctl --user show "$B_UNIT" -p TasksMax --value)/$(systemctl --user show "$B_UNIT" -p OOMPolicy --value)" "256/kill" "job B TasksMax + OOMPolicy applied"
note "--- systemctl --user status $A_UNIT $B_UNIT ---"
systemctl --user status "$A_UNIT" "$B_UNIT" --no-pager --lines=0 2>&1 | sed 's/^/  /'

# --- AC3: B exceeds MemoryMax -> OOM-killed alone; A survives ---
bash "$B_WATCHER" > "$TMP/b.watch" 2>&1 &
watcher_pid=$!
touch "$B_WT/.go-hog"
for _ in $(seq 1 60); do kill -0 "$watcher_pid" 2>/dev/null || break; sleep 1; done
check "$(cat "$TMP/b.watch")" "TMUX_DIED" "watcher reports TMUX_DIED for the killed job"
journal=$(journalctl --user --since "$since" --no-pager 2>/dev/null | grep -F "${B_UNIT}")
note "--- journal for $B_UNIT ---"; printf '%s\n' "$journal" | sed 's/^[A-Z][a-z][a-z] [0-9 :]* [^ ]* /  /'
printf '%s' "$journal" | grep -q "Failed with result 'oom-kill'"; check "$?" 0 "job B scope failed with result oom-kill"
command tmux -L "$SOCK" has-session -t "=$A_SESSION" 2>/dev/null; check "$?" 0 "sibling job A tmux session survived"
systemctl --user is-active --quiet "$A_UNIT"; check "$?" 0 "sibling job A scope still active"
journalctl --user --since "$since" --no-pager 2>/dev/null | grep -F "$A_UNIT" | grep -q oom-kill
check "$?" 1 "no OOM event recorded for job A"

# --- AC5: existing recovery path — worktree preserved, freed slot admits a re-spawn ---
[ -d "$B_WT" ]; check "$?" 0 "killed job's worktree preserved for inspection"
spawn respawn.md "$TMP/d.manifest"; check "$?" 0 "re-spawn admitted into the freed slot"
D_SESSION=$(mval "$TMP/d.manifest" SESSION)
[ -n "$D_SESSION" ] && command tmux -L "$SOCK" has-session -t "=$D_SESSION" 2>/dev/null; check "$?" 0 "re-spawned job is running"
note "re-spawn: session=$D_SESSION unit=$(mval "$TMP/d.manifest" JOB_UNIT)"

[ "$fail" = 0 ] && note "ALL JOB-BOUNDS CHECKS PASSED" || note "JOB-BOUNDS CHECKS FAILED"
exit "$fail"
