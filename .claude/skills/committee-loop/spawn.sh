#!/usr/bin/env bash
# Committee-loop spawner. Invoked by the SKILL.md outer agent with target
# file paths as positional args; does preflight + worktree + seed + generates
# post.sh/watcher/instructions from adjacent body files + spawns detached tmux.
# Emits a manifest on stdout so the outer agent can launch the watcher in a
# separate Bash call.
set -euo pipefail

# Self-location so post-body.sh, watcher-body.sh, inner-agent.md resolve
# regardless of the invoker's cwd.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Cleanup guard: if anything between here and the tmux spawn fails, unwind the
# worktree+branch so we don't leak them. Cleared on successful spawn near the
# end of this script. INT/TERM/HUP/QUIT included so Ctrl-C, terminal hangup,
# or kill between worktree creation and tmux spawn also unwinds.
cleanup_on_error() {
  local rc=$?
  [ -n "${SESSION:-}" ] && tmux kill-session -t "$SESSION" 2>/dev/null || true
  [ -n "${WORKTREE_PATH:-}" ] && git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  [ -n "${BRANCH:-}" ] && git branch -D "$BRANCH" 2>/dev/null || true
  exit $rc
}
trap cleanup_on_error ERR INT TERM HUP QUIT

# ---- Preflight: args, targets, tools, skills, git identity ----

[ "$#" -gt 0 ] || {
  echo "usage: $(basename -- "$0") <target-file> [<target-file> ...]" >&2
  echo "       paths must be repo-relative (resolved against origin's repo root)" >&2
  exit 1
}

ORIGIN_PATH=$(git rev-parse --show-toplevel)
TARGET_FILES=( "$@" )

for f in "${TARGET_FILES[@]}"; do
  case "$f" in
    /*)
      # Downstream builds "$ORIGIN_PATH/$f"; an absolute $f produces a
      # broken path like "/origin//abs/file". Reject repo-absolute paths here.
      echo "target must be repo-relative, not absolute: $f" >&2; exit 1 ;;
  esac
  case "$f" in
    *[\"\`\$\\]* | *$'\n'*)
      # Reject shell metacharacters that would break downstream quoting
      # (ralph-loop's unquoted $ARGUMENTS, the %q-generated post-script header).
      echo "target contains shell metacharacter (\", \`, \$, \\, newline): $f" >&2; exit 1 ;;
  esac
  # Under --dangerously-skip-permissions an un-validated path is an arbitrary-
  # file-write primitive.
  [ -L "$ORIGIN_PATH/$f" ] && { echo "target is a symlink (not supported): $f" >&2; exit 1; }
  ABS=$(cd "$ORIGIN_PATH" && realpath -e -- "$f" 2>/dev/null) \
    || { echo "target does not exist: $f" >&2; exit 1; }
  case "$ABS" in
    "$ORIGIN_PATH"/*) ;;
    *) echo "target resolves outside origin: $f -> $ABS" >&2; exit 1 ;;
  esac
done

for t in tmux claude git realpath sha256sum kiro-cli codex gemini; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

# GNU realpath -e; BSD realpath (default macOS) does not support it. Behavior
# probe (not help-text parse) so wording changes can't break it.
realpath -e -- . >/dev/null 2>&1 \
  || { echo "realpath does not support -e (BSD realpath?); install GNU coreutils (macOS: brew install coreutils)" >&2; exit 1; }

# --effort is referenced in the tmux spawn below; fail fast before worktree cost.
claude --help 2>/dev/null | grep -q -- --effort \
  || { echo "claude CLI missing --effort flag; upgrade claude or remove --effort from spawn.sh" >&2; exit 1; }

# --path-format=absolute (git 2.31+) is used by post-body.sh. Probe by invoking
# the flag itself — avoids help-text parse and `git --help` pager behavior.
git rev-parse --path-format=absolute --git-dir >/dev/null 2>&1 \
  || { echo "git too old (need 2.31+ for rev-parse --path-format); upgrade git" >&2; exit 1; }

# Depends on installed skills/plugins. Only check ones that reliably show up
# as directories under ~/.claude or $ORIGIN_PATH/.claude: ralph-loop, committee,
# superpowers:receiving-code-review. `simplify` and `superpowers:code-reviewer`
# are NOT checked — the former is harness-registered, the latter is an agent
# .md file rather than a directory. Missing-at-runtime surfaces as an Agent/
# Skill error from the inner agent.
check_skill_or_plugin() {
  local label="$1"; shift
  local -a patterns=( "$@" )
  local roots=( "$HOME/.claude" "$ORIGIN_PATH/.claude" )
  local root pat
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    for pat in "${patterns[@]}"; do
      find "$root" -type d \( -name "$pat" -o -path "*/$pat" -o -path "*/$pat/*" \) 2>/dev/null | grep -q . && return 0
    done
  done
  echo "$label not found under ~/.claude or $ORIGIN_PATH/.claude; install it before running committee-loop" >&2
  exit 1
}
check_skill_or_plugin "ralph-loop plugin"                       "ralph-loop"
check_skill_or_plugin "committee skill"                         "committee"
check_skill_or_plugin "superpowers:receiving-code-review skill" "receiving-code-review"

# Seed commit + copy-back commit both require a git identity.
git config user.name >/dev/null && git config user.email >/dev/null \
  || { echo "git user.name/user.email not configured; committee-loop needs both for worktree + copy-back commits" >&2; exit 1; }

# Body files must exist before we try to cat them into the generated scripts.
for required in inner-agent.md post-body.sh watcher-body.sh; do
  [ -f "$SCRIPT_DIR/$required" ] \
    || { echo "committee-loop skill corrupt: $SCRIPT_DIR/$required missing" >&2; exit 1; }
done

# ---- Create the worktree ----

PROJECT=$(basename -- "$ORIGIN_PATH")
SLUG=$(basename -- "${TARGET_FILES[0]}" | sed 's/\.[^.]*$//' | tr -c 'a-zA-Z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
SLUG="${SLUG:-review}"
SLUG="${SLUG:0:40}"
TS="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
# `dirname` (not "$ORIGIN_PATH/..") keeps WORKTREE_PATH canonical — post-body.sh's
# containment check compares it against `realpath -e` output which is canonical.
WORKTREE_PATH="$(dirname -- "$ORIGIN_PATH")/${PROJECT}-committee-loop-${SLUG}-${TS}"
BRANCH="committee-loop/${SLUG}-${TS}"
SESSION="committee-loop-${SLUG}-${TS}"

git worktree add "$WORKTREE_PATH" -b "$BRANCH"

# ---- Seed the worktree ----

# Copy into the worktree first, then hash the worktree bytes. Those are the
# exact bytes handed to the review, so at copy-back time the baseline represents
# what was reviewed. `git status` cannot substitute because we intentionally
# copy uncommitted origin edits in; origin stays "dirty" for the whole review.
declare -a SEED_HASHES=()
for f in "${TARGET_FILES[@]}"; do
  mkdir -p "$WORKTREE_PATH/$(dirname -- "$f")"
  cp -P "$ORIGIN_PATH/$f" "$WORKTREE_PATH/$f"
  HASH=$(sha256sum "$WORKTREE_PATH/$f" | awk '{print $1}')
  [ -n "$HASH" ] || { echo "sha256sum produced empty hash for $f" >&2; exit 1; }
  SEED_HASHES+=( "$HASH" )
done
(
  cd "$WORKTREE_PATH" || exit 1
  git add -A
  git diff --cached --quiet || git commit -m "seed: pull latest uncommitted target from origin"
)

# ---- Build the inner-agent instructions file ----

TARGET_JOINED=$(printf '%s, ' "${TARGET_FILES[@]}")
TARGET_JOINED="${TARGET_JOINED%, }"

INSTRUCTIONS="$WORKTREE_PATH/.committee-loop-instructions.md"
{
  printf '# Committee-Loop — Target file(s)\n\n'
  printf 'Target file(s): %s\n\n' "$TARGET_JOINED"
  printf -- '---\n\n'
  cat "$SCRIPT_DIR/inner-agent.md"
} > "$INSTRUCTIONS"

RALPH_PROMPT="Read .committee-loop-instructions.md and follow it exactly. Review the target files named in that file using the phase-based workflow described, then iterate per the instructions until you emit the REVIEW CLEAN promise."
# ralph-loop's slash-command template substitutes $ARGUMENTS UNQUOTED. No
# backticks, no parens, no $, no quotes in RALPH_PROMPT.
RALPH_INVOCATION="/ralph-loop:ralph-loop \"$RALPH_PROMPT\" --completion-promise \"REVIEW CLEAN\" --max-iterations 10"

# ---- Build post.sh (header + post-body.sh) ----

POST_SCRIPT="$WORKTREE_PATH/.committee-loop-post.sh"

ORIGIN_REF=$(git -C "$ORIGIN_PATH" rev-parse --abbrev-ref HEAD)
# HEAD detached at spawn ("HEAD") is rejected rather than silently accepted:
# without a branch name, copy-back would commit to detached HEAD and the commit
# would be invisible from any branch.
[ "$ORIGIN_REF" != "HEAD" ] \
  || { echo "origin is on detached HEAD; committee-loop requires a named branch so copy-back lands where the user expects" >&2; exit 1; }

{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'ORIGIN_PATH=%q\n' "$ORIGIN_PATH"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'BRANCH=%q\n' "$BRANCH"
  printf 'SESSION=%q\n' "$SESSION"
  printf 'ORIGIN_REF=%q\n' "$ORIGIN_REF"
  printf 'TARGET_FILES=('
  printf ' %q' "${TARGET_FILES[@]}"
  printf ' )\n'
  printf 'SEED_HASHES=('
  printf ' %q' "${SEED_HASHES[@]}"
  printf ' )\n'
} > "$POST_SCRIPT"
cat "$SCRIPT_DIR/post-body.sh" >> "$POST_SCRIPT"
chmod +x "$POST_SCRIPT"

# ---- Build watcher.sh (header + watcher-body.sh) ----

WATCHER_SCRIPT="$WORKTREE_PATH/.committee-loop-watcher.sh"
ORIGIN_GIT_DIR=$(git -C "$ORIGIN_PATH" rev-parse --path-format=absolute --git-common-dir)
ART_DIR="$ORIGIN_GIT_DIR/committee-loop/$SESSION"

{
  printf '#!/usr/bin/env bash\nset -u\n'
  printf 'SESSION=%q\n' "$SESSION"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'ART_DIR=%q\n' "$ART_DIR"
} > "$WATCHER_SCRIPT"
cat "$SCRIPT_DIR/watcher-body.sh" >> "$WATCHER_SCRIPT"
chmod +x "$WATCHER_SCRIPT"

# ---- Build the wrapper prompt the tmux session receives ----

PROMPT_FILE="$WORKTREE_PATH/.committee-loop-prompt.txt"
cat > "$PROMPT_FILE" <<EOF
You are in an isolated worktree at $WORKTREE_PATH. The origin checkout is at $ORIGIN_PATH.

Run the ralph-loop below. The inner loop instructions (in \`.committee-loop-instructions.md\`) handle copy-back and teardown via \`bash .committee-loop-post.sh\` — do not run post.sh yourself.

If ralph-loop exhausts its iteration limit without emitting a promise, write \`.committee-loop-EXHAUSTED.txt\` in this worktree summarizing the last iteration's outstanding findings so the user has a signal other than a stale tmux session.

The ralph-loop instructions embed review-feedback discipline (receiving-code-review, verify claims, decision ledger, quorum + severity gates, convergence exit). Follow them literally — skipping the verification or ledger steps is the failure mode this skill exists to prevent.

Now run the review loop:
EOF
printf '\n%s\n' "$RALPH_INVOCATION" >> "$PROMPT_FILE"

# ---- Spawn the detached tmux session ----

# -x/-y are required: a detached tmux session with no client attached defaults
# to a terminal size too small for Claude's TUI (the pane stays blank, readiness
# never triggers).
# --effort high balances loop-agent discipline (ledger + verification steps)
# against total wall-time. `max` rarely pays off for single-file reviews.
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKTREE_PATH" \
  "claude --dangerously-skip-permissions --effort high"

READY=false
TRUST_DISMISSED=false
for _ in $(seq 1 30); do
  PANE=$(tmux capture-pane -t "$SESSION" -p)
  if echo "$PANE" | grep -qF 'bypass permissions on'; then
    READY=true; break
  fi
  # Claude Code shows a folder-trust prompt for unknown directories BEFORE
  # entering the main TUI — even under --dangerously-skip-permissions. The
  # cursor (❯) is pre-positioned on "Yes, I trust this folder" so a bare Enter
  # confirms. Auto-answer once, then keep polling for the main TUI footer.
  if ! $TRUST_DISMISSED && echo "$PANE" | grep -qF 'Yes, I trust this folder'; then
    tmux send-keys -t "$SESSION" Enter
    TRUST_DISMISSED=true
  fi
  sleep 1
done
if ! $READY; then
  echo "error: Claude input box did not render within 30s; aborting" >&2
  # Dump captured pane so a TUI footer-wording change (or unexpected prompt)
  # is diagnosable without attaching to a killed tmux session.
  echo "--- captured pane contents (for diagnosis) ---" >&2
  tmux capture-pane -t "$SESSION" -p >&2 || true
  echo "--- end pane contents ---" >&2
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  git worktree remove --force "$WORKTREE_PATH" || true
  git branch -D "$BRANCH" || true
  exit 1
fi

# Clear the cleanup trap BEFORE the paste window below — any ERR from tmux
# capture-pane/grep/send-keys would otherwise trip the trap and tear down the
# session we just confirmed alive. Paste failures are recoverable by attaching.
trap - ERR INT TERM HUP QUIT

# Bracketed paste (-p) so multi-line content is delivered atomically. Without
# it tmux converts LF to CR, which in a TUI submits line-by-line and fragments
# the prompt.
tmux load-buffer -b "$SESSION" "$PROMPT_FILE"
tmux paste-buffer -p -t "$SESSION" -b "$SESSION"
tmux delete-buffer -b "$SESSION"

# Claude Code's TUI stages a bracketed paste as `[Pasted text #N +M lines]` and
# does not submit on the same keystroke that ends the paste. Poll until the
# staged indicator appears, then send Enter, and re-send if still visible.
for _ in $(seq 1 10); do
  tmux capture-pane -t "$SESSION" -p | grep -qE '\[Pasted text' && break
  sleep 1
done
for _ in $(seq 1 5); do
  tmux send-keys -t "$SESSION" Enter
  sleep 2
  tmux capture-pane -t "$SESSION" -p | grep -qE '\[Pasted text' || break
done

# Protected-paths watchdog. Claude Code prompts on `.claude/` edits even under
# --dangerously-skip-permissions (claude-code#35718). Detached agent can't
# answer interactively — poll from outside and pick option 2 (session-scoped).
# 12h cap guards against a leaked watchdog; exits when tmux session dies.
nohup bash -c '
  end=$(( $(date +%s) + 43200 ))
  while [ "$(date +%s)" -lt "$end" ] && tmux has-session -t "$1" 2>/dev/null; do
    if tmux capture-pane -t "$1" -p 2>/dev/null | grep -qF "Yes, and allow Claude to edit its own settings"; then
      tmux send-keys -t "$1" "2"; sleep 0.3; tmux send-keys -t "$1" Enter
      break
    fi
    sleep 3
  done
' _ "$SESSION" >/dev/null 2>&1 &
disown

# ---- Emit manifest on stdout + copy to worktree for later recovery ----

# %q-escape each value so the manifest is safely sourceable when paths contain
# spaces or shell metacharacters (matches the post.sh header pattern).
MANIFEST="$WORKTREE_PATH/.committee-loop-manifest.txt"
{
  printf 'SESSION=%q\n' "$SESSION"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'BRANCH=%q\n' "$BRANCH"
  printf 'ORIGIN_PATH=%q\n' "$ORIGIN_PATH"
  printf 'ORIGIN_REF=%q\n' "$ORIGIN_REF"
  printf 'ORIGIN_GIT_DIR=%q\n' "$ORIGIN_GIT_DIR"
  printf 'WATCHER_SCRIPT=%q\n' "$WATCHER_SCRIPT"
  printf 'TARGET_FILES_JOINED=%q\n' "$TARGET_JOINED"
} > "$MANIFEST"
# Print to stdout separately (non-pipeline) so a `tee` failure under pipefail
# can't orphan the live tmux session + watchdog launched above.
cat "$MANIFEST"
