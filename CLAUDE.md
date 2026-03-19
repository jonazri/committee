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
/committee #123                         # Review PR #123
/committee "review the auth changes"    # Vague — coordinator figures it out
```

## Project Structure

- `skills/committee/SKILL.md` — The skill entry point (thin launcher)
- `prompts/coordinator.md` — Coordinator subagent prompt template
- `prompts/verifier.md` — Verifier subagent prompt template
- `prompts/reviewers/kiro.md` — Kiro review prompt (Kiro uses freeform chat, needs context)
- `prompts/reviewers/gemini.md` — Gemini review prompt (Gemini uses freeform chat, needs context)
- `docs/superpowers/specs/` — Design spec
- `docs/superpowers/plans/` — Implementation plan

Note: Claude uses the `superpowers:code-reviewer` subagent type (no custom prompt needed). Codex uses `codex review` with its built-in format (no custom prompt needed). Only Kiro and Gemini need prompt templates because they're invoked via freeform CLI.
