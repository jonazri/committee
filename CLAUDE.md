# Committee

Multi-perspective code review agent for Claude Code.

## What This Is

Two Claude Code skills:
- `/committee` — one-shot parallel code review from four AI reviewers (Claude, Codex, Kiro, Gemini), verifies claims, synthesizes a structured report.
- `/committee-loop` (v1.0) — spawns a detached session in an isolated worktree to iteratively review-and-refine a target file until clean. Iter-1 runs fast (Claude+Kiro+Codex, no Gemini); iter-2+ uses `/committee` (all 4). Includes a simplify pre-pass, parallel verifier subagents, and a persistent decision ledger to prevent thrashing.

## Prerequisites

All four reviewer CLIs must be installed and authenticated:

- **codex** — `npm install -g @openai/codex` then `codex login`
- **kiro-cli** — See https://kiro.dev for installation, then `kiro-cli settings` to configure
- **gemini** — `npm install -g @google/gemini-cli` then configure `GEMINI_API_KEY` in `~/.gemini/settings.json`
  - Install code-review extension: `gemini extensions install https://github.com/gemini-cli-extensions/code-review`
- **claude** — Already running if you're reading this in Claude Code

## Usage

```
/committee                              # Auto-detect scope
/committee --base main                  # Review branch diff from main
/committee --commit abc123              # Review specific commit
/committee abc123..def456               # Review explicit SHA range (bare pattern)
/committee --range abc123..def456       # Review explicit SHA range (flag form)
/committee #123                         # Review PR #123
/committee "review the auth changes"    # Vague — skill resolves scope from git history
/committee --files src/auth.ts src/db.ts # Review specific files (not a diff)
/committee --plan docs/plan.md          # Review an implementation plan
```

Optional cross-scope flags (combine with any scope above):

```
--trust=auto | --trust=read-only        # Pre-select CLI reviewer trust; skips the interactive dialog
--reviewer-model=opus|sonnet|haiku      # Override the Claude reviewer's model (default: harness default)
```

## Project Structure

- `.claude/skills/committee/SKILL.md` — The `/committee` skill entry point
- `.claude/skills/committee-loop/SKILL.md` — The `/committee-loop` companion skill (v1.0)
- `prompts/committee-review.js` — committee review workflow (reviewers → per-reviewer verify → structured `{ quorum, degraded, perReviewer }` return)
- `prompts/verifier.md` — Verifier subagent prompt template (read by the workflow's per-reviewer verifier agents)
- `prompts/reviewers/claude.md` — Claude reviewer prompt template; the skill fills it (including a per-scope `{REVIEW_LENS}`) and dispatches it to a built-in `general-purpose` agent
- `prompts/reviewers/kiro.md` — Kiro review prompt (Kiro uses freeform chat, needs context)
- `prompts/reviewers/gemini.md` — Gemini review prompt (Gemini uses freeform chat, needs context)
- `.committee/` — Session directories created at runtime (gitignored); each run creates `.committee/session-XXXXXX/`
- `docs/superpowers/specs/` — Design spec
- `docs/superpowers/plans/` — Implementation plan

Note: all four reviewers run inside the `committee-review` workflow (`prompts/committee-review.js`), which also runs a per-reviewer verifier agent and returns structured findings; the skill keeps prep (scope, diff, trust dialog) and synthesis. Claude runs as a built-in `general-purpose` agent filled with `prompts/reviewers/claude.md` — committee does NOT use a plugin `code-reviewer` agent type: superpowers 5.1.0 ships no agents, and an absent `subagent_type` is an unrecoverable dispatch error (this is what broke the old `superpowers:code-reviewer` path). Committee still depends on superpowers *skills* — `receiving-code-review` for findings verification — just not on any agent type. The workflow picks a per-scope review lens (code / PR / plan) so the single Claude template adapts to the review type. Codex uses `codex review` (branch/commit/uncommitted) or `codex exec` (sha_range / pr / files / plan). Only Kiro and Gemini need separate prompt templates because they're invoked via freeform CLI.

## Developing & deploying changes

`install.sh` installs both skills into `~/.claude/skills/` as **symlinks** — it `mkdir`s the real `committee/` and `committee-loop/` dirs, then symlinks `SKILL.md` and `prompts/` into this repo (`safe_symlink`, via `ln -sfn`). Consequences:

- **Edits to source are live** — `~/.claude/skills/committee/SKILL.md`, `~/.claude/skills/committee/prompts/` (→ repo `prompts/`), and `~/.claude/skills/committee-loop/SKILL.md` all point back at this repo. The committee-loop helper scripts (`spawn.sh`, `watcher-body.sh`, `health-check-body.sh`, `inner-agent.md`, `post-body.sh`) are NOT symlinked individually — they're resolved at runtime via `readlink -f` on the `SKILL.md` symlink, so editing them in the repo is immediately live too. **No copy step is needed.**
- **To take effect:** skills load at session start, so **start a fresh Claude Code session** after editing (a session already running keeps the old prompts/SKILL.md in context).
- **First install / repair:** run `./install.sh` from the repo root — idempotent (`ln -sfn`; it also replaces a stale real-dir target left by older `cp -r`-based installs). Verify with `ls -l ~/.claude/skills/committee ~/.claude/skills/committee-loop` — `SKILL.md` and `prompts` should be symlinks pointing into this repo.
- **Where what lives:** `/committee` reviewer/verifier prompts + the `committee-review` workflow (`prompts/committee-review.js`) → `prompts/` (deployed to `~/.claude/skills/committee/prompts/`); the workflow is *also* symlinked to `~/.claude/workflows/committee-review.js` so it resolves as a named workflow. `/committee-loop` workflow + helper scripts → `.claude/skills/committee-loop/` (deployed to `~/.claude/skills/committee-loop/`).
- **Uninstall:** `rm -rf ~/.claude/skills/committee ~/.claude/skills/committee-loop ~/.claude/workflows/committee-review.js`.

## Architectural Notes

**Reviewer parallelism** — the `committee-review` workflow dispatches all four reviewers (Claude as a `general-purpose` agent + the Codex/Kiro/Gemini CLIs) in parallel via `pipeline()`, then streams each reviewer into a per-reviewer verifier agent as soon as its review completes (no barrier between the Review and Verify stages). It returns `{ quorum, degraded, perReviewer }`; the skill synthesizes the Critical/Important/Minor report from that.

**Arg delivery** — the skill invokes the workflow with an `args` object, but the harness may deliver it to the workflow as a JSON *string*; `committee-review.js` accepts either form (parses a string, uses an object as-is) and fails fast if `sessionDir`/`promptsDir` are missing.

## Known Limitations

**Codex slowness** — Codex uses `gpt-5.4`. The workflow's Codex reviewer passes `-c model_reasoning_effort=high` on every invocation to override the user's global `xhigh` default, typically completing in ~3–5 minutes. The Codex command is wrapped in a shell `timeout` of 540s (600s for `--files`/`--plan` scope, since Codex explores auxiliary code to validate feasibility). For large diffs, Codex may still time out — the other 3 reviewers maintain quorum.

**Codex sha_range** — Codex has no native flag for arbitrary SHA ranges. For sha_range (and PR) scope, the workflow uses `codex exec --ephemeral -o FILE` with a heredoc prompt, which lets Codex run `git diff` autonomously. Slower than the native `codex review` flows above because Codex has to explore the range itself — ~5–10 minutes even at `high` effort.

**Shell injection + `--trust-all-tools`** — In auto mode (default), Kiro runs with `--trust-all-tools` and Gemini runs with `-y`. A diff containing adversarial content could trigger arbitrary command execution via prompt injection on the reviewer's LLM. The parent session's auto-mode classifier does NOT gate commands issued inside Kiro/Gemini subprocesses. In read-only mode, Kiro uses `--trust-tools=fs_read` (file reading only, no shell) and Gemini receives the diff via stdin without tool access. The skill presents a trust dialog before each run.

**Gemini model fallback (headless)** — The Code Assist backend regularly returns `429 MODEL_CAPACITY_EXHAUSTED` for `gemini-2.5-pro` (and sometimes `gemini-2.5-flash`) on paid plans — a *server-side capacity flag*, not per-account quota. The gemini-cli DOES have a built-in pro→flash fallback chain, but it is **gated on `isInteractive()`** (verified in the installed bundle: `onPersistent429: this.config.isInteractive() ? … : void 0`), so it does NOT cover committee's headless `gemini -p` calls — and merely omitting `-m` can't unpin a user's `GEMINI_MODEL` env var or `settings.model.name` (resolution order is `argv.model || GEMINI_MODEL || settings.model?.name`). The workflow therefore supplies its OWN fallback: the primary Gemini call passes no `-m` pin, and if it returns an empty file (the 429 case), a flash-pinned retry (`-m gemini-2.5-flash`, far less capacity-constrained and confirmed to work headless) runs automatically. If the retry is also empty, Gemini is dropped and quorum holds from the other three.

**Gemini `@` token parsing** — Gemini CLI processes `@path` tokens in stdin input, attempting to read referenced files. In read-only mode (no `-y`), the file read tool call is blocked. In auto mode (`-y`), it succeeds — a diff containing `@/etc/passwd` would cause that file to be read and sent to Google's API. This is within the accepted risk of auto mode but means read-only mode's safety depends on Gemini's tool approval gate, not on content sanitization.

**Kiro network dependency** — Kiro connects to an external AWS service (`q.us-east-1.amazonaws.com`). It will fail with a network error in offline environments or if that service is unavailable. Treat Kiro as best-effort.

**Kiro `profile_name` log error** — kiro-cli logs `Failed to get auth profile: missing field profile_name` on every non-interactive call ([upstream bug](https://github.com/kirodotdev/Kiro/issues/6170)). Non-fatal. If Kiro starts actually failing, re-login with `kiro-cli login`.

**Background task noise** — Stale task-completion notifications from the workflow's parallel reviewer/verifier dispatch may surface after the workflow returns. Harmless — its results were already processed.

**Session directories** — Each run creates `.committee/session-XXXXXX/` in the project root. These are gitignored and cleaned up on completion. If a run is interrupted abnormally, orphaned session dirs may remain — safe to delete manually.
