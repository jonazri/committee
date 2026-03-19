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
- `prompts/reviewers/` — Prompt templates for Kiro and Gemini
- `docs/superpowers/specs/` — Design spec
- `docs/superpowers/plans/` — Implementation plan
