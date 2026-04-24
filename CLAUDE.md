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
- `prompts/coordinator.md` — Coordinator subagent prompt template
- `prompts/verifier.md` — Verifier subagent prompt template
- `prompts/reviewers/claude.md` — Claude review prompt (embedded directly; plugin subagent types unavailable in nested subagent context)
- `prompts/reviewers/kiro.md` — Kiro review prompt (Kiro uses freeform chat, needs context)
- `prompts/reviewers/gemini.md` — Gemini review prompt (Gemini uses freeform chat, needs context)
- `.committee/` — Session directories created at runtime (gitignored); each run creates `.committee/session-XXXXXX/`
- `docs/superpowers/specs/` — Design spec
- `docs/superpowers/plans/` — Implementation plan

Note: Claude is dispatched by the skill (top-level, has plugin access) using `superpowers:code-reviewer` directly — not by the coordinator. The coordinator only handles Codex, Kiro, and Gemini. `prompts/reviewers/claude.md` is a fallback for when the plugin is unavailable. Codex uses `codex review` (branch/commit/uncommitted) or `codex exec` (sha_range). Only Kiro and Gemini need prompt templates because they're invoked via freeform CLI.

## Architectural Notes

**Claude parallelism** — Claude is dispatched by the skill in the background while the coordinator simultaneously starts the CLI reviewers. The coordinator polls for `claude.md` before verification. All 4 reviewers run in parallel.

**Potential future improvement — Claude as CLI subprocess:** The coordinator could invoke `claude -p "$PROMPT"` via Bash directly, inheriting `~/.claude/` config including plugins. This would remove the need for the skill to handle Claude separately, making it a thin launcher again. Not yet implemented.

## Known Limitations

**Codex slowness** — Codex uses `gpt-5.4`. The coordinator passes `-c model_reasoning_effort=high` on every invocation to override the user's global `xhigh` default, typically completing in ~3–5 minutes. Coordinator timeout is 8 minutes (10 for `--plan` scope, since Codex explores auxiliary code to validate feasibility). For large diffs, Codex may still time out — the other 3 reviewers maintain quorum.

**Codex sha_range** — Codex has no native flag for arbitrary SHA ranges. For sha_range (and PR) scope, the coordinator uses `codex exec --ephemeral -o FILE - < prompt_file`, which lets Codex run `git diff` autonomously. Slower than the native `codex review` flows above because Codex has to explore the range itself — ~5–10 minutes even at `high` effort.

**Shell injection + `--trust-all-tools`** — In auto mode (default), Kiro runs with `--trust-all-tools` and Gemini runs with `-y`. A diff containing adversarial content could trigger arbitrary command execution via prompt injection on the reviewer's LLM. The parent session's auto-mode classifier does NOT gate commands issued inside Kiro/Gemini subprocesses. In read-only mode, Kiro uses `--trust-tools=fs_read` (file reading only, no shell) and Gemini receives the diff via stdin without tool access. The skill presents a trust dialog before each run.

**Gemini `@` token parsing** — Gemini CLI processes `@path` tokens in stdin input, attempting to read referenced files. In read-only mode (no `-y`), the file read tool call is blocked. In auto mode (`-y`), it succeeds — a diff containing `@/etc/passwd` would cause that file to be read and sent to Google's API. This is within the accepted risk of auto mode but means read-only mode's safety depends on Gemini's tool approval gate, not on content sanitization.

**Kiro network dependency** — Kiro connects to an external AWS service (`q.us-east-1.amazonaws.com`). It will fail with a network error in offline environments or if that service is unavailable. Treat Kiro as best-effort.

**Kiro `profile_name` log error** — kiro-cli logs `Failed to get auth profile: missing field profile_name` on every non-interactive call ([upstream bug](https://github.com/kirodotdev/Kiro/issues/6170)). Non-fatal. If Kiro starts actually failing, re-login with `kiro-cli login`.

**Background task noise** — Stale task-completion notifications from the coordinator's parallel reviewer dispatch may surface after the coordinator returns. Harmless — its results were already processed.

**Session directories** — Each run creates `.committee/session-XXXXXX/` in the project root. These are gitignored and cleaned up on completion. If a run is interrupted abnormally, orphaned session dirs may remain — safe to delete manually.
