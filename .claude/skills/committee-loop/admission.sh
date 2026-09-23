# shellcheck shell=bash disable=SC2034
# Sourced by spawn.sh. Admission control (a cap on concurrent committee-loop
# jobs) and per-job cgroup bounds (a transient `systemd-run --user --scope`
# per job). Callers must define `tmux` (socket-scoped) before calling
# committee_admit. No `set -e` assumptions: every function returns a status.
#
# Configuration (environment):
#   COMMITTEE_MAX_JOBS             concurrent jobs per tmux socket (default 2)
#   COMMITTEE_JOB_BOUNDS           auto | off (default auto)
#   COMMITTEE_LOOP_SOCKET          tmux socket name (default committee-loop)
#   COMMITTEE_JOB_MEMORY_HIGH      MemoryHigh per job (default infinity; a value near
#                                  MemoryMax can throttle a runaway indefinitely instead
#                                  of letting it reach MemoryMax and be killed)
#   COMMITTEE_JOB_MEMORY_MAX       MemoryMax per job (default 4G)
#   COMMITTEE_JOB_MEMORY_SWAP_MAX  MemorySwapMax per job (default 1G)
#   COMMITTEE_JOB_CPU_QUOTA        CPUQuota per job (default 200%)
#   COMMITTEE_JOB_TASKS_MAX        TasksMax per job (default 2048)

CL_ADMISSION_REJECT_RC=75   # EX_TEMPFAIL

committee_validate_config() {
  CL_MAX_JOBS="${COMMITTEE_MAX_JOBS:-2}"
  CL_BOUNDS_MODE="${COMMITTEE_JOB_BOUNDS:-auto}"
  CL_MEMORY_HIGH="${COMMITTEE_JOB_MEMORY_HIGH:-infinity}"
  CL_MEMORY_MAX="${COMMITTEE_JOB_MEMORY_MAX:-4G}"
  CL_MEMORY_SWAP_MAX="${COMMITTEE_JOB_MEMORY_SWAP_MAX:-1G}"
  CL_CPU_QUOTA="${COMMITTEE_JOB_CPU_QUOTA:-200%}"
  CL_TASKS_MAX="${COMMITTEE_JOB_TASKS_MAX:-2048}"

  case "$CL_MAX_JOBS" in
    ''|*[!0-9]*|0*) echo "invalid COMMITTEE_MAX_JOBS: '$CL_MAX_JOBS' (expected a positive integer)" >&2; return 1 ;;
  esac
  case "$CL_BOUNDS_MODE" in
    auto|off) ;;
    *) echo "invalid COMMITTEE_JOB_BOUNDS: '$CL_BOUNDS_MODE' (expected auto or off)" >&2; return 1 ;;
  esac
  CL_SOCKET="${COMMITTEE_LOOP_SOCKET:-committee-loop}"
  [[ "$CL_SOCKET" =~ ^[A-Za-z0-9_-]+$ ]] \
    || { echo "invalid COMMITTEE_LOOP_SOCKET: '$CL_SOCKET' (allowed: A-Z a-z 0-9 _ -)" >&2; return 1; }
  local name val
  for name in CL_MEMORY_HIGH CL_MEMORY_MAX CL_MEMORY_SWAP_MAX; do
    val="${!name}"
    [ "$name" = CL_MEMORY_SWAP_MAX ] && [ "$val" = 0 ] && continue
    [[ "$val" =~ ^([1-9][0-9]*[KMGT]?|infinity)$ ]] \
      || { echo "invalid ${name/CL_/COMMITTEE_JOB_}: '$val' (expected e.g. 512M, 4G or infinity)" >&2; return 1; }
  done
  [[ "$CL_CPU_QUOTA" =~ ^[1-9][0-9]*%$ ]] \
    || { echo "invalid COMMITTEE_JOB_CPU_QUOTA: '$CL_CPU_QUOTA' (expected e.g. 200%)" >&2; return 1; }
  [[ "$CL_TASKS_MAX" =~ ^([1-9][0-9]*|infinity)$ ]] \
    || { echo "invalid COMMITTEE_JOB_TASKS_MAX: '$CL_TASKS_MAX' (expected a positive integer or infinity)" >&2; return 1; }
  return 0
}

committee_state_dir() {
  printf '%s/committee-loop-admission/%s' "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}/committee-loop-$(id -u)}" "$1"
}

# "<pid> <start time>" (start time empty where /proc is absent), so a reservation
# cannot be kept alive by an unrelated process that reused the spawner's PID.
committee_pid_token() {
  local start=""
  [ -r "/proc/$1/stat" ] && start=$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20)
  printf '%s %s' "$1" "$start"
}

committee_pid_alive() {
  local pid="${1%% *}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$(committee_pid_token "$pid")" = "$1" ]
}

# Prints the names of active jobs on socket $1, one per line: live
# committee-loop-* tmux sessions plus reservations held by a live spawner.
# Prunes reservations whose spawner is gone and whose session never appeared.
committee_active_jobs() {
  local dir="$1" f name pid sessions
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^committee-loop-' || true)
  {
    [ -n "$sessions" ] && printf '%s\n' "$sessions"
    for f in "$dir"/committee-loop-*; do
      [ -f "$f" ] || continue
      name=$(basename -- "$f")
      pid=$(cat -- "$f" 2>/dev/null || true)
      if committee_pid_alive "$pid"; then
        printf '%s\n' "$name"
      elif ! printf '%s\n' "$sessions" | grep -qxF -- "$name"; then
        rm -f -- "$f"
      fi
    done
  } | sort -u
}

# committee_admit <socket> <session> <spawner-pid>
# Admits the job (writes a reservation) or rejects it with rc 75 and a message
# on stderr. The whole count-then-reserve step runs under one exclusive lock.
committee_admit() {
  local socket="$1" session="$2" pid="$3" dir active count rc
  dir=$(committee_state_dir "$socket")
  (umask 077; mkdir -p -- "$dir") || { echo "committee-loop: cannot create admission dir $dir" >&2; return 1; }
  command -v flock >/dev/null 2>&1 \
    || { echo "committee-loop: 'flock' is required for admission control (util-linux)" >&2; return 1; }
  exec {CL_LOCK_FD}>"$dir/.lock" || return 1
  flock -w 30 "$CL_LOCK_FD" || { exec {CL_LOCK_FD}>&-; echo "committee-loop: timed out waiting for the admission lock" >&2; return 1; }
  active=$(committee_active_jobs "$dir")
  count=$(printf '%s' "$active" | grep -c . || true)
  if [ "$count" -ge "$CL_MAX_JOBS" ]; then
    echo "committee-loop: admission rejected — $count/$CL_MAX_JOBS committee jobs already running ($(printf '%s' "$active" | paste -sd, - | sed 's/,/, /g')). Wait for one to finish, stop one, or raise COMMITTEE_MAX_JOBS." >&2
    rc=$CL_ADMISSION_REJECT_RC
  else
    printf '%s\n' "$(committee_pid_token "$pid")" > "$dir/$session" && rc=0 || rc=1
    [ "$rc" = 0 ] && echo "committee-loop: admitted $session ($((count + 1))/$CL_MAX_JOBS)" >&2
  fi
  flock -u "$CL_LOCK_FD"; exec {CL_LOCK_FD}>&-
  return "$rc"
}

committee_release() {
  rm -f -- "$(committee_state_dir "$1")/$2"
}

# Succeeds when a bounded transient scope can be created here. Uses fixed,
# generous caps so a deliberately tight operator cap cannot fail the probe.
committee_probe_bounds() {
  command -v systemd-run >/dev/null 2>&1 || return 1
  timeout 15 systemd-run --user --scope --quiet --collect \
    -p MemoryMax=256M -p CPUQuota=100% -p TasksMax=64 -p OOMPolicy=kill -- true >/dev/null 2>&1
}

# committee_build_bounds_argv <job-id>
# Sets CL_JOB_UNIT (scope unit name, empty when unbounded) and CL_BOUNDS_PREFIX
# (the command-line prefix for the tmux pane command, empty when unbounded).
committee_build_bounds_argv() {
  CL_JOB_UNIT=""; CL_BOUNDS_PREFIX=""
  [ "$CL_BOUNDS_MODE" = off ] && return 0
  if ! committee_probe_bounds; then
    echo "committee-loop: WARNING — job runs UNBOUNDED ('systemd-run --user --scope' unusable here; set COMMITTEE_JOB_BOUNDS=off to silence)" >&2
    return 0
  fi
  CL_JOB_UNIT="committee-job-$1"
  CL_BOUNDS_PREFIX="systemd-run --user --scope --quiet --collect --unit=$CL_JOB_UNIT -p MemoryHigh=$CL_MEMORY_HIGH -p MemoryMax=$CL_MEMORY_MAX -p MemorySwapMax=$CL_MEMORY_SWAP_MAX -p CPUQuota=$CL_CPU_QUOTA -p TasksMax=$CL_TASKS_MAX -p OOMPolicy=kill --"
  return 0
}
