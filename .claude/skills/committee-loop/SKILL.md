---
name: committee-loop
description: Use when iteratively reviewing and refining a spec, plan, design doc, or file with /committee until zero critical and important issues remain. Triggers on "/committee-loop", "committee loop", "review until clean", "iterate committee review", "keep reviewing until no issues".
---

# Committee Loop

## Overview

Spawn a detached Claude Code session in an isolated worktree that runs `/ralph-loop:ralph-loop` with `/committee` as the review task. Inside each iteration the loop agent verifies each finding, applies only vetted critical/important ones, maintains a decision ledger to prevent thrashing, and stops when the review is clean or when it starts reversing its own prior fixes.

**Core principle:** Unattended review-and-refine loop in an isolated workspace, with reviewer-feedback discipline applied **inside** the loop so findings are vetted, not blindly implemented.

**Announce at start:** "I'm using the committee-loop skill to spawn a detached review loop in a worktree."

## When to Use

- Polishing a spec, plan, or design doc via multiple committee passes
- Any review target where the first committee pass is likely to surface fixable issues
- When you want to walk away and return to a commit that's already been vetted

**Do NOT use when:**
- The target needs human judgment on each finding (use `/committee` directly)
- You only want a single review (use `/committee` directly)
- `tmux`, `git`, or `claude` is not installed

## Invocation

```
/committee-loop <review target description that includes a file path>
```

Example:
```
/committee-loop Review docs/superpowers/specs/2026-04-07-upstream-merge-v1.2.52-design.md
```

The argument MUST include at least one concrete file path. If no path is present, stop and ask the user which file to review.

## Workflow

> **Execute steps 1–6 as a single bash block** (or chain them with `&&` inside one Bash tool invocation). Claude Code's Bash tool does not preserve shell variables between calls, so `TARGET_FILES`, `ORIGIN_PATH`, `SEED_HASHES`, `SESSION`, etc. will be empty if a later step runs in a fresh call.

### 1. Parse and verify

Before running the block below, parse the user's invocation argument to extract the target file path(s). The argument is free-form text that MUST contain at least one concrete repo-relative path. Populate the `TARGET_FILES` array with the parsed paths — the `( "docs/spec.md" "docs/plan.md" )` literal is an illustrative placeholder, not a default. Do not execute the block with the placeholder values.

```bash
set -euo pipefail

# Cleanup guard: if anything between here and the tmux spawn fails, unwind the
# worktree+branch so we don't leak them. Cleared on successful spawn (Step 6).
cleanup_on_error() {
  local rc=$?
  [ -n "${SESSION:-}" ] && tmux kill-session -t "$SESSION" 2>/dev/null || true
  [ -n "${WORKTREE_PATH:-}" ] && git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  [ -n "${BRANCH:-}" ] && git branch -D "$BRANCH" 2>/dev/null || true
  exit $rc
}
# INT/TERM/HUP/QUIT included so Ctrl-C, terminal hangup, or kill between
# worktree creation and tmux spawn also unwinds the worktree+branch instead
# of leaking them. Cleared at end of Step 6 once the session is safely detached.
trap cleanup_on_error ERR INT TERM HUP QUIT

ORIGIN_PATH=$(git rev-parse --show-toplevel)

# Populate from the parsed user argument. The sentinel below is intentionally
# an invalid path so an agent that runs this block verbatim fails fast instead
# of silently reviewing the wrong files.
TARGET_FILES=( "__REPLACE_WITH_USER_PATHS__" )  # placeholder — replace with user's paths

[ "${#TARGET_FILES[@]}" -gt 0 ] \
  || { echo "no target files parsed from user argument"; exit 1; }

for f in "${TARGET_FILES[@]}"; do
  case "$f" in
    __REPLACE_WITH_USER_PATHS__*)
      echo "TARGET_FILES still holds the __REPLACE_WITH_USER_PATHS__ placeholder — parse the user argument first"; exit 1 ;;
    /*)
      # Downstream Step 3 builds "$ORIGIN_PATH/$f"; an absolute $f produces a
      # broken path like "/origin//abs/file". Reject repo-absolute paths here.
      echo "target must be repo-relative, not absolute: $f"; exit 1 ;;
  esac
  # Reject shell metacharacters that would break downstream quoting/interpolation
  # (heredoc, ralph-loop's unquoted $ARGUMENTS, the `%q`-generated post-script).
  case "$f" in
    *[\"\`\$\\]* | *$'\n'*)
      echo "target contains shell metacharacter (\", \`, \$, \\, newline): $f"; exit 1 ;;
  esac
  # Under --dangerously-skip-permissions an un-validated path is an arbitrary-file-write primitive.
  [ -L "$ORIGIN_PATH/$f" ] && { echo "target is a symlink (not supported): $f"; exit 1; }
  ABS=$(cd "$ORIGIN_PATH" && realpath -e -- "$f" 2>/dev/null) \
    || { echo "target does not exist: $f"; exit 1; }
  case "$ABS" in
    "$ORIGIN_PATH"/*) ;;
    *) echo "target resolves outside origin: $f -> $ABS"; exit 1 ;;
  esac
done

for t in tmux claude git realpath sha256sum kiro-cli; do
  command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 1; }
done

# realpath usage below (Step 1 + post-script) relies on GNU `-e`; BSD realpath
# (default macOS) does not support it. Fail fast here rather than hitting a
# cryptic error mid-run.
realpath --help 2>&1 | grep -q -- '-e,' \
  || { echo "realpath does not support -e (BSD realpath?); install GNU coreutils"; exit 1; }

# --effort is referenced in Step 6 (tmux spawn); fail fast if this claude build
# does not support it rather than after paying the worktree/tmux setup cost.
claude --help 2>/dev/null | grep -q -- --effort \
  || { echo "claude CLI missing --effort flag; upgrade claude or remove --effort from Step 6"; exit 1; }

# --path-format=absolute (used in post-script) was added in git 2.31. Probe by
# invoking the flag itself — behavior test, not help-text parse, so coreutils-
# style wording changes can't break it, and `git --help` pager behavior on
# interactive TTYs is avoided entirely.
git rev-parse --path-format=absolute --git-dir >/dev/null 2>&1 \
  || { echo "git too old (need 2.31+ for rev-parse --path-format); upgrade git"; exit 1; }

# The workflow depends on three skills/plugins — ralph-loop (plugin), committee
# (skill), and superpowers:receiving-code-review (skill). Check the filesystem
# so missing dependencies surface here, not inside the detached tmux session.
find "$HOME/.claude" -type d \( -name "ralph-loop" -o -path "*/plugins/*/ralph-loop*" \) 2>/dev/null | grep -q . \
  || { echo "ralph-loop plugin not found under ~/.claude/; install it before running committee-loop"; exit 1; }
[ -d "$HOME/.claude/skills/committee" ] || find "$HOME/.claude" -type d -name "committee" 2>/dev/null | grep -q . \
  || { echo "committee skill not found under ~/.claude/; install it before running committee-loop"; exit 1; }
find "$HOME/.claude" -type d \( -name "receiving-code-review" -o -path "*/superpowers*/receiving-code-review*" \) 2>/dev/null | grep -q . \
  || { echo "superpowers:receiving-code-review skill not found under ~/.claude/; install it before running committee-loop"; exit 1; }

# Commits inside the worktree (Step 3 seed) and at copy-back (post-script) both
# require a git identity. Fail fast rather than inside the detached run.
git config user.name >/dev/null && git config user.email >/dev/null \
  || { echo "git user.name/user.email not configured; committee-loop needs both for worktree + copy-back commits"; exit 1; }
```

macOS note: install `coreutils` (`brew install coreutils`) so GNU `realpath`/`sha256sum` are on PATH for subprocesses.

### 2. Create the worktree

Sibling-directory placement per the user's worktree preference:

```bash
PROJECT=$(basename -- "$ORIGIN_PATH")
SLUG=$(basename -- "${TARGET_FILES[0]}" | sed 's/\.[^.]*$//' | tr -c 'a-zA-Z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
SLUG="${SLUG:-review}"
SLUG="${SLUG:0:40}"
TS="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
# `dirname` (not "$ORIGIN_PATH/..") keeps WORKTREE_PATH canonical — the post-script's
# containment check compares it against `realpath -e` output, which is canonical.
WORKTREE_PATH="$(dirname -- "$ORIGIN_PATH")/${PROJECT}-committee-loop-${SLUG}-${TS}"
BRANCH="committee-loop/${SLUG}-${TS}"
SESSION="committee-loop-${SLUG}-${TS}"

git worktree add "$WORKTREE_PATH" -b "$BRANCH"
```

Do NOT use the `using-git-worktrees` skill — it's interactive and runs test baselines we don't need here.

### 3. Seed the worktree

Copy into the worktree first, then hash the worktree bytes. Those are the exact bytes handed to the review, so at copy-back time the baseline represents what was reviewed. A `git status` check can't substitute: Step 3 intentionally copies uncommitted origin edits in, so origin stays "dirty" for the whole review.

```bash
declare -a SEED_HASHES=()
for f in "${TARGET_FILES[@]}"; do
  mkdir -p "$WORKTREE_PATH/$(dirname "$f")"
  cp -P "$ORIGIN_PATH/$f" "$WORKTREE_PATH/$f"
  HASH=$(sha256sum "$WORKTREE_PATH/$f" | awk '{print $1}')
  [ -n "$HASH" ] || { echo "sha256sum produced empty hash for $f"; exit 1; }
  SEED_HASHES+=( "$HASH" )
done
(
  cd "$WORKTREE_PATH" || exit 1
  git add -A
  git diff --cached --quiet || git commit -m "seed: pull latest uncommitted target from origin"
)
```

### 4. Build the ralph-loop prompt (with anti-thrashing discipline)

The discipline that goes into the loop is load-bearing. Without it the loop agent applies every finding uncritically — one reviewer's false claim becomes an edit; a subsequent reviewer's contradictory claim becomes a reversal. The rules below enforce verify-before-apply, a persistent decision ledger, a quorum gate, a severity gate, and a convergence exit.

Write the full discipline to a file in the worktree and have the ralph-loop prompt reference the file rather than embed the rules inline. Ralph-loop's slash-command template uses an **unquoted** `$ARGUMENTS` substitution, so any backticks, parentheses, or `$` characters in the inline prompt break bash parsing. A short filename-only argument avoids the whole class of quoting failures and keeps the rules easy to edit.

```bash
TARGET_JOINED=$(printf '%s, ' "${TARGET_FILES[@]}")
TARGET_JOINED="${TARGET_JOINED%, }"

cat > "$WORKTREE_PATH/.committee-loop-instructions.md" <<EOF
# Committee-Loop Instructions

Target file(s): $TARGET_JOINED

## Exit protocol (read first)

Ralph-loop's stop-hook compares the text inside a \`<promise>...</promise>\` tag to the completion promise by **exact string equality**. Plain prose like "REVIEW CLEAN" will NOT release the loop. Your final message MUST contain the literal XML tag:

    <promise>REVIEW CLEAN</promise>

Preferably as the last line. Both clean and converged exits use the same tag — convergence reason lives in \`.committee-loop-CONVERGED.txt\`.

**Run \`bash .committee-loop-post.sh\` BEFORE emitting the promise** — if the promise goes first, ralph may terminate the session before post.sh runs.

## Per-iteration workflow

Each iteration runs these steps in order.

### 1. Simplify pre-pass (every iteration)

Before running reviewers, invoke the \`simplify\` skill on the target file. Follow its workflow: it dispatches three parallel agents (reuse, quality, efficiency) against the diff. Apply any non-contentious fixes it returns, commit as \`simplify iter-<N>: <brief summary>\`. Run this BEFORE the reviewers so they see the simplified baseline. If simplify returns nothing, commit nothing and move on.

### 2. Review

**Iteration 1 — fast mode (Claude + Kiro only, skip Codex + Gemini):**

Codex is the slowest reviewer and Gemini is the least reliable in this harness; skipping both on the first pass catches easy issues faster. Dispatch two reviewers in parallel:

a. \`superpowers:code-reviewer\` subagent with prompt: *"Review <TARGET> for code quality, bugs, design, shell safety. Output a Critical/Important/Minor list with line references and verification commands where possible."*

b. \`kiro-cli chat --no-interactive --trust-tools=fs_read\` with the same prompt against the target file path.

Do not use \`/committee\`; the coordinator's dispatch pattern includes Codex and Gemini. Synthesize the two reports into a single Critical/Important/Minor list yourself.

**Iteration 2+ — full mode:**

Use \`/committee --files <TARGET>\` (all 4 reviewers) for a thorough second pass. Iteration 2 benefits from Codex's and Gemini's perspectives once the easy Claude+Kiro findings are resolved.

### 3. Classify with parallel verifiers

Dispatch one verifier subagent PER REVIEWER in parallel (2 for iter-1, 4 for iter-2+). Each verifier:
- Reads its reviewer's report
- Runs verification commands for each Critical/Important claim it contains (e.g. \`claude --help | grep -- --effort\`, \`grep -n\`, actual bash tests)
- Returns a decision proposal per finding with its verification evidence

This parallelizes the most expensive phase (each verifier may need several bash probes); subagents run concurrently whereas inline verification would be sequential.

The main agent then writes ledger entries serially (append-order matters). Apply these gates:

- **Severity gate:** only CRITICAL and IMPORTANT findings are candidates. Append minors verbatim to \`.committee-loop-DEFERRED.md\`.
- **Quorum gate:** apply if (a) two or more reviewers flagged substantively the same issue, OR (b) a single reviewer flagged it AND the verifier's probe confirmed the claim. In iteration 1 (only 2 reviewers), "two or more" means unanimous, so single-reviewer claims MUST have a passing verification probe to apply.
- **Ledger check:** read \`.committee-loop-decisions.md\` if it exists. If this finding (or its inverse) was previously decided, you may NOT reverse that decision without new evidence of equal or greater weight — a new verification probe whose output contradicts the prior one. A different reviewer's opinion is not new evidence.

Append one entry per Critical/Important finding regardless of outcome:

\`\`\`
## <iteration>-<reviewer>-<short-id>
- **Severity:** critical | important
- **Claim:** <one-line summary>
- **Verification:** <command run> -> <outcome>
- **Decision:** applied | rejected | deferred
- **Rationale:** <why>
\`\`\`

### 4. Apply sequentially

Same-file edits cannot be parallelized safely. Apply "applied" findings one at a time with the SMALLEST edit that addresses each. Commit with a message naming finding IDs: \`fix iter-<N>: apply <id1>, <id2>, ...\`.

### 5. Post-script sync (mandatory if Step 5 of the target changed)

\`.committee-loop-post.sh\` was generated at spawn time. If your fix edits SKILL.md's Step 5 (the POST_SCRIPT template / \`<<'BODY'\` region), the on-disk post.sh still has the pre-fix logic. After any such fix, apply the equivalent edit directly to \`.committee-loop-post.sh\`, include it in the same commit, and note the sync in the ledger entry.

Detection: \`git diff HEAD~1 -- <TARGET>\` shows changes in the POST_SCRIPT/BODY region.

### 6. Convergence exit

- **Would-be reversal:** if a new iteration's fixes would REVERSE any prior-iteration change, write \`.committee-loop-CONVERGED.txt\` naming the oscillator, run post.sh, emit \`<promise>REVIEW CLEAN</promise>\`.
- **Re-flagged-rejected only:** if the run only re-flags findings already ledgered as rejected, write \`.committee-loop-CONVERGED.txt\` naming the re-flag(s), run post.sh, emit \`<promise>REVIEW CLEAN</promise>\`.
- **Zero Critical+Important:** run post.sh, emit \`<promise>REVIEW CLEAN</promise>\` (no CONVERGED.txt).

## Scope

DO NOT fix or modify ANY files other than the target(s) above and these sidecars: \`.committee-loop-decisions.md\`, \`.committee-loop-DEFERRED.md\`, \`.committee-loop-CONVERGED.txt\`, \`.committee-loop-EXHAUSTED.txt\`, \`.committee-loop-post.sh\` (only when Post-script sync applies). NO implementation work in this session.
EOF

# The ralph-loop argument must be bash-safe because the ralph-loop slash-command template
# substitutes $ARGUMENTS UNQUOTED. No backticks, no parens, no $, no quotes. Keep it short
# and point at the instructions file for the actual rules.
RALPH_PROMPT="Read .committee-loop-instructions.md and follow it exactly. Review the target files named in that file using the phase-based workflow described, then iterate per the instructions until you emit the REVIEW CLEAN promise."
RALPH_INVOCATION="/ralph-loop:ralph-loop \"$RALPH_PROMPT\" --completion-promise \"REVIEW CLEAN\" --max-iterations 3"
```

ralph-loop's stop-hook compares the extracted `<promise>` text to `--completion-promise` by **exact equality** (not substring). That's why the instructions above tell the inner agent to emit `<promise>REVIEW CLEAN</promise>` in BOTH the clean and converged cases, and to carry the convergence reason in a `.committee-loop-CONVERGED.txt` sidecar — a `<promise>REVIEW CONVERGED</promise>` would not release the loop.

### 5. Build the post-review script and wrapper prompt

```bash
POST_SCRIPT="$WORKTREE_PATH/.committee-loop-post.sh"

{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'ORIGIN_PATH=%q\n' "$ORIGIN_PATH"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'BRANCH=%q\n' "$BRANCH"
  printf 'SESSION=%q\n' "$SESSION"
  printf 'TARGET_FILES=('
  printf ' %q' "${TARGET_FILES[@]}"
  printf ' )\n'
  printf 'SEED_HASHES=('
  printf ' %q' "${SEED_HASHES[@]}"
  printf ' )\n'
} > "$POST_SCRIPT"

cat >> "$POST_SCRIPT" <<'BODY'

cd "$WORKTREE_PATH"

# --git-common-dir (not ".git") because origin may itself be a linked worktree
# where .git is a file pointing to the real gitdir. --path-format=absolute
# (git 2.31+) forces an absolute path — without it, `rev-parse --git-common-dir`
# returns the relative string ".git", which breaks `mkdir -p "$ART_DIR"` below
# because our cwd is $WORKTREE_PATH where .git is a file, not a directory.
ORIGIN_GIT_DIR=$(git -C "$ORIGIN_PATH" rev-parse --path-format=absolute --git-common-dir)

# Merged validate-then-write loop: separate validate/write loops leave a TOCTOU
# window where a concurrent mutation (e.g. parent-dir symlink swap) can race
# through. Doing the write immediately after per-file validation shrinks the
# window to microseconds. A fully atomic solution isn't possible in pure bash.
#
# Partial-write safety (multi-target): track which targets were successfully
# written. On block, `break` instead of `exit 0`, then commit whatever made it
# with a (PARTIAL) note so origin is never left with uncommitted changes.
declare -a WRITTEN=()
BLOCK_MSG=""
for i in "${!TARGET_FILES[@]}"; do
  expected="${SEED_HASHES[$i]}"
  rel="${TARGET_FILES[$i]}"
  dest="$ORIGIN_PATH/$rel"
  if [ ! -f "$dest" ]; then
    BLOCK_MSG=$(printf 'origin target %s no longer exists; refusing to overwrite\n' "$rel"); break
  fi
  # Re-validate symlink + containment at copy-back time. Without this, a swap
  # of the origin target into a symlink during the detached run would let
  # sha256sum (which follows symlinks) + cp (which writes through dest symlinks)
  # overwrite a file outside the repo under --dangerously-skip-permissions.
  if [ -L "$dest" ]; then
    BLOCK_MSG=$(printf 'origin target %s became a symlink during the review; refusing to overwrite\n' "$rel"); break
  fi
  ABS=$(realpath -e -- "$dest" 2>/dev/null || true)
  if [ -z "$ABS" ]; then
    BLOCK_MSG=$(printf 'origin target %s could not be resolved by realpath; refusing to overwrite\n' "$rel"); break
  fi
  case "$ABS" in
    "$ORIGIN_PATH"/*) ;;
    *)
      BLOCK_MSG=$(printf 'origin target %s resolves outside origin (%s); refusing to overwrite\n' "$rel" "$ABS"); break ;;
  esac
  current=$(sha256sum "$dest" | awk '{print $1}')
  [ -n "$current" ] || { echo "sha256sum failed for $dest"; exit 1; }
  if [ "$expected" != "$current" ]; then
    BLOCK_MSG=$(printf 'origin target %s changed during the review; refusing to overwrite\n' "$rel"); break
  fi
  # Validate the worktree source BEFORE removing origin. Without this check,
  # a missing/unreadable/became-a-symlink source makes rm -f remove origin,
  # then cp -P fails under set -e — destructive partial state.
  if [ ! -f "$rel" ] || [ -L "$rel" ]; then
    BLOCK_MSG=$(printf 'worktree source %s missing or is a symlink; refusing to overwrite origin\n' "$rel"); break
  fi
  # Worktree-source containment check. `[ -L "$rel" ]` above only catches a
  # symlink at the LEAF; a parent-dir swap (e.g. `sub/` replaced with a symlink
  # to `/tmp/evil` during the run) passes the leaf check but `cp -P -- "$rel"`
  # would then read through the symlinked parent. Resolving with realpath and
  # requiring the result stay under $WORKTREE_PATH closes the directory-
  # component TOCTOU under --dangerously-skip-permissions.
  SRC_ABS=$(realpath -e -- "$rel" 2>/dev/null || true)
  if [ -z "$SRC_ABS" ]; then
    BLOCK_MSG=$(printf 'worktree source %s could not be resolved by realpath; refusing to overwrite\n' "$rel"); break
  fi
  case "$SRC_ABS" in
    "$WORKTREE_PATH"/*) ;;
    *)
      BLOCK_MSG=$(printf 'worktree source %s resolves outside worktree (%s); refusing to overwrite\n' "$rel" "$SRC_ABS"); break ;;
  esac
  # rm -f before cp so cp can't be tricked into writing through a destination
  # symlink that appeared between the check above and the write below.
  rm -f -- "$dest"
  cp -P -- "$rel" "$dest"
  WRITTEN+=( "$rel" )
done

if [ -n "$BLOCK_MSG" ]; then
  printf '%s' "$BLOCK_MSG" > .committee-loop-BLOCKED.txt
  [ "${#WRITTEN[@]}" -gt 0 ] && printf 'partially written (committed separately): %s\n' "${WRITTEN[*]}" >> .committee-loop-BLOCKED.txt
  # Echo to stderr so the block reason is visible via `tmux capture-pane`
  # without requiring the user to ls into the preserved worktree.
  echo "BLOCKED: $BLOCK_MSG" >&2
fi

# Commit whatever WAS written — even on partial block. Leaving origin dirty
# with uncommitted changes is worse than a "(PARTIAL)" commit the user can
# see and decide to revert.
if [ "${#WRITTEN[@]}" -gt 0 ]; then
  git -C "$ORIGIN_PATH" add -- "${WRITTEN[@]}"
  if ! git -C "$ORIGIN_PATH" diff --cached --quiet -- "${WRITTEN[@]}"; then
    COMMIT_NOTE="review: apply committee-loop review to ${WRITTEN[*]}"
    if [ -n "$BLOCK_MSG" ]; then
      COMMIT_NOTE="${COMMIT_NOTE} (PARTIAL — see .committee-loop-BLOCKED.txt)"
    elif [ -f .committee-loop-CONVERGED.txt ]; then
      # Surface the convergence-by-give-up case in git log so a reader can tell
      # a truly clean review apart from one that stopped to avoid oscillation.
      COMMIT_NOTE="${COMMIT_NOTE} (CONVERGED)"
    fi
    git -C "$ORIGIN_PATH" commit -m "$COMMIT_NOTE" -- "${WRITTEN[@]}"
  fi
fi

# On block, preserve the worktree+branch+session so the user can inspect
# BLOCKED.txt and decide how to resolve. DONE sentinel + artifact dir + teardown
# are only written on clean (or converged) completion.
if [ -n "$BLOCK_MSG" ]; then
  exit 0
fi

# Nest artifacts under a per-session subdirectory so concurrent or sequential
# runs in the same repo don't overwrite each other's audit trail.
ART_DIR="$ORIGIN_GIT_DIR/committee-loop/$SESSION"
mkdir -p "$ART_DIR"
git -C "$ORIGIN_PATH" rev-parse HEAD > "$ART_DIR/DONE"
[ -f .committee-loop-decisions.md ] && cp .committee-loop-decisions.md "$ART_DIR/decisions.md"
[ -f .committee-loop-DEFERRED.md ]  && cp .committee-loop-DEFERRED.md  "$ART_DIR/deferred.md"
[ -f .committee-loop-CONVERGED.txt ] && cp .committee-loop-CONVERGED.txt "$ART_DIR/CONVERGED.txt"

cd "$ORIGIN_PATH"
git worktree remove --force "$WORKTREE_PATH" || true
git branch -D "$BRANCH" || true
tmux kill-session -t "$SESSION" 2>/dev/null || true
BODY
chmod +x "$POST_SCRIPT"

PROMPT_FILE="$WORKTREE_PATH/.committee-loop-prompt.txt"
cat > "$PROMPT_FILE" <<EOF
You are in an isolated worktree at $WORKTREE_PATH. The origin checkout is at $ORIGIN_PATH.

Run the ralph-loop below. The inner loop instructions (in \`.committee-loop-instructions.md\`) handle copy-back and teardown via \`bash .committee-loop-post.sh\` — do not run post.sh yourself.

If ralph-loop exhausts its iteration limit without emitting a promise, write \`.committee-loop-EXHAUSTED.txt\` in this worktree summarizing the last iteration's outstanding findings so the user has a signal other than a stale tmux session.

The ralph-loop instructions embed review-feedback discipline (receiving-code-review, verify claims, decision ledger, quorum + severity gates, convergence exit). Follow them literally — skipping the verification or ledger steps is the failure mode this skill exists to prevent.

Now run the review loop:
EOF
printf '\n%s\n' "$RALPH_INVOCATION" >> "$PROMPT_FILE"
```

### 6. Spawn the detached session

```bash
# -x/-y are required: a detached tmux session with no client attached defaults to a terminal
# size too small for Claude's TUI to render (the pane stays blank, readiness never triggers).
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKTREE_PATH" "claude --dangerously-skip-permissions --effort max"

READY=false
TRUST_DISMISSED=false
for _ in $(seq 1 30); do
  PANE=$(tmux capture-pane -t "$SESSION" -p)
  if echo "$PANE" | grep -qF 'bypass permissions on'; then
    READY=true; break
  fi
  # Claude Code shows a folder-trust prompt for unknown directories BEFORE entering the main
  # TUI — even under --dangerously-skip-permissions. The cursor (❯) is pre-positioned on
  # "Yes, I trust this folder", so a bare Enter confirms. Auto-answer once, then keep polling
  # for the main TUI footer.
  if ! $TRUST_DISMISSED && echo "$PANE" | grep -qF 'Yes, I trust this folder'; then
    tmux send-keys -t "$SESSION" Enter
    TRUST_DISMISSED=true
  fi
  sleep 1
done
if ! $READY; then
  echo "error: Claude input box did not render within 30s; aborting" >&2
  # Dump captured pane so a TUI footer-wording change (or unexpected prompt) is
  # diagnosable without attaching to a killed tmux session.
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

# Bracketed paste (-p) so multi-line content is delivered atomically. Without it tmux
# converts LF to CR, which in a TUI submits line-by-line and fragments the prompt.
tmux load-buffer -b "$SESSION" "$PROMPT_FILE"
tmux paste-buffer -p -t "$SESSION" -b "$SESSION"
tmux delete-buffer -b "$SESSION"

# Claude Code's TUI stages a bracketed paste as `[Pasted text #N +M lines]` and does not
# submit on the same keystroke that ends the paste. Poll until the staged indicator
# appears, then send Enter, and re-send if the indicator is still visible.
for _ in $(seq 1 10); do
  tmux capture-pane -t "$SESSION" -p | grep -qE '\[Pasted text' && break
  sleep 1
done
for _ in $(seq 1 5); do
  tmux send-keys -t "$SESSION" Enter
  sleep 2
  tmux capture-pane -t "$SESSION" -p | grep -qE '\[Pasted text' || break
done
```

Notes:
- `--dangerously-skip-permissions` suppresses the agent's permission prompts so it can run unattended. It does NOT sandbox — scope is enforced by the ralph-loop prompt's "DO NOT fix or modify ANY files other than $TARGET_JOINED" clause.
- `--effort max` is supported (`claude --help | grep -- --effort`) and materially improves the loop agent's discipline around the ledger/verification steps.

### 7. Report to user

```
Committee loop spawned.
- Session:  <SESSION>
- Worktree: <WORKTREE_PATH>
- Branch:   <BRANCH>
- Target:   <TARGET_FILES joined with ", ">

Monitor:  tmux attach -t <SESSION>      (Ctrl-b d to detach)
Peek:     tmux capture-pane -t <SESSION> -p | tail -40
Cancel:   tmux kill-session -t <SESSION> && git worktree remove --force <WORKTREE_PATH> && git branch -D <BRANCH>

Outcomes (artifacts land under <ORIGIN_GIT_DIR>/committee-loop/<SESSION>/ — per-session so runs don't collide):
- REVIEW CLEAN                 -> post-script copies back, commits, writes <ORIGIN_GIT_DIR>/committee-loop/<SESSION>/DONE, tears down.
- REVIEW CLEAN + CONVERGED.txt -> same as CLEAN, but the sidecar names an oscillating finding; check decisions.md in the same artifact dir.
- .committee-loop-BLOCKED.txt   -> origin target changed/became-a-symlink during review, or a multi-target run blocked after writing some targets.
                                   Any vetted writes ARE committed to origin (marked "(PARTIAL)"); worktree preserved at <WORKTREE_PATH> for inspection.
                                   After resolving, run the Cancel command above to tear down.
- .committee-loop-EXHAUSTED.txt -> ran out of ralph iterations without emitting the promise; no copy-back, worktree preserved at <WORKTREE_PATH>.
                                   No outer watchdog monitors this — inspect and run the Cancel command above to tear down, or stale tmux sessions accumulate.
```

Do not wait for the session to finish.

## Red Flags

- About to run `/ralph-loop:ralph-loop` in the current session → STOP, spawn detached
- About to apply a finding without logging it in `.committee-loop-decisions.md` → STOP, log first
- About to reverse a prior iteration's fix because a *different* reviewer complained → STOP, that's not new evidence
- About to edit for a Minor finding → STOP, route to deferred file
- About to skip the verification command for a single-reviewer Critical → STOP, verify or reject
- About to edit any file other than the target(s) or the ledger sidecars → STOP, scope is load-bearing
- About to block waiting for the tmux session to finish → STOP, this is fire-and-forget
