#!/usr/bin/env bash
# Hermetic smoke for prepare.sh outside a git repo: plan/files scopes succeed with
# NO_GIT=1, the session dir lands under $XDG_CACHE_HOME/committee (the reviewed dir
# is never written), WORKFLOW_SCRIPT is a real copy, a plan outside the cwd roots
# PROJECT_ROOT at the plan's dir, diff scopes are rejected, and a git repo still
# uses <repo>/.committee without NO_GIT.
# Mirrors scripts/headroom-launch-smoke.sh's note()/check()/exit "$fail" convention.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PREPARE="$HERE/../.claude/skills/committee/prepare.sh"
PROMPTS="$HERE/../prompts"
fail=0
note()  { printf '%s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then note "PASS: $3"; else note "FAIL: $3"; note "  got:  $1"; note "  want: $2"; fail=1; fi; }

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT INT TERM
export GIT_CEILING_DIRECTORIES="$TMP" XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$TMP/work" "$TMP/elsewhere" "$TMP/repo"
printf '# plan\nstep 1\n' > "$TMP/work/plan.md"
printf '# far plan\n' > "$TMP/elsewhere/far.md"
printf 'echo hi\n' > "$TMP/work/a.sh"

# run <dir> <args...>: prepare.sh's exit code in $rc; its manifest sourced in a clean namespace.
run() {
  local dir=$1; shift
  unset SESSION_DIR PROJECT_ROOT NO_GIT WORKFLOW_SCRIPT
  out=$(cd "$dir" && bash "$PREPARE" "$@" 2>"$TMP/err"); rc=$?
  [ "$rc" = 0 ] && eval "$out"
}

run "$TMP/work" --scope=plan --plan=plan.md --prompts-dir="$PROMPTS"
check "$rc" 0 "non-git plan succeeds"
check "${NO_GIT:-}" 1 "manifest carries NO_GIT=1"
check "${PROJECT_ROOT:-}" "$TMP/work" "PROJECT_ROOT is the cwd"
case "${SESSION_DIR:-}" in "$TMP/cache/committee/session-"*) s=cache ;; *) s="${SESSION_DIR:-}" ;; esac
check "$s" cache "session dir under \$XDG_CACHE_HOME/committee"
check "$(cmp -s "$TMP/work/plan.md" "${SESSION_DIR:-/x}/diff.txt" && echo same)" same "diff.txt is the plan"
check "$( [ -f "${WORKFLOW_SCRIPT:-/x}" ] && [ ! -L "$WORKFLOW_SCRIPT" ] && cmp -s "$WORKFLOW_SCRIPT" "$PROMPTS/committee-review.js" && echo copy)" copy "WORKFLOW_SCRIPT is a real copy of the install's workflow"
check "$(find "$TMP/work" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' ')" "a.sh plan.md " "reviewed dir is not written"

run "$TMP/work" --scope=plan --plan="$TMP/elsewhere/far.md"
check "$rc" 0 "non-git plan outside the cwd succeeds"
check "${PROJECT_ROOT:-}" "$TMP/elsewhere" "PROJECT_ROOT is the plan's dir"
check "${WORKFLOW_SCRIPT:-unset}" unset "no --prompts-dir → no WORKFLOW_SCRIPT"

XDG_CACHE_HOME=rel HOME="$TMP/home" run "$TMP/work" --scope=plan --plan=plan.md
case "${SESSION_DIR:-}" in "$TMP/home/.cache/committee/session-"*) s=home ;; *) s="${SESSION_DIR:-}" ;; esac
check "$rc:$s" "0:home" "relative \$XDG_CACHE_HOME is ignored"

mkdir -p "$TMP/work/tmpx"
XDG_CACHE_HOME='' HOME="$TMP/work" TMPDIR="$TMP/outside" run "$TMP/work" --scope=plan --plan=plan.md
case "${SESSION_DIR:-}" in "$TMP/outside/committee/session-"*) s=tmpdir ;; *) s="${SESSION_DIR:-}" ;; esac
check "$rc:$s:$( [ -e "$TMP/work/.cache" ] && echo wrote )" "0:tmpdir:" "cache inside the reviewed dir falls back to \$TMPDIR"
before=$(find "$TMP/work" | sort)
XDG_CACHE_HOME='' HOME="$TMP/work" TMPDIR="$TMP/work/tmpx" run "$TMP/work" --scope=plan --plan=plan.md
check "$rc:$(grep -c 'both inside' "$TMP/err"):$( [ "$(find "$TMP/work" | sort)" = "$before" ] && echo same)" "1:1:same" "cache and \$TMPDIR both inside the reviewed dir is rejected"
rmdir "$TMP/work/tmpx"
XDG_CACHE_HOME="$TMP/missing/../work/cache" TMPDIR="$TMP/outside" run "$TMP/work" --scope=plan --plan=plan.md
case "${SESSION_DIR:-}" in "$TMP/outside/committee/session-"*) s=tmpdir ;; *) s="${SESSION_DIR:-}" ;; esac
check "$rc:$s:$( [ -e "$TMP/work/cache" ] && echo wrote )" "0:tmpdir:" "a cache path with .. is skipped"

printf 'a.sh\n' > "$TMP/paths.txt"
run "$TMP/work" --scope=files --paths-file="$TMP/paths.txt"
check "$rc" 0 "non-git files succeeds"
check "${NO_GIT:-}" 1 "files manifest carries NO_GIT=1"
check "$(grep -c '^=== FILE: a.sh ===$' "${SESSION_DIR:-/x}/diff.txt" 2>/dev/null)" 1 "files diff.txt carries the file"

printf 'import os\n' > "$TMP/work/b.py"
printf 'b.py\n' > "$TMP/paths.txt"
before=$(find "$TMP/work" | sort)
run "$TMP/work" --scope=files --paths-file="$TMP/paths.txt"
check "$rc:$( [ "$(find "$TMP/work" | sort)" = "$before" ] && echo same)" "0:same" "non-git .py files review leaves the reviewed dir untouched (static pre-pass)"

for args in "--scope=commit --commit=abc1234" "--scope=uncommitted" "--scope=branch_diff --base=main"; do
  # shellcheck disable=SC2086
  run "$TMP/work" $args
  check "$rc:$(grep -c 'must be run inside a git repository' "$TMP/err")" "1:1" "non-git rejects ${args%% *}"
done

run "$TMP/work" --scope=plan --plan=plan.md --prompts-dir="$TMP/elsewhere"
check "$rc:$(grep -c 'has no committee-review.js' "$TMP/err")" "1:1" "--prompts-dir without the workflow is rejected"

git -C "$TMP/repo" init -q && cp "$TMP/work/plan.md" "$TMP/repo/" \
  && git -C "$TMP/repo" add plan.md && git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -qm init
run "$TMP/repo" --scope=plan --plan=plan.md
check "$rc" 0 "in-git plan succeeds"
check "${NO_GIT:-unset}" unset "in-git manifest has no NO_GIT"
case "${SESSION_DIR:-}" in "$TMP/repo/.committee/session-"*) s=repo ;; *) s="${SESSION_DIR:-}" ;; esac
check "$s" repo "in-git session dir under <repo>/.committee"

exit "$fail"
