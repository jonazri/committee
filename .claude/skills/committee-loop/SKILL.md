---
name: committee-loop
description: Use when iteratively reviewing and refining a spec, plan, design doc, or file with /committee until zero critical and important issues remain. Triggers on "/committee-loop", "committee loop", "review until clean", "iterate committee review", "keep reviewing until no issues".
---

# Committee Loop

Spawn a detached Claude Code session in an isolated worktree that runs `/ralph-loop:ralph-loop` with `/committee` as the review task. The inner agent vets each finding against a quorum + severity + ledger gate and stops when the review is clean OR when it would reverse its own prior fixes. The invoking session coordinates via **two** background shells: a 4.5-minute one-shot health check that confirms the loop is running correctly, and a long-lived watcher whose exit notification is the "loop done" callback.

**Announce at start:** "I'm using the committee-loop skill to spawn a detached review loop in a worktree."

## When to use / not use

<when_to_use>
Use for polishing a spec, plan, or design doc via multiple committee passes — any review target where the first committee pass is likely to surface fixable issues, and you want to walk away and return to a vetted commit.

Do NOT use when: the target needs human judgment on each finding (use `/committee`), you only want a single review (use `/committee`), or `tmux`/`git`/`claude` is not installed.
</when_to_use>

## Red flags — STOP if any apply

<red_flags>
- About to run `/ralph-loop:ralph-loop` in the current session → spawn detached via `spawn.sh` instead
- About to edit any bash inline in SKILL.md or reproduce spawn logic by hand → call `spawn.sh`
- About to synchronously block on the tmux session, watcher, or health check → all run in background; the harness delivers each exit as a notification
- About to tell the user "fire-and-forget", or to exit without (a) launching the watcher + health-check shells AND (b) starting the recurring ~4.5m keep-alive loop (§2b) → this skill ACTIVELY monitors; a stall must be caught within ~4.5 min, not hours
- The argument contains no concrete file path → ask the user which file to review before spawning
</red_flags>

## Invocation

```
/committee-loop <review target description that includes a file path>
```

Example:
```
/committee-loop Review docs/superpowers/specs/2026-04-07-upstream-merge-v1.2.52-design.md
```

The argument MUST include at least one concrete repo-relative file path. If no path is present, stop and ask the user which file to review.

## Workflow

### 1. Spawn the detached session

Parse one or more repo-relative file paths from the user's argument, then call `spawn.sh` with those paths as positional args. Locate the skill dir via a find lookup that works whether the skill is fully installed under `~/.claude/skills/` or only has `SKILL.md` symlinked (common) — in the symlink case, resolve the symlink to find the real dir where `spawn.sh` lives:

```bash
# Resolve repo root explicitly — outer agent's cwd is not guaranteed to be the
# repo root, so a bare `find .claude ...` would miss a repo-installed skill.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
SEARCH_ROOTS=( "$HOME/.claude" )
[ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/.claude" ] && SEARCH_ROOTS+=( "$REPO_ROOT/.claude" )
SKILL_DIR=""
while IFS= read -r candidate; do
  if [ -f "$candidate/spawn.sh" ]; then
    SKILL_DIR="$candidate"; break
  fi
  real=$(readlink -f -- "$candidate/SKILL.md" 2>/dev/null || true)
  if [ -n "$real" ]; then
    real_dir=$(dirname -- "$real")
    [ -f "$real_dir/spawn.sh" ] && { SKILL_DIR="$real_dir"; break; }
  fi
done < <(find "${SEARCH_ROOTS[@]}" -type d -name committee-loop 2>/dev/null)
[ -n "$SKILL_DIR" ] || { echo "committee-loop skill not found (no spawn.sh adjacent to SKILL.md)" >&2; exit 1; }
bash "$SKILL_DIR/spawn.sh" <path1> [<path2> ...]
```

<operator_model_overrides>
If the user's request specifies model choices for this run — e.g. *"only use opus 4.8 with xhigh and gpt 5.5 xhigh"*, *"run codex on xhigh"*, *"skip kiro and gemini"*, *"verify with opus"* — translate that into a JSON config and pass it as `--models '<json>'` (before or among the path args): `bash "$SKILL_DIR/spawn.sh" --models '<json>' <path1> ...`. Schema (every field optional; omit anything not requested):

```json
{
  "innerAgent": { "model": "opus", "effort": "xhigh" },
  "reviewers": {
    "claude":     { "model": "opus", "policy": "pin" },
    "codex":      { "model": "gpt-5.5", "effort": "xhigh" },
    "kiro":       { "enabled": false },
    "gemini":     { "model": "gemini-2.5-pro" },
    "gemini-pro": { "model": "gemini-3.1-pro-preview" }
  },
  "verifier": { "model": "sonnet" }
}
```

Honest capability limits to respect when translating: **effort** is only honorable for `innerAgent.effort` (the orchestrator's `--effort`) and `reviewers.codex.effort` (`model_reasoning_effort`); the in-workflow Claude reviewer, verifiers, and Gemini reviewers expose no per-agent effort knob, so for those set only `model`. `reviewers.claude.policy: "pin"` (the default when a claude model is set) freezes the loop's adaptive iter-3 Sonnet step-down + auto-re-escalation to that model; `"adaptive"` keeps the adaptive logic. Model ids must be `[A-Za-z0-9._-]`; effort levels are lowercase enums (`minimal|low|medium|high|xhigh`); `verifier.model` must be `opus|sonnet|haiku`. `spawn.sh` validates the JSON and fails fast on a bad value. Use `model: "opus"` for "opus 4.8" (the current Opus). If the user gives no model preferences, omit `--models` entirely (committee defaults).
</operator_model_overrides>

`spawn.sh` handles preflight (tool checks, skill checks, realpath/git version probes, git identity), creates a sibling-dir worktree + committee-loop branch, seeds the worktree with the current origin bytes (including uncommitted edits), generates `.committee-loop-post.sh` / `.committee-loop-watcher.sh` / `.committee-loop-health-check.sh` / `.committee-loop-instructions.md` / `.committee-loop-prompt.txt` (and `.committee-loop-models.json` when `--models` is given) in the worktree, spawns the detached `tmux` session running `claude --dangerously-skip-permissions --effort high` (the model/effort overridable via `innerAgent` in `--models`), pastes the ralph-loop prompt, and emits a manifest on stdout.

On any failure between worktree creation and the tmux spawn, `spawn.sh`'s trap unwinds the worktree + branch so nothing leaks.

**Do NOT use the `using-git-worktrees` skill** — it's interactive and runs test baselines we don't need here.

<manifest_format>
The manifest is a newline-separated, %q-escaped list of `KEY=VALUE` pairs. Parse by reading the last `head` lines of stdout (or the file `$WORKTREE_PATH/.committee-loop-manifest.txt`) and extracting these keys: `SESSION`, `WORKTREE_PATH`, `BRANCH`, `ORIGIN_PATH`, `ORIGIN_REF`, `ORIGIN_GIT_DIR`, `WATCHER_SCRIPT`, `HEALTH_CHECK_SCRIPT`, `TARGET_FILES_JOINED`.
</manifest_format>

### 2. Install the status watcher AND the 4.5m health check

Launch BOTH in the same response as two parallel Bash tool calls, each with `run_in_background: true`. The watcher delivers the terminal outcome; the health check delivers a one-shot "still running?" signal at T+4.5m. Both paths are in the manifest (`WATCHER_SCRIPT`, `HEALTH_CHECK_SCRIPT`):

```
Bash({
  command: "bash \"<WATCHER_SCRIPT>\"",
  description: "Committee-loop status watcher",
  run_in_background: true
})
Bash({
  command: "bash \"<HEALTH_CHECK_SCRIPT>\"",
  description: "Committee-loop 4.5m health check",
  run_in_background: true
})
```

Each call returns a shell ID — save both and include in the user report so the user can kill them if they cancel manually. Do NOT synchronously block on either shell; the harness delivers each exit as a notification.

**Then start the recurring 4.5m keep-alive loop — this is DEFAULT, not optional.** The event-driven watcher only fires at the *terminal* state and the health check fires *once* at T+4.5m; neither catches a mid-run auto-continue stall, so a stalled loop could otherwise burn hours unnoticed. So in addition to the two shells: schedule a self-wakeup ~4.5 min out via `ScheduleWakeup` (~270s — keeps the prompt cache warm). On each wakeup, run the §2b check — view the pane, resolve a stall if present — and then, **unless the watcher has already reported a terminal outcome, schedule the next wakeup ~4.5 min from then**; repeat until terminal. This guarantees a stall is caught within ~4.5 min, not hours.

**Health check outcomes (fires at T+4.5m, single notification):**

<health_check_outcomes>
- `HEALTHY` followed by `--- tmux pane (last 40 lines) ---` and a pane dump — loop is still running at 4.5m. Summarize the pane for the user (what iteration, what the agent is currently doing) so they know progress is real.
- `FINISHED_EARLY:DONE` / `FINISHED_EARLY:BLOCKED` / `FINISHED_EARLY:EXHAUSTED` — loop terminated before 4.5m. The watcher will also fire (or already has); the health check just confirms no stall.
- `TMUX_DIED_EARLY` — session is gone at 4.5m with no sentinel. Something went wrong — tell the user and suggest inspecting the worktree (which is preserved). Do NOT tear the watcher down; let it deliver `TMUX_DIED` separately so the user has both signals.
</health_check_outcomes>

**Watcher outcomes (fires whenever the loop reaches a terminal state, typically much later):**

<watcher_outcomes>
- `DONE:<sha>` — loop finished clean; commit `<sha>` on origin's branch at spawn time (`ORIGIN_REF` from the manifest; post.sh refuses to copy back if that branch moved).
- `CONVERGED:<sha>` — finished, but converged to avoid oscillation; see `decisions.md` in the artifact dir.
- `BLOCKED:<reason>` — origin target changed during review, target became a symlink, multi-target run partially blocked, or origin's branch moved. Worktree preserved.
- `EXHAUSTED` — ralph ran out of iterations without emitting the promise; no copy-back, worktree preserved.
- `TMUX_DIED` — tmux died without writing any sentinel (crashed or killed manually).
- `TIMEOUT` — 24h elapsed without a terminal state (leaked watcher self-limiting).
</watcher_outcomes>

On receiving either notification in a future turn, map the line to a user-facing message and report.

### 2b. Keep-alive — detect and recover auto-continue stalls

The 4.5m health check and the terminal watcher are NOT sufficient on their own. The detached ralph loop is supposed to auto-send "continue" to start each next iteration, but on some hosts this **stalls at iteration boundaries**: the word `continue` is typed into the inner prompt and Enter is never submitted, so the inner agent sits idle (an observed stall sat ~3 hours). Between the health check and the terminal signal, **poll and re-nudge**:

- **Cadence:** poll the pane roughly every ~4.5 min (270s — keeps the prompt cache warm) until the watcher fires a terminal outcome. Use the harness's own scheduling (e.g. `ScheduleWakeup`) rather than blocking `sleep`s.
- **Peek:** `tmux -L committee-loop capture-pane -t <SESSION> -p | tail -45`.
- **STALLED** = an idle prompt — `❯ continue`, or an empty `❯ ` with a `← for agents` / `new task? /clear` hint — and **no active spinner**. Corroborate with no recent worktree file activity: `find <WORKTREE_PATH> -type f -not -path '*/.git/*' -newermt '-6 minutes'` returns nothing.
- **RUNNING** = an active spinner line (`…· esc to interrupt`). Iterations legitimately take ~20–25 min (reviewers + verifiers), so a static tail *with* a spinner is normal — judge by spinner + fs activity, not "looks stuck."
- **Recover** (a bare `Enter`/`C-m` does NOT submit — the line must be cleared and retyped):
  ```bash
  tmux -L committee-loop send-keys -t <SESSION> C-u
  sleep 1; tmux -L committee-loop send-keys -t <SESSION> -l "continue"
  sleep 1; tmux -L committee-loop send-keys -t <SESSION> Enter
  ```
  Wait ~10s, re-peek, and confirm a spinner appeared.
- **Exception — the final `Run post.sh?` prompt is a SELECTION MENU, not a text prompt.** There a single `Enter` (selects the highlighted "Yes, run post.sh") is correct — do NOT clear/retype, and do NOT auto-advance it if the user asked to decide on teardown.

Treat committee-loop on a large target as **attended**, not fire-and-forget: expect to nudge at most iteration boundaries.

### 3. Report to user

Use the manifest values to fill in `<placeholders>`:

```
Committee loop spawned.
- Session:       <SESSION>
- Worktree:      <WORKTREE_PATH>
- Branch:        <BRANCH>
- Target:        <TARGET_FILES_JOINED>
- Watcher:       background shell <WATCHER_SHELL_ID> (fires on terminal state, polls every 15s)
- Health check:  background shell <HEALTH_SHELL_ID> (fires once at T+4.5m with a progress snapshot)

I'll check in roughly every 4.5 minutes (recovering the loop if its auto-continue stalls — see §2b) and report again whenever the loop finishes (within ~15s of terminal state).

(committee-loop runs on a private tmux socket for isolation — note the `-L committee-loop`.)
Monitor:  tmux -L committee-loop attach -t <SESSION>      (Ctrl-b d to detach)
Peek:     tmux -L committee-loop capture-pane -t <SESSION> -p | tail -40
Cancel:   tmux -L committee-loop kill-session -t <SESSION> && git worktree remove --force <WORKTREE_PATH> && git branch -D <BRANCH>

Outcomes (artifacts land under <ORIGIN_GIT_DIR>/committee-loop/<SESSION>/):
- REVIEW CLEAN                 -> post.sh copies back, commits, writes DONE, tears down.
- REVIEW CLEAN + CONVERGED.txt -> same as CLEAN, but the sidecar names an oscillating finding; check decisions.md.
- .committee-loop-BLOCKED.txt   -> origin target changed/became-a-symlink during review, a multi-target run blocked mid-loop, origin's branch moved, or origin had unrelated staged index changes that would be swept into the review commit.
                                   Vetted writes ARE committed (marked "(PARTIAL)" or "(BRANCH MOVED)") EXCEPT when the block reason is an index conflict (pre-existing OR concurrent unrelated staged changes): those runs leave reviewed bytes in origin's working tree UNCOMMITTED and the user must resolve the conflicting index state before staging/committing manually. Worktree preserved for inspection either way.
- .committee-loop-EXHAUSTED.txt -> ran out of ralph iterations without emitting the promise; no copy-back, worktree preserved.
```

### 4. After a clean terminal outcome (plan/spec/design targets): offer to finalize for execution

When the watcher reports `DONE:<sha>` or `CONVERGED:<sha>`, post.sh has already copied the reviewed target back to the origin branch. If the target was an **implementation plan / spec / design doc**, **proactively offer the two standard finishing steps below and run them on a yes.** This saves the user from typing the requests each time while keeping a confirmation gate — do NOT edit the plan before they approve. Skip step 4 entirely for arbitrary code-diff reviews; for those, step 3's report ends the workflow.

**Present a recommendation, then ask one yes/no.** Read the committee's deferred ledger at `<ORIGIN_GIT_DIR>/committee-loop/<SESSION>/deferred.md` and triage it. Show the user a short summary: which deferred findings are worth implementing — genuine correctness / robustness / plan-completeness gaps (e.g. a prose-only test step that violates the plan's own no-placeholder/TDD standard, brittle parsing, a missing preflight/guard, a hollow test that doesn't exercise the property it claims) — vs. which to leave as notes (line-ref drift of 1–3 lines, verified-correct hardcoded paths, items the loop already fixed mid-run); plus your intent to add verification gates + an execution preamble. Then ask a single yes/no, e.g. *"Apply these N deferred fixes and make the plan fresh-session-ready?"* **Wait for the answer.**

On **yes**, do both, commit (one focused commit each, scoped to the target file), and report what changed:
- **4a — apply the agreed deferred findings** to the copied-back target on the origin branch.
- **4b — make the plan fresh-session-ready:** weave `superpowers:verification-before-completion` checkpoints in at each key checkpoint (every phase boundary / before each human-gated deploy) AND a final verification at the end (evidence-before-assertions — run the named commands and confirm output before claiming any phase green); and open the plan with a subagent-driven **execution preamble** — driver skill (`superpowers:subagent-driven-development`), task/phase ordering, build/test/deploy commands + runtimes, and links to the context the executor needs (the design/spec doc, the repo's CLAUDE.md gotchas, the deferred ledger).

On **no** (or a partial selection), do only what the user approved — or nothing — and leave the committed-back plan as-is.

## How the pieces fit

<architecture>
- **`spawn.sh`** — outer-agent-invoked orchestrator. Preflight + worktree + seed + file generation + tmux spawn. Emits manifest.
- **`inner-agent.md`** — discipline for the detached Claude inside the worktree: per-iteration workflow, quorum/severity/ledger gates, convergence exit. Copied to `.committee-loop-instructions.md` at spawn.
- **`post-body.sh`** — body of `.committee-loop-post.sh`. Runs at loop completion: validates origin hasn't drifted, atomically copies reviewed bytes back to origin, commits, tears down worktree + tmux.
- **`watcher-body.sh`** — body of `.committee-loop-watcher.sh`. Polls sentinel files every 15s, 24h cap. Exit stdout tells the outer agent how the loop ended.
- **`health-check-body.sh`** — body of `.committee-loop-health-check.sh`. Sleeps 270s (4.5m) then emits a one-shot `HEALTHY` / `FINISHED_EARLY:*` / `TMUX_DIED_EARLY` line so the outer agent can report mid-run progress instead of fire-and-forget.
- **`SKILL.md`** (this file) — what the outer agent reads at `/committee-loop` invocation.
</architecture>

## Notes

- macOS: install `coreutils` (`brew install coreutils`) AND put the gnubin symlinks on PATH so `realpath`, `sha256sum`, `readlink -f`, and `timeout` resolve to the GNU variants (not BSD `readlink` which lacks `-f`, and not a missing `timeout`). Example: `export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$PATH"` in your shell profile. `spawn.sh` preflight probes `timeout` and behavior-probes `realpath -e` so a missing GNU variant fails fast.
- `--dangerously-skip-permissions` does NOT bypass Claude Code's protected-paths guard for writes under `.claude/` (claude-code#35718). `spawn.sh` launches a watchdog that auto-answers that prompt. Targets outside `.claude/` never trigger it. Scope is enforced by the inner-agent instructions, not by sandboxing.
- `--effort high` is the sweet spot for loop-agent discipline vs wall-time; `max` rarely pays off for single-file reviews.
- Each ralph iteration is capped at 10; if the loop doesn't converge within that, the watcher reports `EXHAUSTED` and the worktree is preserved for inspection.
