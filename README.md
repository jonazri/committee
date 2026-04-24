# Committee

Multi-perspective code review agent for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Runs parallel code reviews from four AI reviewers, verifies claims, and synthesizes a single structured report.

## How It Works

```
/committee --base main
```

Committee dispatches four reviewers in parallel:

| Reviewer | Model | Mechanism |
|----------|-------|-----------|
| **Claude** | Claude (via superpowers plugin) | Agent subagent |
| **Codex** | GPT-5.4 | `codex review` / `codex exec` |
| **Kiro** | Amazon Q | `kiro-cli chat` |
| **Gemini** | Gemini | `gemini` CLI with code-review extension |

After all reviews return, Committee:
1. Dispatches **per-reviewer verifiers** in parallel — each verifier checks one reviewer's claims against the actual codebase
2. The coordinator **synthesizes** verified claims into a deduplicated report with severity ratings, contradiction detection, and a merge verdict
3. The skill applies **receiving-code-review** evaluation before presenting — adding a layer of skepticism to the reviewers' findings

## Prerequisites

Install and authenticate all four reviewer CLIs:

```bash
# Codex (OpenAI)
npm install -g @openai/codex
codex login

# Kiro (Amazon)
# See https://kiro.dev for installation
kiro-cli login

# Gemini (Google)
npm install -g @google/gemini-cli
# Configure GEMINI_API_KEY in ~/.gemini/settings.json
gemini extensions install https://github.com/gemini-cli-extensions/code-review

# Claude — already running if you're in Claude Code
```

Committee also requires the [superpowers](https://github.com/anthropics/claude-plugins-official) plugin for Claude Code (provides the `code-reviewer` agent type).

## Installation

```bash
git clone https://github.com/jonazri/committee.git && cd committee && ./install.sh
```

`install.sh` symlinks the `committee` and `committee-loop` skills into `~/.claude/skills/`, so `/committee` and `/committee-loop` are available in every Claude Code session. Re-running is safe; uninstall with `rm -rf ~/.claude/skills/committee ~/.claude/skills/committee-loop`.

Keep the cloned repo around — the skills are symlinked into it. To update, `git pull` in the clone; no reinstall needed.

## Usage

```
/committee                              # Auto-detect scope
/committee --base main                  # Review branch diff from main
/committee --commit abc123              # Review specific commit
/committee abc123..def456               # Review explicit SHA range
/committee --range abc123..def456       # Explicit SHA range (flag form)
/committee #123                         # Review PR #123
/committee "review the auth changes"    # Vague — skill resolves from git history
/committee --files src/auth.ts src/db.ts # Review specific files (not a diff)
/committee --plan docs/plan.md          # Review an implementation plan
/committee --plan plan.md --spec spec.md # Review plan against a spec
```

Optional cross-scope flags (combine with any scope above):

| Flag | Effect |
|------|--------|
| `--trust=auto` / `--trust=read-only` | Pre-selects CLI reviewer trust level, skipping the interactive dialog (used by `/committee-loop` for unattended runs). |
| `--reviewer-model=opus\|sonnet\|haiku` | Overrides the Claude reviewer's model. Inherits the harness default. `/committee-loop` uses `sonnet` from iter-3 on for faster iterations (~3 min vs ~8 min). |

### File Review (`--files`)

Reviews standalone files for code quality, bugs, design, and security — not as a git diff, but as complete source files. Useful for reviewing files that aren't part of a recent commit, imported code, or generated output.

### Plan Review (`--plan`)

Reviews an implementation plan for completeness, feasibility, task decomposition, architectural soundness, and whether an implementing agent could follow it. Optionally cross-references against a spec file. Review criteria shift from code quality to plan quality:
- Are tasks atomic and actionable?
- Are file paths and code examples concrete?
- Are edge cases and error handling covered?
- Does the plan violate YAGNI?
- Could an implementing agent follow this without ambiguity?

### Trust Level

Before each run, Committee presents a trust dialog:

- **Auto Mode** (default) — CLI reviewers (Kiro, Gemini) run with their own auto-approval flags so they can explore the repo (`git log`, `grep`, `blame`); the Claude reviewer inherits the parent session's auto-mode classifier. The parent classifier does NOT gate commands inside Kiro/Gemini subprocesses — diff-borne prompt injection can execute there.
- **Read-only** — Reviewers read a precomputed diff file. No shell access. Safer for untrusted code.

## Committee Loop

Companion skill `/committee-loop` (v1.0) runs iterative review-and-refine cycles. Where `/committee` produces a single report for you to act on, `/committee-loop` spawns a detached Claude Code session in an isolated git worktree that:

1. Runs a `simplify` pre-pass to catch obvious code-quality issues
2. **Iteration 1 — fast mode:** dispatches Claude + Kiro + Codex in parallel (skipping Gemini); Codex runs at `high` reasoning effort (~3–5 min)
3. **Iteration 2+ — full mode:** uses `/committee` (all 4 reviewers, including Gemini) for thorough verification
4. Per reviewer, dispatches a parallel verifier subagent that runs concrete bash probes to confirm each claim before any fix is applied
5. Applies only Critical+Important findings that pass a quorum gate (≥2 reviewers OR single reviewer + passing verification probe); rejects unverifiable claims; defers minors to a sidecar
6. Maintains a persistent `.committee-loop-decisions.md` ledger with verification commands and rationale for every decision — prevents thrashing because prior rejections can't be re-opened without new evidence
7. Exits when zero Critical+Important findings remain, or when a fix would reverse a prior iteration (convergence detection), and copies the reviewed file back to origin with a commit

Invocation:
```
/committee-loop Review docs/superpowers/specs/my-spec.md
```

Requires `tmux`, `git 2.31+`, `realpath -e` (GNU coreutils), `sha256sum`, and the `ralph-loop` Claude Code plugin. The loop runs unattended — monitor with `tmux attach -t <session>` or walk away.

## Recommended Settings

Add these to your project's `.claude/settings.local.json` for smooth operation (avoids permission dialogs):

```json
{
  "permissions": {
    "allow": [
      "Bash(*:*)"
    ]
  }
}
```

This allows all Bash commands for this project. Committee's subagents run `git`, `codex`, `kiro-cli`, `gemini`, `sleep`, `cat`, `mktemp`, `rm`, and other standard commands. Without a broad permission, you'll get frequent approval prompts — especially from the coordinator's polling loop and CLI reviewer invocations.

If you prefer granular permissions instead of a blanket allow:

```json
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(codex:*)",
      "Bash(kiro-cli:*)",
      "Bash(gemini:*)",
      "Bash(gh:*)",
      "Bash(wc:*)",
      "Bash(mktemp:*)",
      "Bash(mkdir:*)",
      "Bash(rm:*)",
      "Bash(cat:*)",
      "Bash(sleep:*)"
    ]
  }
}
```

Note: Even with granular permissions, compound shell commands (pipelines, loops) may still trigger prompts. `Bash(*:*)` is recommended.

## Output Format

Committee produces a structured markdown report:

```
## Committee Code Review

**Scope:** Feature branch (abc123..def456, 5 files changed)
**Reviewers:** Claude, Codex, Kiro, Gemini

### Critical (Must Fix)
1. **SQL injection in query builder**
   - Flagged by: Codex, Gemini
   - Status: Confirmed
   - Evidence: `src/db.ts:42` — user input passed directly to query
   - Recommendation: Use parameterized queries

### Important (Should Fix)
...

### Minor (Nice to Have)
...

### Contradictions
- **Error handling**: Claude says adequate, Kiro says missing.
  Verification found: ...

### Verdict
**Ready to merge?** With fixes
**Reasoning:** Core logic is sound; SQL injection must be fixed first.
```

## Architecture

```
User session
  └── /committee (skill — scope, diff, trust dialog, Claude dispatch)
        ├── Claude code-reviewer (background, via superpowers plugin)
        └── Coordinator subagent
              ├── Codex review via Bash (parallel)
              ├── Kiro review via Bash (parallel)
              ├── Gemini review via Bash (parallel)
              ├── Poll for Claude's review file
              ├── Per-reviewer verifier subagents (parallel)
              └── Synthesis (deduplication, contradiction detection, verdict)
```

Key design decisions:
- **Claude dispatched by skill layer** (not coordinator) — plugin agent types require top-level session access
- **Per-reviewer verifiers** (not one shared verifier) — smaller context per verifier, parallel execution, better failure isolation
- **Precomputed diffs** — reviewers read from file instead of running `git diff`, eliminating the need for shell access in read-only mode
- **Coordinator never reads review content** — passes file paths to verifiers, which read directly. Keeps coordinator context lean.

## Timing

| Scope | Expected Duration |
|-------|------------------|
| Single commit | ~5–8 min |
| Branch diff | ~5–8 min |
| SHA range | ~8–10 min |
| PR | ~8–10 min |

Codex (GPT-5.4) is the bottleneck. The coordinator overrides to `model_reasoning_effort=high` (from the user's `xhigh` default), typically completing in ~3–5 min. Timeout is 8 min (10 min for `--plan` scope). The other three reviewers typically finish in 1–3 min. The minimum quorum is 2 of 4 reviewers — if Codex times out, the review proceeds with the other three.

## Security Considerations

- **Auto Mode** (default): Kiro uses `--trust-all-tools`, Gemini uses `-y`. A malicious diff could trigger arbitrary command execution via prompt injection at the reviewer-CLI layer. The parent session's auto-mode classifier does not gate subprocess internals. Use only for reviewing your own code.
- **Read-only mode**: Kiro uses `--trust-tools=fs_read` (no shell). Gemini receives diff via stdin (no tool access). Safer for reviewing untrusted code.
- **Gemini `@` tokens**: Gemini CLI processes `@path` in stdin, attempting file reads. Blocked in read-only mode; succeeds in auto mode.
- **Branch name injection**: The skill instructs the executing LLM to quote all branch names in bash commands. Defense-in-depth for crafted branch names.

## File Structure

```
.claude/skills/
  committee/SKILL.md                 # /committee skill entry point
  committee-loop/                    # /committee-loop skill (SKILL.md + spawn.sh + inner-agent.md + body scripts)
prompts/
  coordinator.md                     # Coordinator orchestration prompt
  verifier.md                        # Per-reviewer verifier prompt
  reviewers/
    claude.md                        # Claude fallback prompt
    kiro.md                          # Kiro review prompt template
    gemini.md                        # Gemini review prompt template
CLAUDE.md                            # Project conventions
docs/superpowers/
  specs/                             # Design spec
  plans/                             # Implementation plan
```

## License

MIT
