# Committee

Multi-perspective code review agent for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Runs parallel code reviews from five AI reviewers, verifies claims, and synthesizes a single structured report.

## How It Works

```
/committee --base main
```

Committee runs five reviewers in parallel inside the `committee-review` workflow:

| Reviewer | Model | Mechanism |
|----------|-------|-----------|
| **Claude** | Claude (harness default; `--reviewer-model` to override) | workflow agent (`general-purpose`) + bundled template |
| **Codex** | GPT-5.4 | workflow agent runs `codex review` / `codex exec` |
| **Kiro** | Amazon Q | workflow agent runs `kiro-cli chat` |
| **Gemini** | Gemini 3.5 Flash | workflow agent runs `agy -p --model gemini-3.5-flash` |
| **Gemini-Pro** | Gemini 3.1 Pro (High) | workflow agent runs `agy -p --model "Gemini 3.1 Pro (High)"` (Pro→Flash retry at default pin) |

After the reviewers return, the `committee-review` workflow runs **per-reviewer verifiers** in parallel — one agent each, checking that reviewer's claims against the actual codebase — and returns a structured `{ quorum, degraded, perReviewer }` result. Then the `/committee` skill:
1. **Synthesizes** the verified claims into a deduplicated report with severity ratings, contradiction detection, and a merge verdict
2. Applies **receiving-code-review** evaluation before presenting — adding a layer of skepticism to the reviewers' findings

## Prerequisites

Install and authenticate the reviewer CLIs (both Gemini reviewers use the Antigravity `agy` CLI):

```bash
# Codex (OpenAI)
npm install -g @openai/codex
codex login

# Kiro (Amazon)
# See https://kiro.dev for installation
kiro-cli login

# Gemini reviewers — Google Antigravity CLI
# Install per https://antigravity.google, then sign in:
agy            # run once interactively to complete OAuth, then exit

# Claude — already running if you're in Claude Code
```

The Claude reviewer runs as the built-in `general-purpose` agent using committee's bundled prompt template (`prompts/reviewers/claude.md`) — no extra plugin is needed for it. Committee still uses the [superpowers](https://github.com/anthropics/claude-plugins-official) plugin for its *skills* (`receiving-code-review` for findings verification; `/committee-loop` also uses `subagent-driven-development` and `verification-before-completion`), so keep superpowers installed. Note: superpowers 5.1.0 no longer ships a `code-reviewer` agent type — committee does not depend on one.

## Installation

```bash
git clone https://github.com/jonazri/committee.git && cd committee && ./install.sh
```

`install.sh` symlinks the `committee` and `committee-loop` skills into `~/.claude/skills/` (and the `committee-review` workflow into `~/.claude/workflows/`), so `/committee` and `/committee-loop` are available in every Claude Code session. Re-running is safe; uninstall with `rm -rf ~/.claude/skills/committee ~/.claude/skills/committee-loop ~/.claude/workflows/committee-review.js`.

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

- **Read-only** (default) — the CLI reviewers can only read. Gemini reviewers run `agy` under a fail-closed deny lockdown (repo reads allowed; writes, shell, **and** URL/network fetch denied), Kiro runs `--trust-tools=fs_read`, and Codex runs `--sandbox read-only`. Safer for untrusted code (but not exfil-safe — see Security Considerations).
- **Auto Mode** (explicit opt-in, trusted content only) — relaxes the lockdown: the Gemini reviewers may additionally use the network/web, and Codex follows your `~/.codex/config.toml` sandbox (which can allow writes if you widened it). **Gemini and Kiro still cannot write to or run commands in your repo** — writes and shell are denied in *both* modes (as of 2026-06-23; `--dangerously-skip-permissions` is no longer used). The Claude reviewer inherits the parent session's auto-mode classifier in either mode.

## Committee Loop

Companion skill `/committee-loop` (v1.1) runs iterative review-and-refine cycles. Where `/committee` produces a single report for you to act on, `/committee-loop` spawns a detached Claude Code session in an isolated git worktree that:

1. Runs a `simplify` pre-pass to catch obvious code-quality issues
2. **Iteration 1 — fast mode:** dispatches Claude + Kiro + Codex in parallel (skipping Gemini); Codex runs at `high` reasoning effort (~3–5 min)
3. **Iteration 2+ — full mode:** uses `/committee` (all 5 reviewers, including both Gemini models) for thorough verification
4. Per reviewer, dispatches a parallel verifier subagent that runs concrete bash probes to confirm each claim before any fix is applied
5. Applies only Critical+Important findings that pass a quorum gate (≥2 reviewers OR single reviewer + passing verification probe); rejects unverifiable claims; defers minors to a sidecar
6. Maintains a persistent `.committee-loop-decisions.md` ledger with verification commands and rationale for every decision — prevents thrashing because prior rejections can't be re-opened without new evidence — and feeds each round's REFUTED/SETTLED record back to every reviewer and verifier so settled items aren't re-litigated
7. Exits when zero blocking findings remain — under the default gate that's zero Critical+Important; for spec/plan/doc targets a **soundness gate** (auto-selected, or `--gate soundness`) blocks only on findings that would make an implementer build something incorrect/insecure/non-functional and routes documentation polish to a non-blocking `polish.md` backlog, so large prose targets converge (**SOUNDNESS CLEAN**) instead of exhausting the iteration budget — or when a fix would reverse a prior iteration (convergence detection), and copies the reviewed file back to origin with a commit

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

This allows all Bash commands for this project. Committee's workflow agents run `git`, `codex`, `kiro-cli`, `agy`, `cat`, `mktemp`, `rm`, and other standard commands. Without a broad permission, you'll get frequent approval prompts — especially from the CLI reviewer invocations.

If you prefer granular permissions instead of a blanket allow:

```json
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(codex:*)",
      "Bash(kiro-cli:*)",
      "Bash(agy:*)",
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
  └── /committee (skill — scope, precompute diff, trust dialog, synthesis)
        └── committee-review workflow (Workflow tool)
              ├── Review stage (parallel):
              │     ├── Claude  — general-purpose agent + bundled template
              │     ├── Codex   — agent runs codex review / codex exec
              │     ├── Kiro    — agent runs kiro-cli chat
              │     ├── Gemini  — agent runs `agy --model gemini-3.5-flash`
              │     └── Gemini-Pro — agent runs `agy --model "Gemini 3.1 Pro (High)"` (Pro→Flash retry)
              ├── Verify stage — one verifier agent per reviewer, streamed as each review completes
              └── returns { quorum, degraded, perReviewer }
                    → skill synthesizes (dedup, contradiction detection, verdict)
```

Key design decisions:
- **Reviewers + verifiers run in a workflow** (not a single orchestrator subagent) — deterministic fan-out via `pipeline()`; the skill keeps scope/diff/trust prep and the final synthesis
- **Per-reviewer verifiers** (not one shared verifier) — smaller context per verifier, parallel execution, better failure isolation
- **Precomputed diffs** — reviewers read from file instead of running `git diff`, eliminating the need for shell access in read-only mode
- **Structured return, not files** — the workflow returns verified claims as data (`{ quorum, degraded, perReviewer }`); the skill synthesizes from that and never parses raw review files

## Timing

| Scope | Expected Duration |
|-------|------------------|
| Single commit | ~5–8 min |
| Branch diff | ~5–8 min |
| SHA range | ~8–10 min |
| PR | ~8–10 min |

Codex (GPT-5.4) is the bottleneck. The workflow's Codex reviewer overrides to `model_reasoning_effort=high` (from the user's `xhigh` default), typically completing in ~3–5 min, wrapped in a 540s `timeout` (600s for `--files`/`--plan` scope). The other four reviewers typically finish in 1–3 min. The minimum quorum is 2 of 5 reviewers — if Codex times out, the review proceeds with the others.

## Security Considerations

- **Reviewers cannot write or execute in either mode** (as of 2026-06-23): Kiro always uses `--trust-tools=fs_read` (no shell) and the Gemini reviewers always run `agy` under a fail-closed per-run-`HOME` `permissions.deny` lockdown with **no** `--dangerously-skip-permissions`. Both modes deny `write_file`/`edit_file`/`replace`/`command`/`run_command` (writes + shell). This closes the regression where an auto-mode Gemini reviewer would *execute* a plan/prompt-injected diff and change code (RCA 2026-06-23).
- **Read-only mode** (default) additionally denies the network/URL exfil tools (`read_url`/`fetch`/`web_search`/`browser_action`) and runs Codex `--sandbox read-only`. Repo reads (`read_file`/`grep_search`) are still ALLOWED, so this is *safer for untrusted content*, NOT a zero-tool sandbox. **Not exfil-safe:** `agy`'s reads are not filesystem-confined, so a prompt-injected reviewer can read local files (incl. `~/.gemini` creds) and echo them into the review output (accepted risk); the network denials only close the *network* exfil channel.
- **Auto Mode** (explicit opt-in, trusted content only): relaxes the lockdown so the Gemini reviewers may use the network and Codex follows your `~/.codex/config.toml` sandbox (Codex is the only reviewer that could write, and only if you widened that config). Because auto allows the network, a prompt-injected read could be POSTed to a URL — use only for reviewing content you trust.
- **Gemini `@` tokens**: `agy` processes `@path` in stdin and reads the file via `read_file` (NOT workspace-confined — verified to read out-of-repo paths). In both modes writes/shell are denied, so an `@`-read can't become a write/commit; in read-only the network is denied too, so it can't be fetched to a URL (but can still be echoed into the review output — accepted risk). In auto mode the network is allowed, so an `@`-read could also be POSTed to a URL (accepted trusted-content risk).
- **Branch name injection**: The skill instructs the executing LLM to quote all branch names in bash commands. Defense-in-depth for crafted branch names.

## File Structure

```
.claude/skills/
  committee/SKILL.md                 # /committee skill entry point
  committee-loop/                    # /committee-loop skill (SKILL.md + spawn.sh + inner-agent.md + body scripts)
prompts/
  committee-review.js                # review workflow (reviewers -> per-reviewer verify -> structured return)
  verifier.md                        # Per-reviewer verifier prompt
  reviewers/
    claude.md                        # Claude reviewer prompt template (filled per-scope, dispatched to general-purpose agent)
    kiro.md                          # Kiro review prompt template
    gemini.md                        # Gemini review prompt template (consumed by the agy-backed Gemini reviewers)
CLAUDE.md                            # Project conventions
docs/superpowers/
  specs/                             # Design spec
  plans/                             # Implementation plan
```

## License

MIT
