# Committee

Multi-perspective code review agent for Claude Code.

## What This Is

A Claude Code skill (`/committee`) that runs parallel code reviews from four AI reviewers (Claude, Codex, Kiro, Gemini), verifies claims, and synthesizes a structured report.

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
/committee abc123..def456               # Review explicit SHA range
/committee #123                         # Review PR #123
/committee "review the auth changes"    # Vague — skill resolves scope from git history
```

## Project Structure

- `.claude/skills/committee/SKILL.md` — The skill entry point (installed here for Claude Code to discover it as `/committee`)
- `prompts/coordinator.md` — Coordinator subagent prompt template
- `prompts/verifier.md` — Verifier subagent prompt template
- `prompts/reviewers/kiro.md` — Kiro review prompt (Kiro uses freeform chat, needs context)
- `prompts/reviewers/gemini.md` — Gemini review prompt (Gemini uses freeform chat, needs context)
- `prompts/summarizer.md` — Summarizer subagent prompt (used when a review exceeds 500 lines)
- `docs/superpowers/specs/` — Design spec
- `docs/superpowers/plans/` — Implementation plan

Note: Claude uses the `superpowers:code-reviewer` subagent type (no custom prompt needed). Codex uses `codex review` with its built-in format (no custom prompt needed). Only Kiro and Gemini need prompt templates because they're invoked via freeform CLI.

## Known Limitations

**Codex reliability** — Codex has been flaky in testing (Rust panics, process kills). Its review output is captured when it completes, but Codex may fail silently. The minimum quorum of 2 reviewers means the run still succeeds with 3 others.

**Kiro network dependency** — Kiro connects to an external AWS service (`q.us-east-1.amazonaws.com`). It will fail with a network error in offline environments or if that service is unavailable. Treat Kiro as best-effort.

**Background task noise** — The coordinator uses background tasks internally to run CLI reviewers in parallel. When the coordinator subagent finishes, stale task-completion notifications may surface in the parent Claude Code session. These are harmless — the coordinator already processed their results before returning.

**Summaries lose origin context** — When a review exceeds 500 lines and gets summarized, the verifier receives the summary without knowing which claims came from the full text vs. were dropped by summarization. The verifier can read original files via `{SESSION_DIR}`, but it won't do so automatically for every claim.
