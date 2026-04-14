---
name: committee-loop
description: Use when iteratively reviewing and refining a spec, plan, design doc, or file with /committee until zero critical and important issues remain. Triggers on "/committee-loop", "committee loop", "review until clean", "iterate committee review", "keep reviewing until no issues".
---

# Committee Loop

Spawn a detached Claude Code session in an isolated worktree that runs `/ralph-loop:ralph-loop` with `/committee` as the review task. The inner agent vets each finding against a quorum + severity + ledger gate and stops when the review is clean OR when it would reverse its own prior fixes. The invoking session coordinates via a background watcher whose exit notification is the "loop done" callback.

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
- About to synchronously block on the tmux session or the watcher → the watcher runs in background; the harness delivers the completion notification
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

`spawn.sh` handles preflight (tool checks, skill checks, realpath/git version probes, git identity), creates a sibling-dir worktree + committee-loop branch, seeds the worktree with the current origin bytes (including uncommitted edits), generates `.committee-loop-post.sh` / `.committee-loop-watcher.sh` / `.committee-loop-instructions.md` / `.committee-loop-prompt.txt` in the worktree, spawns the detached `tmux` session running `claude --dangerously-skip-permissions --effort high`, pastes the ralph-loop prompt, and emits a manifest on stdout.

On any failure between worktree creation and the tmux spawn, `spawn.sh`'s trap unwinds the worktree + branch so nothing leaks.

**Do NOT use the `using-git-worktrees` skill** — it's interactive and runs test baselines we don't need here.

<manifest_format>
The manifest is a newline-separated, %q-escaped list of `KEY=VALUE` pairs. Parse by reading the last `head` lines of stdout (or the file `$WORKTREE_PATH/.committee-loop-manifest.txt`) and extracting these keys: `SESSION`, `WORKTREE_PATH`, `BRANCH`, `ORIGIN_PATH`, `ORIGIN_REF`, `ORIGIN_GIT_DIR`, `WATCHER_SCRIPT`, `TARGET_FILES_JOINED`.
</manifest_format>

### 2. Install the status watcher

Invoke the watcher via a SEPARATE Bash tool call with `run_in_background: true`. The watcher path is in the manifest under `WATCHER_SCRIPT`:

```
Bash({
  command: "bash \"<WATCHER_SCRIPT>\"",
  description: "Committee-loop status watcher",
  run_in_background: true
})
```

The call returns a shell ID — save it and include in the user report so the user can kill the watcher if they cancel manually. Do NOT synchronously block on the shell; the whole point is the invoker is free to continue work until the harness delivers the completion notification.

When the watcher exits later, its stdout will be one of:

<watcher_outcomes>
- `DONE:<sha>` — loop finished clean; commit `<sha>` on origin's branch at spawn time (`ORIGIN_REF` from the manifest; post.sh refuses to copy back if that branch moved).
- `CONVERGED:<sha>` — finished, but converged to avoid oscillation; see `decisions.md` in the artifact dir.
- `BLOCKED:<reason>` — origin target changed during review, target became a symlink, multi-target run partially blocked, or origin's branch moved. Worktree preserved.
- `EXHAUSTED` — ralph ran out of iterations without emitting the promise; no copy-back, worktree preserved.
- `TMUX_DIED` — tmux died without writing any sentinel (crashed or killed manually).
- `TIMEOUT` — 24h elapsed without a terminal state (leaked watcher self-limiting).
</watcher_outcomes>

On receiving the notification in a future turn, map the line to a user-facing message and report.

### 3. Report to user

Use the manifest values to fill in `<placeholders>`:

```
Committee loop spawned.
- Session:  <SESSION>
- Worktree: <WORKTREE_PATH>
- Branch:   <BRANCH>
- Target:   <TARGET_FILES_JOINED>
- Watcher:  background shell <SHELL_ID> (I'll notify you when it fires)

Monitor:  tmux attach -t <SESSION>      (Ctrl-b d to detach)
Peek:     tmux capture-pane -t <SESSION> -p | tail -40
Cancel:   tmux kill-session -t <SESSION> && git worktree remove --force <WORKTREE_PATH> && git branch -D <BRANCH>

Outcomes (artifacts land under <ORIGIN_GIT_DIR>/committee-loop/<SESSION>/):
- REVIEW CLEAN                 -> post.sh copies back, commits, writes DONE, tears down.
- REVIEW CLEAN + CONVERGED.txt -> same as CLEAN, but the sidecar names an oscillating finding; check decisions.md.
- .committee-loop-BLOCKED.txt   -> origin target changed/became-a-symlink during review, a multi-target run blocked mid-loop, origin's branch moved, or origin had unrelated staged index changes that would be swept into the review commit.
                                   Vetted writes ARE committed (marked "(PARTIAL)" or "(BRANCH MOVED)") EXCEPT when the block reason is an index conflict (pre-existing OR concurrent unrelated staged changes): those runs leave reviewed bytes in origin's working tree UNCOMMITTED and the user must resolve the conflicting index state before staging/committing manually. Worktree preserved for inspection either way.
- .committee-loop-EXHAUSTED.txt -> ran out of ralph iterations without emitting the promise; no copy-back, worktree preserved.
```

## How the pieces fit

<architecture>
- **`spawn.sh`** — outer-agent-invoked orchestrator. Preflight + worktree + seed + file generation + tmux spawn. Emits manifest.
- **`inner-agent.md`** — discipline for the detached Claude inside the worktree: per-iteration workflow, quorum/severity/ledger gates, convergence exit. Copied to `.committee-loop-instructions.md` at spawn.
- **`post-body.sh`** — body of `.committee-loop-post.sh`. Runs at loop completion: validates origin hasn't drifted, atomically copies reviewed bytes back to origin, commits, tears down worktree + tmux.
- **`watcher-body.sh`** — body of `.committee-loop-watcher.sh`. Polls sentinel files every 15s, 24h cap. Exit stdout tells the outer agent how the loop ended.
- **`SKILL.md`** (this file) — what the outer agent reads at `/committee-loop` invocation.
</architecture>

## Notes

- macOS: install `coreutils` (`brew install coreutils`) AND put the gnubin symlinks on PATH so `realpath`, `sha256sum`, `readlink -f`, and `timeout` resolve to the GNU variants (not BSD `readlink` which lacks `-f`, and not a missing `timeout`). Example: `export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$PATH"` in your shell profile. `spawn.sh` preflight probes `timeout` and behavior-probes `realpath -e` so a missing GNU variant fails fast.
- `--dangerously-skip-permissions` does NOT bypass Claude Code's protected-paths guard for writes under `.claude/` (claude-code#35718). `spawn.sh` launches a watchdog that auto-answers that prompt. Targets outside `.claude/` never trigger it. Scope is enforced by the inner-agent instructions, not by sandboxing.
- `--effort high` is the sweet spot for loop-agent discipline vs wall-time; `max` rarely pays off for single-file reviews.
- Each ralph iteration is capped at 10; if the loop doesn't converge within that, the watcher reports `EXHAUSTED` and the worktree is preserved for inspection.
