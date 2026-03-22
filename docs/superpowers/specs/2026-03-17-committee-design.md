# Committee: Multi-Perspective Code Review Agent

## Overview

Committee is a Claude Code skill (`/committee`) that orchestrates parallel code reviews from four independent AI reviewers, verifies claims made by the reviewers, and synthesizes the results into a single structured report.

The skill handles scope resolution, diff precomputation, trust level selection, and Claude reviewer dispatch before handing off to a coordinator subagent. The coordinator handles all orchestration — dispatching reviewers, running verification, producing the final report.

## Architecture

```
User session
  └── /committee (skill — scope resolution, diff precomputation, trust dialog, Claude dispatch)
        ├── Claude code-reviewer subagent (background, parallel with coordinator)
        └── Coordinator subagent (fresh context)
              ├── Codex review via Bash (parallel)
              ├── Kiro review via Bash (parallel)
              ├── Gemini review via Bash (parallel)
              ├── Poll for Claude's review file
              │
              ├── Per-reviewer verifier subagents (parallel, one per reviewer)
              │
              └── Synthesis (coordinator itself, produces final report)
```

### Layers

1. **Skill layer** — Parses user input, gathers available context, dispatches coordinator
2. **Coordinator subagent** — Orchestrates all phases, produces final report
3. **Reviewer subagents/processes** — Four parallel reviews, each using its native style
4. **Verifier subagent** — Assesses validity of claims from all reviews

## Skill Layer (`/committee`)

### Responsibilities

1. Parse user input to understand review scope
2. **Resolve the review scope to concrete git context** — this is the skill's primary job and the single source of truth for scope. The coordinator does not re-resolve scope; it trusts what the skill provides.
3. Dispatch coordinator subagent with a constructed prompt containing the resolved context
4. Display the coordinator's final report in the user's session

### Input Handling

The skill accepts freeform arguments and interprets them flexibly:

- `/committee` — No args. Auto-detect: uncommitted changes → branch diff from main → last commit.
- `/committee --base main` — Explicit git range.
- `/committee --commit abc123` — Specific commit.
- `/committee #123` or `/committee <PR URL>` — PR review. Uses `gh pr diff` to get the changes.
- `/committee "review the auth middleware changes"` — Vague context. The skill extracts what it can and passes the user's intent to the coordinator, which resolves the scope itself.

The skill always resolves to concrete git context before dispatching the coordinator. Even for vague inputs like "review the auth changes," the skill determines the relevant SHAs, branch, and diff stat. The coordinator never re-resolves scope — it trusts the skill's resolution and focuses on dispatching reviewers with the provided context.

### What the Skill Does NOT Do

- Review code (that's the reviewers' job)
- Synthesize or produce the final report (that's the coordinator's job)
- Run verifiers (that's the coordinator's job)

Note: The skill DOES resolve scope, precompute diffs, present the trust dialog, and dispatch the Claude reviewer. These responsibilities grew from the original "thin launcher" design as constraints were discovered (plugin access, session directory ownership, diff precomputation for security).

## Coordinator Subagent

The coordinator runs in its own context window, dispatched via the Agent tool. It executes three phases sequentially.

### Phase 1: Dispatch Reviewers (Parallel)

Four reviewers are dispatched simultaneously:

| Reviewer | Mechanism | Prompt Style |
|----------|-----------|--------------|
| Claude | Agent tool, `superpowers:code-reviewer` subagent type | Uses existing code-reviewer prompt template with git range. This is a pre-existing capability in the superpowers plugin. |
| Codex | Bash: `codex review --base <branch>` (branch diff) or `codex review --commit <sha>` (single commit) | Native review format, no custom prompt. Note: `--base` takes a branch name, not a SHA. |
| Kiro | Bash: `kiro-cli chat --no-interactive --trust-all-tools "<prompt>"` | Minimal context prompt (git range, what to review), native review style. `--trust-all-tools` required because the reviewer prompt asks Kiro to run git commands — `--trust-tools=fs_read` is too restrictive and blocks shell execution. |
| Gemini | Bash: `gemini -p "<prompt>" -e code-review -y -o text` | Non-interactive (`-p`), loads code-review extension (`-e`), auto-approves tool use (`-y`), text output (`-o text`) to avoid ANSI noise. |

Each reviewer is left to its native review style. No standardized output format is imposed.

For Kiro and Gemini, the prompt provides:
- The git range or PR reference
- A brief description of what's being reviewed
- No instructions on how to format the review — let the tool be itself

Note on scope-to-CLI mapping: The coordinator maps the skill-provided context (SHAs, branch, scope type) to the appropriate CLI flags per tool. For example, a branch diff becomes `codex review --base main` but `kiro-cli chat --no-interactive "Review the changes between main and HEAD"`. The coordinator does not determine *what* to review — only *how* to invoke each tool with the scope the skill already resolved.

### Phase 2: Verify Claims

After all 4 reviews return, the coordinator dispatches **one verifier per reviewer in parallel** (not a single shared verifier). Each verifier receives the file path for its reviewer's output and reads it directly — the coordinator never reads review content into its own context.

**As-built deviations from original design:**
- Session directories are project-relative (`.committee/session-XXXXXX/`) not `/tmp/` — subagents have Read tool access to the project directory
- The summarizer subagent was removed — per-reviewer verifiers each handle a single review file, so context budget is not a concern at that level
- Claude reviewer is dispatched by the skill layer (not the coordinator) using `superpowers:code-reviewer`, which requires top-level session plugin access unavailable in nested subagents

**Verifier input (per reviewer):**
- The file path to that reviewer's output
- The git range or review scope
- Full tool access (Read, Bash, Grep, Glob, etc.)

**Verifier process:**

1. Extract concrete, verifiable assertions from each review
2. Exercise judgment on verification depth per claim:
   - **Read code** for factual assertions about what code does/doesn't do
   - **Run tests** when a reviewer questions test correctness or coverage
   - **Note:** Cross-reviewer contradiction detection is handled by the coordinator's synthesis step, not individual verifiers. Each verifier only sees one reviewer's output.
   - **Skip verification** for subjective opinions, style preferences, suggestions
3. Tag each claim:
   - **Confirmed** — evidence supports the claim (cite file:line or test output)
   - **Refuted** — evidence contradicts the claim (cite why)
   - **Unverifiable** — can't be practically checked (explain why)

The verifier does not produce the final report. It returns annotated claims to the coordinator.

### Phase 3: Synthesize

The coordinator itself (not another subagent) takes the verified results and produces the final report. It:
- Deduplicates findings (same issue from multiple reviewers → one entry with multiple attributions)
- Assigns severity based on verified evidence (not just what the reviewer claimed)
- Calls out contradictions explicitly
- Produces the final verdict

## Final Report Format

```
## Committee Code Review

**Scope:** <description> (<base_sha>..<head_sha>, N files changed)
**Reviewers:** Claude, Codex, Kiro, Gemini

### Critical (Must Fix)
1. **<finding title>**
   - Flagged by: <reviewer(s)>
   - Status: ✅ Confirmed | ❌ Refuted | ⚠️ Unverifiable
   - Evidence: <file:line reference or test output>
   - Recommendation: <how to fix>

### Important (Should Fix)
...

### Minor (Nice to Have)
...

### Contradictions
- **<topic>**: <Reviewer A> says X, <Reviewer B> says Y.
  Verification found: <resolution or "unresolvable">

### Unverifiable Claims
- "<claim>" (<reviewer>) — <reason it couldn't be verified>

### Verdict
**Ready to merge?** Yes / No / With fixes
**Reasoning:** <1-2 sentences>
```

Rules:
- Findings are deduplicated. Multiple reviewers flagging the same issue = one entry with multiple attributions.
- Refuted claims still appear (in their severity section) so the user sees what was checked and dismissed.
- Severity is assigned by the coordinator based on verified evidence, not just reviewer assertions.

## File Structure

```
committee/
├── .claude/
│   └── skills/
│       └── committee/
│           └── SKILL.md          # The /committee skill (installed here for Claude Code to discover)
├── prompts/
│   ├── coordinator.md            # Coordinator subagent prompt template
│   ├── verifier.md               # Verifier subagent prompt template (one per reviewer, parallel)
│   └── reviewers/
│       ├── claude.md             # Claude review prompt (fallback when superpowers plugin unavailable)
│       ├── kiro.md               # Kiro review prompt (freeform chat, needs context)
│       └── gemini.md             # Gemini review prompt (freeform chat, needs context)
├── .committee/                   # Session directories (gitignored, created at runtime)
├── CLAUDE.md                     # Project conventions, prerequisites
└── docs/
    └── superpowers/
        ├── specs/
        │   └── 2026-03-17-committee-design.md
        └── plans/
            └── 2026-03-17-committee-plan.md
```

Notes:
- Claude's code-reviewer uses the existing `superpowers:code-reviewer` subagent type — no custom prompt file needed.
- Codex uses `codex review` with its built-in format — no custom prompt file needed.
- Kiro and Gemini need prompt templates because they're invoked via freeform CLI — these set context without prescribing review style.

## Prerequisites

- `codex` installed and authenticated
- `kiro-cli` installed and authenticated
- `gemini` installed with code-review extension (`gemini extensions install https://github.com/gemini-cli-extensions/code-review`), `GEMINI_API_KEY` configured
- Git repository with commits to review

## Error Handling

- **Timeouts:** Kiro and Gemini use a 5-minute (300000ms) timeout. Codex uses a 10-minute (600000ms) timeout (gpt-5.4 with xhigh reasoning is slow). The Claude reviewer has no explicit timeout — the coordinator's 10-minute polling window is the effective cap. If a Bash tool call returns a timeout error, the coordinator records the reviewer name and actual timeout as the failure reason. Do not retry.
- **Failures:** Any reviewer that produces a non-zero exit code, timeout, empty output, or an error message instead of a review is treated as failed. The coordinator proceeds with the remaining reviewers and notes each failure (reviewer name + reason) in the report header.
- **Minimum quorum:** If fewer than 2 reviewers succeed, the coordinator aborts and reports the failures to the user rather than producing a low-confidence review.
- **Verifier fallibility:** The verifier is not expected to be infallible — its judgment calls are surfaced transparently via the three-tier tagging system.
