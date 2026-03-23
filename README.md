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

Clone this repo into your project (or any directory where you want the skill available):

```bash
git clone https://github.com/jonazri/committee.git
cd committee
```

The skill is at `.claude/skills/committee/SKILL.md` — Claude Code discovers it automatically when you open this directory.

### Installing into an existing project

Copy the skill and prompts into your project:

```bash
# From your project root:
mkdir -p .claude/skills/committee
cp /path/to/committee/.claude/skills/committee/SKILL.md .claude/skills/committee/
cp -r /path/to/committee/prompts .

# Add to .gitignore
echo ".committee/" >> .gitignore
```

## Usage

```
/committee                              # Auto-detect scope
/committee --base main                  # Review branch diff from main
/committee --commit abc123              # Review specific commit
/committee abc123..def456               # Review explicit SHA range
/committee --range abc123..def456       # Explicit SHA range (flag form)
/committee #123                         # Review PR #123
/committee "review the auth changes"    # Vague — skill resolves from git history
```

### Trust Level

Before each run, Committee presents a trust dialog:

- **Read-only** (default) — Reviewers read a precomputed diff file. No shell access. Safe for untrusted code.
- **Full access** — Reviewers can explore the repo autonomously (`git log`, `grep`, `blame`). Richer reviews but exposes the host to prompt injection from diff content.

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

Codex (GPT-5.4, xhigh reasoning) is the bottleneck at ~5–10 min. The other three reviewers typically finish in 1–3 min. The minimum quorum is 2 of 4 reviewers — if Codex times out, the review proceeds with the other three.

## Security Considerations

- **Read-only mode** (default): Kiro uses `--trust-tools=fs_read` (no shell). Gemini receives diff via stdin (no tool access). Safe for reviewing untrusted code.
- **Full-access mode**: Kiro uses `--trust-all-tools`, Gemini uses `-y`. A malicious diff could trigger arbitrary command execution via prompt injection. Use only for reviewing your own code.
- **Gemini `@` tokens**: Gemini CLI processes `@path` in stdin, attempting file reads. Blocked in read-only mode; succeeds in full-access mode.
- **Branch name injection**: The skill instructs the executing LLM to quote all branch names in bash commands. Defense-in-depth for crafted branch names.

## File Structure

```
.claude/skills/committee/SKILL.md   # Skill entry point
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
