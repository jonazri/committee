---
name: committee-loop
description: Use when iteratively reviewing and refining a spec, plan, design doc, or file with /committee until zero critical and important issues remain. Triggers on "/committee-loop", "committee loop", "review until clean", "iterate committee review", "keep reviewing until no issues".
---

# Committee Loop

## Overview

Spawn a detached Claude Code session in an isolated worktree that runs `/ralph-loop:ralph-loop` with `/committee` as the review task. Inside each iteration the loop agent verifies each finding, applies only vetted critical/important ones, maintains a decision ledger to prevent thrashing, and stops when the review is clean or when it starts reversing its own prior fixes.

The invoking session stays the coordinator via a background status watcher: after the detached session is running, the skill launches a second shell (Bash tool with `run_in_background: true`) that polls the sentinel files and exits with a one-line classification. The harness surfaces that exit as a notification to the invoker, so the invoker can report completion to the user without requiring the user to poll.

**Core principle:** Unattended review-and-refine loop in an isolated workspace, with reviewer-feedback discipline applied **inside** the loop so findings are vetted, not blindly implemented. The invoker coordinates via a passive background watcher, not active polling.

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

for t in tmux claude git realpath sha256sum kiro-cli codex gemini; do
  command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 1; }
done

# realpath usage below (Step 1 + post-script) relies on GNU `-e`; BSD realpath
# (default macOS) does not support it. Behavior probe (not help-text parse) so
# wording changes across coreutils versions can't break it.
realpath -e -- . >/dev/null 2>&1 \
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

# The workflow depends on installed skills/plugins. Only check the ones that
# reliably show up as directories under ~/.claude or $ORIGIN_PATH/.claude:
# ralph-loop (plugin dir), committee (skill dir), superpowers:receiving-code-review
# (skill dir). `simplify` and `superpowers:code-reviewer` are NOT checked here:
# the former is registered via a harness-level mechanism and doesn't appear as a
# findable dir; the latter exists only as agent `.md` files (agents/code-reviewer.md)
# in the superpowers plugin layout, not as a directory. If those dependencies are
# missing at runtime, the inner Agent/Skill call surfaces the specific error itself.
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
  echo "$label not found under ~/.claude or $ORIGIN_PATH/.claude; install it before running committee-loop"
  exit 1
}
check_skill_or_plugin "ralph-loop plugin"                       "ralph-loop"
check_skill_or_plugin "committee skill"                         "committee"
check_skill_or_plugin "superpowers:receiving-code-review skill" "receiving-code-review"

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
  mkdir -p "$WORKTREE_PATH/$(dirname -- "$f")"
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

**Never emit \`<promise>REVIEW CLEAN</promise>\` if \`.committee-loop-BLOCKED.txt\` exists in the worktree after post.sh returns.** post.sh exits 0 on BLOCKED so the shell return code alone does not signal failure; the sidecar is the signal. On BLOCKED, do NOT emit the promise — let ralph-loop terminate naturally via iteration exhaustion (the watcher will report BLOCKED to the invoker).

## Per-iteration workflow

Each iteration runs these steps in order.

### 1. Simplify pre-pass (iter-1 only, overlapped with reviewers)

Simplify also runs at convergence exit as an end-pass (see section 6). SKIP this step on iterations 2+ — after iter-1 cleans up newly-written-code noise, the committee reviewers cover any remaining simplification opportunities as Minor findings.

For iter-1: dispatch \`simplify\` CONCURRENTLY with the reviewers in section 2 (not before them). All four — simplify, Claude, Kiro, Codex — run in parallel against the original baseline. Simplify's 3 sub-agents average ~9m; reviewers average 3-8m; wall-time is bounded by the slowest of the four, not by their sum.

When simplify returns, apply any non-contentious fixes and commit as \`simplify iter-1: <brief summary>\` BEFORE the \`fix iter-1\` commit, so the ledger and \`git diff HEAD~1\` references resolve correctly. If simplify returns nothing, commit nothing and move on.

**De-duplication:** reviewers running in parallel may flag issues simplify has already fixed by the time verifiers run. Verifiers in section 3 probe the current file state — if a claim no longer holds because simplify's commit resolved it, the verifier naturally reports "not present" and the ledger records the finding as "resolved by simplify" (rejection, not application). No special-case logic needed.

### 2. Review

**Iteration 1 — fast-ish mode (Claude + Kiro + Codex, skip Gemini):**

Historical timing data (from the committee-loop self-review, 2026-04-13): per-reviewer averages are Kiro ~3m, Codex ~7m, Gemini ~8m, Claude ~8m30s. Reviewers run in parallel, so wall-time is bounded by the slowest. Skipping Codex saves no wall-time (Codex is faster than Claude on average) but forfeits its correctness-focused findings on the densest-bug iteration. Skipping Gemini saves occasional tail latency (Gemini has the largest variance) AND sidesteps its known reliability issues in this harness.

Dispatch three reviewers in parallel, concurrent with simplify (section 1):

a. \`superpowers:code-reviewer\` subagent with prompt: *"Review <TARGET> for code quality, bugs, design, shell safety. Output a Critical/Important/Minor list with line references and verification commands where possible."*

b. \`kiro-cli chat --no-interactive --trust-tools=fs_read\` with the same prompt against the target file path. Write output to \`.committee-loop-iter1-kiro.txt\`.

c. \`codex exec --skip-git-repo-check --sandbox read-only -o .committee-loop-iter1-codex.txt "Review <TARGET> ..."\` (same prompt).

Do NOT use \`/committee\`; the coordinator's dispatch pattern includes Gemini and its own synthesis. Synthesize the three reports into a single Critical/Important/Minor list yourself.

**Iteration 2+ — full mode:**

Use \`/committee --files <TARGET...>\` (all 4 reviewers, including Gemini) for a thorough subsequent pass. In multi-target runs, pass every entry from \`TARGET_FILES\` as separate space-separated arguments after \`--files\` (the committee skill expects \`--files <path1> [path2...]\`). Gemini's perspective joins once the file is already cleaner from iter-1 fixes, reducing noise.

### 3. Classify with verifier dispatch

**Per-iteration dispatch model:**
- **Iter-1 (direct dispatch):** three reviewers run in parallel, each with its own completion signal. Streaming verifier dispatch (below) applies.
- **Iter-2+ / final pass (\`/committee\` synthesis):** one synthesized report is returned. Dispatch a single verifier over it — no streaming needed.

In iter-1, the three reviewers (Claude subagent, Kiro background Bash, Codex background Bash) each have their own completion signal: the Agent tool returns when the subagent finishes, and background Bash calls fire a \`<task-notification>\` when the process exits (exit code + output file both final at that point — there is no partial-write window). Those completion signals ARE the "output ready" marker; no \`.done\` sentinel is needed.

Do NOT wait for ALL reviewers to finish before dispatching verifiers. As each reviewer's completion signal fires, IMMEDIATELY dispatch that reviewer's verifier subagent in parallel to any still-running reviewers and any in-flight verifiers. This overlaps verification with the tail-latency reviewer and saves 3-7 minutes per iteration.

Concrete pattern: maintain a pending-reviewers set. On each reviewer completion (Agent return OR task-notification), remove it from pending and dispatch its verifier. Continue until pending is empty AND all dispatched verifiers have returned.

Each verifier:
- Reads its reviewer's report
- Runs verification commands for each Critical/Important claim it contains (e.g. \`claude --help | grep -- --effort\`, \`grep -n\`, actual bash tests)
- Returns a decision proposal per finding with its verification evidence

The main agent then writes ledger entries serially once all verifiers return (append-order matters). Apply these gates:

- **Severity gate:** only CRITICAL and IMPORTANT findings are candidates. Append minors verbatim to \`.committee-loop-DEFERRED.md\`.
- **Quorum gate:** apply if (a) two or more reviewers flagged substantively the same issue, OR (b) a single reviewer flagged it AND the verifier's probe confirmed the claim. In iteration 1 (3 reviewers: Claude+Kiro+Codex), "two or more" means any 2-of-3 agreement; single-reviewer claims still require a passing verification probe to apply.
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

### 5. Generated-file sync (mandatory for self-review)

This only matters when the committee-loop reviews ITSELF. For normal use (reviewing other files), the generated files are spawned fresh from the current SKILL.md and no sync is needed.

Several runtime files are generated from SKILL.md at spawn time: \`.committee-loop-post.sh\` (Step 5 BODY), \`.committee-loop-watcher.sh\` (Step 5 WATCHER region), \`.committee-loop-instructions.md\` (Step 4 heredoc), and \`.committee-loop-prompt.txt\` (Step 5 tail). If your fix edits SKILL.md's corresponding region, the on-disk file still has the pre-fix logic. Apply the equivalent edit directly to the affected file(s) in the same commit.

- SKILL.md Step 5 BODY (\`<<'BODY'\`) → \`.committee-loop-post.sh\`
- SKILL.md Step 5 WATCHER region → \`.committee-loop-watcher.sh\`
- SKILL.md Step 4 heredoc (\`<<EOF\`) → \`.committee-loop-instructions.md\` (but note: the inner agent is typically running from conversational context by this point, so this sync is primarily about future-restart consistency)
- SKILL.md Step 5 prompt region → \`.committee-loop-prompt.txt\` (only affects re-paste; usually moot after spawn)

Detection: \`git diff HEAD~1 -- <TARGET>\` shows changes in any of the generator regions above. Post.sh sync is the most critical because post.sh actually runs at copy-back time.

### 6. Convergence exit

Entry conditions (any one triggers the exit protocol below):

- **Zero Critical+Important:** committee returned nothing actionable this iteration. No \`.committee-loop-CONVERGED.txt\`.
- **Would-be reversal:** a new iteration's fixes would REVERSE any prior-iteration change. Write \`.committee-loop-CONVERGED.txt\` naming the oscillator.
- **Re-flagged-rejected only:** this iteration only re-flags findings already ledgered as rejected. Write \`.committee-loop-CONVERGED.txt\` naming the re-flag(s).

**End-simplify + final-pass protocol (runs AT MOST ONCE per session):**

This is the "end" half of the "simplify at beginning and end" design. Simplify potentially changes the file; a final full committee pass verifies the result is still clean.

Use \`.committee-loop-FINAL-PASS-DONE\` as a single-shot flag. If it already exists, skip to the emit step.

1. Run \`simplify\` on the target (same workflow as iter-1's simplify). Apply any non-contentious fixes, commit as \`simplify final: <summary>\`. If nothing, no commit.
2. Run a full committee pass (all 4 reviewers — Gemini included this time) using the same section-2/section-3/section-4 workflow (verifier dispatch per section 3, quorum + severity + ledger gates, sequential apply). Commit any applied fixes as \`fix final: ...\`.
3. Run \`bash .committee-loop-post.sh\`.
4. Create \`.committee-loop-FINAL-PASS-DONE\` (empty marker) AFTER post.sh returns. The flag only matters on the BLOCKED path: if post.sh blocked, the worktree+tmux session survive and ralph-loop may re-feed the prompt; the flag then suppresses a redundant re-entry into the final-pass protocol. On the CLEAN path, post.sh tears down the worktree + tmux session itself, so step 4 never actually executes and ralph has no re-feed target — the flag is moot. The ordering (AFTER post.sh) is the safe default: a crash between post.sh and flag-creation simply re-runs the final pass, which will see the same (already-committed or BLOCKED) state and behave consistently. The inverse ordering would let a crash between flag-creation and post.sh make a later restart skip copy-back entirely.
5. If \`.committee-loop-BLOCKED.txt\` now exists, STOP — do NOT emit the promise. Otherwise emit \`<promise>REVIEW CLEAN</promise>\`.

The final pass is a safety net, not a regular iteration — whatever it applies (or rejects) is trusted on the same gates as any other iteration's findings, and the session ends after step 5 regardless of what the final pass surfaces. The ledger captures all findings for post-mortem inspection.

## Scope

DO NOT fix or modify ANY files other than the target(s) above and the loop's own sidecar files (anything matching \`.committee-loop-*\` at the worktree root: reviewer output files like \`.committee-loop-iter<N>-<reviewer>.txt\`, the decision ledger \`.committee-loop-decisions.md\`, the deferred list \`.committee-loop-DEFERRED.md\`, the convergence/exhaustion/block sentinels, \`.committee-loop-FINAL-PASS-DONE\`, and \`.committee-loop-post.sh\` — the last one ONLY when Post-script sync applies). NO implementation work in this session.
EOF

# The ralph-loop argument must be bash-safe because the ralph-loop slash-command template
# substitutes $ARGUMENTS UNQUOTED. No backticks, no parens, no $, no quotes. Keep it short
# and point at the instructions file for the actual rules.
RALPH_PROMPT="Read .committee-loop-instructions.md and follow it exactly. Review the target files named in that file using the phase-based workflow described, then iterate per the instructions until you emit the REVIEW CLEAN promise."
RALPH_INVOCATION="/ralph-loop:ralph-loop \"$RALPH_PROMPT\" --completion-promise \"REVIEW CLEAN\" --max-iterations 10"
```

ralph-loop's stop-hook compares the extracted `<promise>` text to `--completion-promise` by **exact equality** (not substring). That's why the instructions above tell the inner agent to emit `<promise>REVIEW CLEAN</promise>` in BOTH the clean and converged cases, and to carry the convergence reason in a `.committee-loop-CONVERGED.txt` sidecar — a `<promise>REVIEW CONVERGED</promise>` would not release the loop.

### 5. Build the post-review script and wrapper prompt

```bash
POST_SCRIPT="$WORKTREE_PATH/.committee-loop-post.sh"

# Capture origin's branch at spawn time. post.sh re-checks this before copy-back
# so a user `git switch`'ing the origin checkout during the detached run can't
# cause the review commit to land on the wrong branch (even if content happens
# to hash-match because of an identical file on the new branch).
ORIGIN_REF=$(git -C "$ORIGIN_PATH" rev-parse --abbrev-ref HEAD)
# HEAD detached at spawn ("HEAD") is rejected rather than silently accepted:
# without a branch name, copy-back would commit to detached HEAD and the commit
# would be invisible from any branch.
[ "$ORIGIN_REF" != "HEAD" ] \
  || { echo "origin is on detached HEAD; committee-loop requires a named branch so copy-back lands where the user expects"; exit 1; }

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

cat >> "$POST_SCRIPT" <<'BODY'

# Signal-safe TMP cleanup for the atomic cp-to-tmp + mv -f replace below.
# Without this trap, SIGTERM between `cp -P "$rel" "$TMP"` and `mv -f "$TMP" "$dest"`
# leaks a `.committee-loop.$$.tmp` file in origin's target directory.
# Two traps: EXIT for cleanup-only on natural exit; INT/TERM/HUP also TERMINATE
# via `exit 130` so a trapped signal stops post.sh rather than letting it
# continue through copy-back + commit after the handler returns (bash's default
# is to continue after a custom signal handler returns).
TMP=""
cleanup_tmp() {
  [ -n "${TMP:-}" ] && rm -f -- "$TMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT
trap 'cleanup_tmp; exit 130' INT TERM HUP

cd "$WORKTREE_PATH"

# --git-common-dir (not ".git") because origin may itself be a linked worktree
# where .git is a file pointing to the real gitdir. --path-format=absolute
# (git 2.31+) forces an absolute path — without it, `rev-parse --git-common-dir`
# returns the relative string ".git", which breaks `mkdir -p "$ART_DIR"` below
# because our cwd is $WORKTREE_PATH where .git is a file, not a directory.
ORIGIN_GIT_DIR=$(git -C "$ORIGIN_PATH" rev-parse --path-format=absolute --git-common-dir)

# Refuse copy-back if origin's branch has moved since spawn. Without this,
# a user who `git switch`'d origin during the detached run would get the
# review commit on the new branch (bytes may hash-match because the same file
# exists on the new branch). "HEAD" means origin is in detached state now —
# also refuse. `|| true` on rev-parse so a transient git failure goes to the
# explicit BLOCKED path below rather than tripping set -e silently.
CURRENT_ORIGIN_REF=$(git -C "$ORIGIN_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ "$CURRENT_ORIGIN_REF" != "$ORIGIN_REF" ]; then
  printf 'origin branch changed during the review: was %s, now %s; refusing to copy back\n' "$ORIGIN_REF" "$CURRENT_ORIGIN_REF" > .committee-loop-BLOCKED.txt
  echo "BLOCKED: origin branch changed ($ORIGIN_REF -> $CURRENT_ORIGIN_REF)" >&2
  exit 0
fi

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
  # Atomic replace: cp to sibling tmp, then mv into place. Avoids the destructive
  # window of `rm then cp` — if cp fails (EIO, EDQUOT, disk-full, perms race) the
  # dest stays intact and BLOCK_MSG fires. `.$$` suffix is unique per post.sh
  # process; explicit rm -f on the failure branches + the EXIT/INT/TERM trap above
  # clean up the tmp file under command failure AND under signal.
  TMP="$dest.committee-loop.$$.tmp"
  rm -f -- "$TMP"
  if ! cp -P -- "$rel" "$TMP"; then
    rm -f -- "$TMP"
    BLOCK_MSG=$(printf 'cp of worktree source %s to tmp failed; origin unchanged\n' "$rel"); break
  fi
  # mv -f overwrites dest atomically (rename(2) on same filesystem). If dest
  # is itself a symlink, rename replaces the symlink — which is what we want,
  # since the earlier `[ -L "$dest" ]` check already rejected symlinks.
  if ! mv -f -- "$TMP" "$dest"; then
    rm -f -- "$TMP"
    BLOCK_MSG=$(printf 'atomic mv of %s into origin failed; origin unchanged\n' "$rel"); break
  fi
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
  # Re-check origin branch right before commit. The initial branch check runs
  # before the validation+copy loop, which takes time — a user `git switch`'ing
  # origin during that window would see our commit land on the current
  # (changed) branch. `mv -f` in the loop has ALREADY written reviewed bytes
  # to origin's working tree, so we CANNOT bail out without leaving origin
  # dirty. Instead: commit anyway with a loud `(BRANCH MOVED)` note so the
  # commit is visible and revertable, and set BLOCK_MSG so the existing
  # exit-0-on-block path skips DONE+teardown.
  REFRESH_ORIGIN_REF=$(git -C "$ORIGIN_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  BRANCH_MOVED=""
  if [ "$REFRESH_ORIGIN_REF" != "$ORIGIN_REF" ]; then
    BRANCH_MOVED="branch moved mid-post.sh from $ORIGIN_REF to $REFRESH_ORIGIN_REF"
    if [ -z "$BLOCK_MSG" ]; then
      BLOCK_MSG="$BRANCH_MOVED"
      printf '%s\n' "$BRANCH_MOVED" > .committee-loop-BLOCKED.txt
    else
      BLOCK_MSG="$BLOCK_MSG; also $BRANCH_MOVED"
      printf '%s\n' "$BRANCH_MOVED" >> .committee-loop-BLOCKED.txt
    fi
    echo "BLOCKED: $BRANCH_MOVED" >&2
  fi
  git -C "$ORIGIN_PATH" add -- "${WRITTEN[@]}"
  if ! git -C "$ORIGIN_PATH" diff --cached --quiet -- "${WRITTEN[@]}"; then
    COMMIT_NOTE="review: apply committee-loop review to ${WRITTEN[*]}"
    if [ -n "$BRANCH_MOVED" ]; then
      COMMIT_NOTE="${COMMIT_NOTE} (BRANCH MOVED — ${BRANCH_MOVED}; commit lands on $REFRESH_ORIGIN_REF)"
    elif [ -n "$BLOCK_MSG" ]; then
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

# Copy sidecars FIRST, write DONE LAST (atomic rename). The watcher's classify
# checks DONE before CONVERGED.txt — if DONE were written before CONVERGED.txt
# is copied, a sweep landing in that window would misreport a converged run as
# plain DONE. Atomic rename ensures DONE appears only when all sidecars are in
# place.
[ -f .committee-loop-decisions.md ] && cp .committee-loop-decisions.md "$ART_DIR/decisions.md"
[ -f .committee-loop-DEFERRED.md ]  && cp .committee-loop-DEFERRED.md  "$ART_DIR/deferred.md"
[ -f .committee-loop-CONVERGED.txt ] && cp .committee-loop-CONVERGED.txt "$ART_DIR/CONVERGED.txt"
git -C "$ORIGIN_PATH" rev-parse HEAD > "$ART_DIR/DONE.tmp"
mv -f -- "$ART_DIR/DONE.tmp" "$ART_DIR/DONE"

cd "$ORIGIN_PATH"
git worktree remove --force "$WORKTREE_PATH" || true
git branch -D "$BRANCH" || true
tmux kill-session -t "$SESSION" 2>/dev/null || true
BODY
chmod +x "$POST_SCRIPT"

# Status watcher. Launched later as a run_in_background Bash call from the
# invoker; the harness notifies Claude when it exits, which becomes the
# "review loop done" callback. Polling is best-effort and bounded to 24h.
# Priority order on each sweep: DONE (clean/converged) > BLOCKED > EXHAUSTED > TMUX_DIED.
# On tmux death without any sentinel, a 2s grace re-sweep covers the race between
# post.sh's final writes and tmux teardown.
WATCHER_SCRIPT="$WORKTREE_PATH/.committee-loop-watcher.sh"
ORIGIN_GIT_DIR=$(git -C "$ORIGIN_PATH" rev-parse --path-format=absolute --git-common-dir)
ART_DIR="$ORIGIN_GIT_DIR/committee-loop/$SESSION"
{
  printf '#!/usr/bin/env bash\nset -u\n'
  printf 'SESSION=%q\n' "$SESSION"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'ART_DIR=%q\n' "$ART_DIR"
} > "$WATCHER_SCRIPT"
cat >> "$WATCHER_SCRIPT" <<'BODY'
classify() {
  if [ -f "$ART_DIR/DONE" ]; then
    if [ -f "$ART_DIR/CONVERGED.txt" ]; then
      echo "CONVERGED:$(cat "$ART_DIR/DONE")"
    else
      echo "DONE:$(cat "$ART_DIR/DONE")"
    fi
    return 0
  fi
  if [ -f "$WORKTREE_PATH/.committee-loop-BLOCKED.txt" ]; then
    echo "BLOCKED:$(head -1 "$WORKTREE_PATH/.committee-loop-BLOCKED.txt")"
    return 0
  fi
  if [ -f "$WORKTREE_PATH/.committee-loop-EXHAUSTED.txt" ]; then
    echo "EXHAUSTED"
    return 0
  fi
  return 1
}
end=$(( $(date +%s) + 86400 ))
while [ "$(date +%s)" -lt "$end" ]; do
  classify && exit 0
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    sleep 2
    classify && exit 0
    echo "TMUX_DIED"; exit 0
  fi
  sleep 15
done
echo "TIMEOUT"
BODY
chmod +x "$WATCHER_SCRIPT"

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
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKTREE_PATH" "claude --dangerously-skip-permissions --effort high"

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

# Protected-paths watchdog. Claude Code prompts on `.claude/` edits even under
# --dangerously-skip-permissions (claude-code#35718). Detached agent can't answer
# interactively — poll from outside and pick option 2 (session-scoped). 12h cap
# guards against a leaked watchdog; exits when tmux session dies.
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

# Emit a manifest on stdout so Step 7 (watcher) and Step 8 (user report) — which
# run in SEPARATE Bash tool calls that do NOT inherit these variables — can
# recover the values. Also write a file copy inside the worktree so an operator
# who loses the tool output can still reconstruct the session state later.
# %q shell-escapes each value so the manifest is safely sourceable even when
# paths contain spaces or shell metacharacters (matches the post.sh header
# pattern above).
ORIGIN_GIT_DIR=$(git -C "$ORIGIN_PATH" rev-parse --path-format=absolute --git-common-dir)
MANIFEST="$WORKTREE_PATH/.committee-loop-manifest.txt"
{
  printf 'SESSION=%q\n' "$SESSION"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'BRANCH=%q\n' "$BRANCH"
  printf 'ORIGIN_PATH=%q\n' "$ORIGIN_PATH"
  printf 'ORIGIN_REF=%q\n' "$ORIGIN_REF"
  printf 'ORIGIN_GIT_DIR=%q\n' "$ORIGIN_GIT_DIR"
  printf 'WATCHER_SCRIPT=%q\n' "$WATCHER_SCRIPT"
} > "$MANIFEST"
# Print to stdout separately (non-pipeline) so a `tee` failure under pipefail
# can't orphan the live tmux session + watchdog launched above.
cat "$MANIFEST"
```

Notes:
- `--dangerously-skip-permissions` suppresses most permission prompts but does NOT bypass Claude Code's protected-paths guard for writes under `.claude/` (claude-code#35718). The watchdog above handles that case — targets outside `.claude/` never trigger the prompt and the watchdog exits when the session ends. It does NOT sandbox — scope is enforced by the ralph-loop prompt's "DO NOT fix or modify ANY files other than $TARGET_JOINED" clause.
- `--effort high` balances the loop agent's discipline around the ledger/verification steps against total wall-time. `max` is available and supported but its per-turn reasoning cost rarely pays off for single-file reviews; `high` is the sweet spot.

### 7. Install the status watcher

The detached session writes a terminal sentinel (`<ORIGIN_GIT_DIR>/committee-loop/<SESSION>/DONE` on clean, `.committee-loop-BLOCKED.txt` or `.committee-loop-EXHAUSTED.txt` in the worktree on the other paths). The watcher script generated in step 5 polls for those files, exits with a one-line classification when any appears, and the harness surfaces that exit to the invoker session as a background-task-completion notification — that notification IS the callback.

Read `SESSION`, `WORKTREE_PATH`, `BRANCH`, and `ORIGIN_GIT_DIR` from the manifest emitted at the end of Step 6 (either the stdout of that Bash call or `$WORKTREE_PATH/.committee-loop-manifest.txt`). The block's shell variables are NOT inherited by later Bash tool calls, so the manifest is the only persistent source.

Invoke the watcher via a SEPARATE Bash tool call with `run_in_background: true`. Quote the substituted path so repos with spaces in their directory names don't split the command:

```
Bash({
  command: "bash \"<WORKTREE_PATH>/.committee-loop-watcher.sh\"",
  description: "Committee-loop status watcher",
  run_in_background: true
})
```

The call returns a shell ID. Save it. Include it in the user report so the user can kill the watcher (e.g. if they cancel the loop manually). Do NOT synchronously block on the shell — the whole point is that the invoker is free to continue other work until the harness delivers the completion notification.

When the watcher completes, its stdout will be one of:
- `DONE:<sha>` — loop finished clean; commit `<sha>` on origin's branch at spawn time (ORIGIN_REF in the manifest; typically `main` but post.sh refuses to copy back if that branch moved).
- `CONVERGED:<sha>` — finished, but converged to avoid oscillation (see decisions.md in the artifact dir).
- `BLOCKED:<reason>` — origin target changed during review or similar safety block; worktree preserved.
- `EXHAUSTED` — ralph ran out of iterations without emitting the promise; worktree preserved.
- `TMUX_DIED` — tmux died without writing any sentinel (crashed or killed manually).
- `TIMEOUT` — 24h elapsed without a terminal state (leaked watcher self-limiting).

On receiving that notification later, read the line, map it to a user-facing message, and report. This is NOT part of the skill's current invocation — it happens in a future turn of the invoker's conversation.

### 8. Report to user

```
Committee loop spawned.
- Session:  <SESSION>
- Worktree: <WORKTREE_PATH>
- Branch:   <BRANCH>
- Target:   <TARGET_FILES joined with ", ">
- Watcher:  background shell <SHELL_ID> (I'll notify you when it fires)

Monitor:  tmux attach -t <SESSION>      (Ctrl-b d to detach)
Peek:     tmux capture-pane -t <SESSION> -p | tail -40
Cancel:   tmux kill-session -t <SESSION> && git worktree remove --force <WORKTREE_PATH> && git branch -D <BRANCH>

Outcomes (artifacts land under <ORIGIN_GIT_DIR>/committee-loop/<SESSION>/ — per-session so runs don't collide):
- REVIEW CLEAN                 -> post-script copies back, commits, writes <ORIGIN_GIT_DIR>/committee-loop/<SESSION>/DONE, tears down.
- REVIEW CLEAN + CONVERGED.txt -> same as CLEAN, but the sidecar names an oscillating finding; check decisions.md in the same artifact dir.
- .committee-loop-BLOCKED.txt   -> origin target changed/became-a-symlink during review, a multi-target run blocked after writing some targets, or origin's branch moved during the detached run.
                                   Any vetted writes ARE committed to origin (marked "(PARTIAL)" for mid-loop blocks or "(BRANCH MOVED — ...)" for post-copy branch drift); worktree preserved at <WORKTREE_PATH> for inspection.
                                   After resolving, run the Cancel command above to tear down.
- .committee-loop-EXHAUSTED.txt -> ran out of ralph iterations without emitting the promise; no copy-back, worktree preserved at <WORKTREE_PATH>.
                                   Watcher emits EXHAUSTED and exits; inspect and run the Cancel command above to tear down, or stale tmux sessions accumulate.
```

Do not synchronously block on the watcher. The coordination is passive: the harness delivers the completion notification when the watcher exits.

## Red Flags

- About to run `/ralph-loop:ralph-loop` in the current session → STOP, spawn detached
- About to apply a finding without logging it in `.committee-loop-decisions.md` → STOP, log first
- About to reverse a prior iteration's fix because a *different* reviewer complained → STOP, that's not new evidence
- About to edit for a Minor finding → STOP, route to deferred file
- About to skip the verification command for a single-reviewer Critical → STOP, verify or reject
- About to edit any file other than the target(s) or the ledger sidecars → STOP, scope is load-bearing
- About to block waiting for the tmux session or the watcher → STOP, the watcher runs in the background and the harness notifies you when it exits
- About to launch the watcher in the SAME Bash tool call as the spawn block → STOP, the spawn block must complete synchronously; the watcher must be a SEPARATE Bash call with `run_in_background: true`
