#!/usr/bin/env bash
# Unit tests for .claude/skills/committee-loop/admission.sh (admission cap +
# per-job bounds prefix). Hermetic: a stub `tmux` function, a stub
# `systemd-run` on PATH, and a temp XDG_RUNTIME_DIR — no real tmux server,
# systemd scope, or worktree is touched.
# Mirrors scripts/headroom-launch-smoke.sh's note()/check()/exit "$fail" convention.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../.claude/skills/committee-loop/admission.sh"
fail=0
note()  { printf '%s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then note "PASS: $3"; else note "FAIL: $3"; note "  got:  $1"; note "  want: $2"; fail=1; fi; }

[ -f "$LIB" ] || { note "FAIL: $LIB not found"; exit 1; }
# shellcheck source=../.claude/skills/committee-loop/admission.sh
. "$LIB"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
export XDG_RUNTIME_DIR="$TMP/run"
mkdir -p "$XDG_RUNTIME_DIR" "$TMP/bin"
SESSIONS_FILE="$TMP/sessions"
: > "$SESSIONS_FILE"
tmux() { [ "$1" = list-sessions ] && cat "$SESSIONS_FILE"; }
SOCK=test-sock
DIR=$(committee_state_dir "$SOCK")

reset_env() {
  unset COMMITTEE_MAX_JOBS COMMITTEE_JOB_BOUNDS COMMITTEE_LOOP_SOCKET COMMITTEE_JOB_MEMORY_HIGH \
    COMMITTEE_JOB_MEMORY_MAX COMMITTEE_JOB_MEMORY_SWAP_MAX COMMITTEE_JOB_CPU_QUOTA COMMITTEE_JOB_TASKS_MAX
  : > "$SESSIONS_FILE"; rm -rf "$DIR"
}

# --- config validation ---
reset_env
committee_validate_config 2>/dev/null; check "$?" 0 "defaults validate"
check "$CL_MAX_JOBS/$CL_BOUNDS_MODE/$CL_SOCKET/$CL_MEMORY_HIGH/$CL_MEMORY_MAX/$CL_MEMORY_SWAP_MAX/$CL_CPU_QUOTA/$CL_TASKS_MAX" \
  "2/auto/committee-loop/infinity/4G/1G/200%/2048" "default values"
for bad in "COMMITTEE_MAX_JOBS=0" "COMMITTEE_MAX_JOBS=abc" "COMMITTEE_MAX_JOBS=-1" "COMMITTEE_MAX_JOBS=02" \
           "COMMITTEE_JOB_BOUNDS=on" "COMMITTEE_LOOP_SOCKET=a/b" "COMMITTEE_LOOP_SOCKET=a;b" \
           "COMMITTEE_JOB_MEMORY_MAX=4GB" "COMMITTEE_JOB_MEMORY_HIGH=0" "COMMITTEE_JOB_MEMORY_MAX=0" "COMMITTEE_JOB_MEMORY_SWAP_MAX=1G;x" \
           "COMMITTEE_JOB_CPU_QUOTA=200" "COMMITTEE_JOB_TASKS_MAX=-5"; do
  reset_env; export "${bad?}"
  msg=$(committee_validate_config 2>&1); rc=$?
  check "$rc" 1 "rejects $bad"
  case "$msg" in "invalid ${bad%%=*}"*) note "PASS: message names ${bad%%=*}" ;; *) note "FAIL: message for $bad: $msg"; fail=1 ;; esac
done
reset_env; export COMMITTEE_JOB_MEMORY_MAX=infinity COMMITTEE_JOB_TASKS_MAX=infinity COMMITTEE_MAX_JOBS=10
committee_validate_config 2>/dev/null; check "$?" 0 "accepts infinity + multi-digit cap"

# --- admission: cap N admits N, rejects N+1 deterministically ---
reset_env; export COMMITTEE_MAX_JOBS=2; committee_validate_config
committee_admit "$SOCK" committee-loop-a-1 "$$" 2>/dev/null; check "$?" 0 "job 1 of 2 admitted"
committee_admit "$SOCK" committee-loop-b-2 "$$" 2>/dev/null; check "$?" 0 "job 2 of 2 admitted"
msg=$(committee_admit "$SOCK" committee-loop-c-3 "$$" 2>&1); rc=$?
check "$rc" 75 "job 3 of 2 rejected with rc 75"
check "$msg" "committee-loop: admission rejected — 2/2 committee jobs already running (committee-loop-a-1, committee-loop-b-2). Wait for one to finish, stop one, or raise COMMITTEE_MAX_JOBS." "rejection message explains why"
check "$([ -e "$DIR/committee-loop-c-3" ] && echo present || echo absent)" absent "rejected job leaves no reservation"
for i in 1 2 3; do
  committee_admit "$SOCK" "committee-loop-d-$i" "$$" 2>/dev/null; rc=$?
  check "$rc" 75 "repeat rejection $i is deterministic"
done

# --- release frees a slot ---
committee_release "$SOCK" committee-loop-a-1
committee_admit "$SOCK" committee-loop-e-4 "$$" 2>/dev/null; check "$?" 0 "released slot is reusable"

# --- live tmux sessions count toward the cap (spawner already exited) ---
reset_env; export COMMITTEE_MAX_JOBS=2; committee_validate_config
printf '%s\n' committee-loop-live-1 committee-loop-live-2 other-session > "$SESSIONS_FILE"
msg=$(committee_admit "$SOCK" committee-loop-f-5 "$$" 2>&1); rc=$?
check "$rc" 75 "live sessions fill the cap"
case "$msg" in *"(committee-loop-live-1, committee-loop-live-2)"*) note "PASS: non-committee sessions ignored" ;; *) note "FAIL: $msg"; fail=1 ;; esac

# --- stale reservation (dead spawner, no session) is pruned ---
reset_env; export COMMITTEE_MAX_JOBS=1; committee_validate_config
mkdir -p "$DIR"
bash -c 'exit 0' & deadpid=$!; wait "$deadpid"
printf '%s\n' "$deadpid" > "$DIR/committee-loop-stale-1"
committee_admit "$SOCK" committee-loop-g-6 "$$" 2>/dev/null; check "$?" 0 "stale reservation does not hold a slot"
check "$([ -e "$DIR/committee-loop-stale-1" ] && echo present || echo absent)" absent "stale reservation pruned"

# --- a reservation whose PID was reused by another process is pruned ---
reset_env; export COMMITTEE_MAX_JOBS=1; committee_validate_config
mkdir -p "$DIR"
printf '%s 1\n' "$$" > "$DIR/committee-loop-reused-1"
committee_admit "$SOCK" committee-loop-j-9 "$$" 2>/dev/null; check "$?" 0 "reused-PID reservation does not hold a slot"
check "$([ -e "$DIR/committee-loop-reused-1" ] && echo present || echo absent)" absent "reused-PID reservation pruned"
check "$(cat "$DIR/committee-loop-j-9")" "$(committee_pid_token "$$")" "reservation records pid + start time"

# --- live-spawner reservation holds a slot even before its session exists ---
reset_env; export COMMITTEE_MAX_JOBS=1; committee_validate_config
committee_admit "$SOCK" committee-loop-h-7 "$$" 2>/dev/null
committee_admit "$SOCK" committee-loop-i-8 "$$" 2>/dev/null; check "$?" 75 "in-flight reservation holds its slot"

# --- concurrent admissions never exceed the cap ---
reset_env; export COMMITTEE_MAX_JOBS=3; committee_validate_config
for i in $(seq 1 12); do
  ( committee_admit "$SOCK" "committee-loop-race-$i" "$$" 2>/dev/null; echo "$?" > "$TMP/rc.$i" ) &
done
wait
admitted=$(cat "$TMP"/rc.* | grep -cx 0); rejected=$(cat "$TMP"/rc.* | grep -cx 75)
check "$admitted/$rejected" "3/9" "12 concurrent admissions at cap 3 admit exactly 3"
rm -f "$TMP"/rc.*

# --- same race without flock (mkdir lock; stock macOS) ---
reset_env; export COMMITTEE_MAX_JOBS=3; committee_validate_config
committee_have_flock() { return 1; }
for i in $(seq 1 12); do
  ( committee_admit "$SOCK" "committee-loop-mk-$i" "$$" 2>/dev/null; echo "$?" > "$TMP/rc.$i" ) &
done
wait
admitted=$(cat "$TMP"/rc.* | grep -cx 0); rejected=$(cat "$TMP"/rc.* | grep -cx 75)
check "$admitted/$rejected" "3/9" "mkdir lock: 12 concurrent admissions at cap 3 admit exactly 3"
check "$([ -e "$DIR/.lock.d" ] && echo held || echo released)" released "mkdir lock released"
mkdir -p "$DIR/.lock.d"; bash -c 'exit 0' & deadpid=$!; wait "$deadpid"; echo "$deadpid" > "$DIR/.lock.d/pid"
committee_admit "$SOCK" committee-loop-mk-stale "$$" 2>/dev/null; rc=$?
check "$rc" 75 "lock left by a dead holder is broken (cap still enforced)"
rm -f "$TMP"/rc.*
unset -f committee_have_flock
# shellcheck source=../.claude/skills/committee-loop/admission.sh
. "$LIB"

# --- bounds prefix ---
reset_env; export COMMITTEE_JOB_MEMORY_MAX=128M COMMITTEE_JOB_MEMORY_HIGH=96M COMMITTEE_JOB_MEMORY_SWAP_MAX=0 \
  COMMITTEE_JOB_CPU_QUOTA=50% COMMITTEE_JOB_TASKS_MAX=64
committee_validate_config 2>/dev/null; check "$?" 0 "MemorySwapMax=0 accepted (no swap)"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/systemd-run"; chmod +x "$TMP/bin/systemd-run"
PATH="$TMP/bin:$PATH" committee_build_bounds_argv slug-20260101-000000-1-2 2>/dev/null
check "$CL_JOB_UNIT" "committee-job-slug-20260101-000000-1-2" "unit name carries the job id"
check "$CL_BOUNDS_PREFIX" "systemd-run --user --scope --quiet --collect --unit=committee-job-slug-20260101-000000-1-2 -p MemoryHigh=96M -p MemoryMax=128M -p MemorySwapMax=0 -p CPUQuota=50% -p TasksMax=64 -p OOMPolicy=kill --" "bounds prefix built from config"

printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/systemd-run"
msg=$(PATH="$TMP/bin:$PATH" committee_build_bounds_argv x 2>&1)
PATH="$TMP/bin:$PATH" committee_build_bounds_argv x 2>/dev/null; rc=$?
check "$rc|$CL_JOB_UNIT|$CL_BOUNDS_PREFIX" "0||" "unusable systemd-run -> no wrapper, spawn continues"
case "$msg" in *UNBOUNDED*) note "PASS: unusable systemd-run warns UNBOUNDED" ;; *) note "FAIL: no UNBOUNDED warning: $msg"; fail=1 ;; esac

printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/systemd-run"
export COMMITTEE_JOB_BOUNDS=off; committee_validate_config
msg=$(PATH="$TMP/bin:$PATH" committee_build_bounds_argv x 2>&1)
PATH="$TMP/bin:$PATH" committee_build_bounds_argv x; rc=$?
check "$rc|$CL_JOB_UNIT|$CL_BOUNDS_PREFIX|$msg" "0|||" "COMMITTEE_JOB_BOUNDS=off -> no wrapper, silent"

[ "$fail" = 0 ] && note "ALL ADMISSION CHECKS PASSED" || note "ADMISSION CHECKS FAILED"
exit "$fail"
