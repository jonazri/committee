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
- `prompts/reviewers/claude.md` — Claude review prompt (embedded directly; plugin subagent types unavailable in nested subagent context)
- `prompts/reviewers/kiro.md` — Kiro review prompt (Kiro uses freeform chat, needs context)
- `prompts/reviewers/gemini.md` — Gemini review prompt (Gemini uses freeform chat, needs context)
- `prompts/summarizer.md` — Summarizer subagent prompt (used when a review exceeds 500 lines)
- `docs/superpowers/specs/` — Design spec
- `docs/superpowers/plans/` — Implementation plan

Note: Claude is dispatched by the skill (top-level, has plugin access) using `superpowers:code-reviewer` directly — not by the coordinator. The coordinator only handles Codex, Kiro, and Gemini. `prompts/reviewers/claude.md` is a fallback for when the plugin is unavailable. Codex uses `codex review` (branch/commit/uncommitted) or `codex exec` (sha_range). Only Kiro and Gemini need prompt templates because they're invoked via freeform CLI.

## Known Limitations

**Codex slowness** — Codex uses `gpt-5.4` with `xhigh` reasoning effort and takes ~5–10 minutes even for small diffs. The coordinator allows 10 minutes. For large diffs, Codex may still time out — the other 3 reviewers maintain quorum.

**Codex sha_range** — Codex has no native flag for arbitrary SHA ranges. For sha_range scope, the coordinator uses `codex exec --ephemeral -o FILE "prompt with SHA range"`, which lets Codex run `git diff` autonomously and produce a clean review via the `-o` output flag. Tested working; takes ~5-10 minutes.

**Shell injection + `--trust-all-tools`** — Kiro reviewer prompts go through shell variable expansion (`"$KIRO_PROMPT"`), and Kiro runs with `--trust-all-tools` (auto-approves all bash). A diff containing shell metacharacters in commit messages or filenames could cause unintended command execution. Acceptable for reviewing your own code; do not use on untrusted diffs without switching Kiro to a restricted tool set.

**Kiro network dependency** — Kiro connects to an external AWS service (`q.us-east-1.amazonaws.com`). It will fail with a network error in offline environments or if that service is unavailable. Treat Kiro as best-effort.

**Background task noise** — The coordinator uses background tasks internally to run CLI reviewers in parallel. When the coordinator subagent finishes, stale task-completion notifications may surface in the parent Claude Code session. These are harmless — the coordinator already processed their results before returning.

**Summaries lose origin context** — When a review exceeds 500 lines and gets summarized, the verifier receives the summary without knowing which claims came from the full text vs. were dropped by summarization. The verifier can read original files via `{SESSION_DIR}`, but it won't do so automatically for every claim.
