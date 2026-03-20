# Committee Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude Code skill (`/committee`) that orchestrates parallel code reviews from Claude, Codex, Kiro, and Gemini, verifies reviewer claims, and synthesizes a structured report.

**Architecture:** A thin skill launcher dispatches a coordinator subagent with fresh context. The coordinator dispatches 4 reviewer processes in parallel, then a verifier subagent, then synthesizes the final report itself. All prompt logic lives in markdown template files.

**Tech Stack:** Claude Code skills (markdown), Bash (CLI orchestration), Claude Code Agent tool (subagents)

**Spec:** `docs/superpowers/specs/2026-03-17-committee-design.md`

---

## Execution Status

**Completed:** 2026-03-19

### What's Done

All 6 implementation tasks complete. Final commit: `88125d9`.

| Task | File | Status |
|------|------|--------|
| 1 | `CLAUDE.md` | ✅ Done |
| 2 | `prompts/reviewers/kiro.md` | ✅ Done |
| 3 | `prompts/reviewers/gemini.md` | ✅ Done |
| 4 | `prompts/verifier.md` | ✅ Done |
| 5 | `prompts/coordinator.md` | ✅ Done |
| 6 | `skills/committee/SKILL.md` | ✅ Done |
| 7 | Smoke test | ⏳ Pending live session |

### What's Remaining

**Task 7 (Smoke Test):** The live end-to-end test requires a Claude Code session with the skill loaded. All three CLIs are authenticated (codex, kiro-cli, gemini). Run:
```
/committee --commit HEAD
```
Then verify the report contains: `## Committee Code Review` header, scope info, reviewer attributions, findings with verification status, and a verdict. Test auto-detect with `/committee`.

### Deviations from Plan

1. **Tasks 2–4 were batched into a single subagent invocation** — The plan defines them as separate tasks, but they were dispatched to one subagent since all three are independent file writes with no shared state. Each was still committed separately per the plan.

2. **Extra fixes added during code quality review:**
   - `prompts/verifier.md` — Added explicit `REVIEWER FAILED: <reason>` handling (reviewer flagged missing failure path)
   - `CLAUDE.md` — Expanded Project Structure section to list kiro.md/gemini.md separately and clarify why Codex/Claude have no custom prompts
   - `prompts/coordinator.md` — Context threshold made concrete (under/over 500 lines instead of "use judgment"); PR scope for Kiro/Gemini made explicit (`git diff {BASE_BRANCH}...{HEAD_BRANCH}`)

3. **`--range` and bare SHA range detection added to skill** — The spec's scope table lists only `--base`, `--commit`, `--uncommitted`, and PR as input modes. Added `--range <sha1>..<sha2>` and bare `sha1..sha2` pattern detection to support arbitrary SHA ranges. Codex is automatically skipped for this scope type (no native support).

4. **`{GIT_RANGE_INSTRUCTIONS}` kept as freeform placeholder** — A reviewer suggested replacing it with raw `{BASE_SHA}`/`{HEAD_SHA}` placeholders. Pushed back: the coordinator fills it with human-readable git commands (e.g. "Run `git diff main...HEAD`"), which is intentionally more helpful for Kiro/Gemini than raw SHAs.

### Known Issues (resolved 2026-03-19)

Issues identified during first live run and addressed in subsequent commit:

**Issue 3: Shell injection in Kiro/Gemini invocations** — ✅ Fixed
Coordinator now uses Write tool to write filled prompt to `$SESSION_DIR/kiro_prompt.txt` / `$SESSION_DIR/gemini_prompt.txt`, then reads via `$PROMPT=$(cat file)` / stdin redirect. Prompt content no longer inline in bash string.

**Issue 4: Temp directory never cleaned up** — ✅ Fixed
Added `trap 'rm -rf "$SESSION_DIR"' EXIT` immediately after `mktemp`, plus explicit `rm -rf "$SESSION_DIR"` at end of Phase 3.

---

## File Structure

```
committee/
├── skills/
│   └── committee/
│       └── SKILL.md              # Skill definition — thin launcher, parses input, dispatches coordinator
├── prompts/
│   ├── coordinator.md            # Coordinator subagent prompt — orchestrates all phases
│   ├── verifier.md               # Verifier subagent prompt — assesses claim validity
│   └── reviewers/
│       ├── kiro.md               # Kiro review prompt template
│       └── gemini.md             # Gemini review prompt template
├── CLAUDE.md                     # Project conventions, prerequisites, usage
└── docs/
    └── superpowers/
        ├── specs/
        │   └── 2026-03-17-committee-design.md
        └── plans/
            └── 2026-03-17-committee-plan.md
```

**No custom prompts needed for:**
- Claude — uses existing `superpowers:code-reviewer` subagent type
- Codex — uses `codex review` with built-in format

---

## Chunk 1: Foundation and Reviewer Prompts

### Task 1: CLAUDE.md

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Write CLAUDE.md**

This file documents project conventions, prerequisites, and usage for anyone (human or agent) working in this repo.

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Add CLAUDE.md with project conventions and prerequisites"
```

---

### Task 2: Kiro Reviewer Prompt

**Files:**
- Create: `prompts/reviewers/kiro.md`

- [ ] **Step 1: Write Kiro review prompt template**

This template is interpolated by the coordinator and passed to `kiro-cli chat --no-interactive --trust-tools=fs_read "<interpolated prompt>"`. It provides context without prescribing review format — let Kiro be itself.

```markdown
Review the code changes in this git repository.

{SCOPE_DESCRIPTION}

{GIT_RANGE_INSTRUCTIONS}

Focus your review on whatever you think is most important. Look at the actual code — read the changed files, understand what they do, and give your honest assessment.
```

Placeholders (filled by the coordinator):
- `{SCOPE_DESCRIPTION}` — e.g. "Changes on branch feature/auth compared to main" or "Commit abc123: Add user validation"
- `{GIT_RANGE_INSTRUCTIONS}` — e.g. "Run `git diff main...HEAD` to see the changes" or "Run `git show abc123` to see the commit"

- [ ] **Step 2: Commit**

```bash
git add prompts/reviewers/kiro.md
git commit -m "Add Kiro reviewer prompt template"
```

---

### Task 3: Gemini Reviewer Prompt

**Files:**
- Create: `prompts/reviewers/gemini.md`

- [ ] **Step 1: Write Gemini review prompt template**

This template is interpolated by the coordinator and passed to `gemini -p "<interpolated prompt>" -e code-review -y -o text`. Similar to Kiro — provide context, let the tool's native review style take over.

```markdown
Review the code changes in this git repository.

{SCOPE_DESCRIPTION}

{GIT_RANGE_INSTRUCTIONS}

Give a thorough code review. Focus on whatever you think is most important — bugs, security, design, testing, performance, maintainability. Be specific with file and line references.
```

Same placeholders as kiro.md, filled by the coordinator.

- [ ] **Step 2: Commit**

```bash
git add prompts/reviewers/gemini.md
git commit -m "Add Gemini reviewer prompt template"
```

---

### Task 4: Verifier Subagent Prompt

**Files:**
- Create: `prompts/verifier.md`

- [ ] **Step 1: Write verifier prompt template**

The verifier receives all 4 raw reviews and the git range. It assesses claims — it does NOT add new findings or produce the final report.

```markdown
# Claim Verifier

You are verifying claims made by code reviewers. Your job is to assess the validity of their assertions — not to add new findings or produce a final report.

## Review Scope

{SCOPE_DESCRIPTION}

Git range: `{BASE_SHA}..{HEAD_SHA}` (if available — the coordinator must resolve concrete SHAs before invoking the verifier, even for vague inputs)

**Original review files:** `{SESSION_DIR}/` — contains `claude.md`, `codex.md`, `kiro.md`, `gemini.md`. If the reviews below were summarized by the coordinator, you can read the original files for full detail.

## Reviewer Outputs

### Claude Review
{CLAUDE_REVIEW}

### Codex Review
{CODEX_REVIEW}

### Kiro Review
{KIRO_REVIEW}

### Gemini Review
{GEMINI_REVIEW}

## Your Task

1. Read through all four reviews and extract concrete, verifiable assertions. Examples:
   - "Function X doesn't handle null" — verifiable, read the code
   - "Tests don't cover the error path" — verifiable, read the tests
   - "This could be slow at scale" — opinion, mark Unverifiable
   - "SQL injection risk in query builder" — verifiable, read the code

2. For each verifiable claim, use your judgment on how to check it:
   - **Read the code** for assertions about what code does or doesn't do
   - **Run tests** if a reviewer questions test correctness or coverage
   - **Cross-reference reviewers** to flag contradictions (reviewer A says X is fine, reviewer B says X is broken)
   - **Skip verification** for subjective opinions, style preferences, or vague suggestions — tag as Unverifiable

3. Tag each claim:
   - **Confirmed** — you found evidence supporting the claim. Cite the evidence (file:line, test output, etc.)
   - **Refuted** — you found evidence contradicting the claim. Explain what you found.
   - **Unverifiable** — you can't practically check this claim. Explain why.

## Output Format

Return a structured list of claims. For each claim:

```
### Claim: "<the assertion>"
- **Source:** <which reviewer(s)>
- **Status:** Confirmed | Refuted | Unverifiable
- **Evidence:** <what you found, with file:line references or test output>
- **Notes:** <any additional context>
```

List all claims. Do not skip any. Do not add new findings — only verify what the reviewers said.

If two reviewers contradict each other, verify both claims and note the contradiction explicitly.
```

- [ ] **Step 2: Commit**

```bash
git add prompts/verifier.md
git commit -m "Add verifier subagent prompt template"
```

---

### Chunk 1 Verification

- [ ] **Verify all files exist and placeholders are consistent**

```bash
# Check all Chunk 1 files exist
ls CLAUDE.md prompts/reviewers/kiro.md prompts/reviewers/gemini.md prompts/verifier.md

# Check placeholder consistency — all templates should use the same names
grep -h '{[A-Z_]*}' prompts/reviewers/kiro.md prompts/reviewers/gemini.md prompts/verifier.md | sort -u
```

Expected placeholders across all templates:
- `{SCOPE_DESCRIPTION}` — in kiro.md, gemini.md, verifier.md
- `{GIT_RANGE_INSTRUCTIONS}` — in kiro.md, gemini.md
- `{BASE_SHA}`, `{HEAD_SHA}` — in verifier.md
- `{CLAUDE_REVIEW}`, `{CODEX_REVIEW}`, `{KIRO_REVIEW}`, `{GEMINI_REVIEW}` — in verifier.md

If any file is missing or placeholder names don't match, fix before proceeding.

---

## Chunk 2: Coordinator Prompt and Skill

### Task 5: Coordinator Subagent Prompt

**Files:**
- Create: `prompts/coordinator.md`

This is the most complex piece — the coordinator orchestrates all three phases (dispatch reviewers, verify, synthesize).

- [ ] **Step 1: Write coordinator prompt template**

```markdown
# Committee Coordinator

You are the coordinator for a multi-perspective code review. You will orchestrate four parallel code reviews, verify their claims, and synthesize a single structured report.

## Review Context

{REVIEW_CONTEXT}

## Setup

First, create a temp directory for this review session:
```bash
SESSION_DIR=$(mktemp -d /tmp/committee-XXXXXX)
```

All reviewer outputs will be written to files in this directory rather than returned directly into your context. This gives you control over context management.

## Phase 1: Dispatch Reviewers

Dispatch all four reviewers in parallel. Use a single message with multiple tool calls. Each reviewer writes output to a temp file.

### Reviewer 1: Claude (superpowers:code-reviewer)

Dispatch via Agent tool with `subagent_type: "superpowers:code-reviewer"`. Add to the prompt: "Write your complete review to `{SESSION_DIR}/claude.md` using the Write tool before returning."

The prompt should follow the code-reviewer template pattern:
- WHAT_WAS_IMPLEMENTED: The changes being reviewed
- PLAN_OR_REQUIREMENTS: "General code review — no specific plan"
- BASE_SHA: {BASE_SHA}
- HEAD_SHA: {HEAD_SHA}
- DESCRIPTION: {SCOPE_DESCRIPTION}

### Reviewer 2: Codex

Dispatch via Bash tool with a 5-minute (300000ms) timeout. Pipe output to temp file:

For branch diff:
```bash
codex review --base {BASE_BRANCH} > {SESSION_DIR}/codex.md 2>&1
```

For single commit:
```bash
codex review --commit {COMMIT_SHA} > {SESSION_DIR}/codex.md 2>&1
```

For uncommitted changes:
```bash
codex review --uncommitted > {SESSION_DIR}/codex.md 2>&1
```

### Reviewer 3: Kiro

Read the prompt template at `prompts/reviewers/kiro.md`. Fill in the placeholders:
- `{SCOPE_DESCRIPTION}` — describe the changes
- `{GIT_RANGE_INSTRUCTIONS}` — tell Kiro what git command to run

Dispatch via Bash tool with a 5-minute (300000ms) timeout. Pipe output to temp file:
```bash
kiro-cli chat --no-interactive --trust-tools=fs_read "<filled prompt>" > {SESSION_DIR}/kiro.md 2>&1
```

### Reviewer 4: Gemini

Read the prompt template at `prompts/reviewers/gemini.md`. Fill in the placeholders (same as Kiro).

Dispatch via Bash tool with a 5-minute (300000ms) timeout. Pipe output to temp file:
```bash
gemini -p "<filled prompt>" -e code-review -y -o text > {SESSION_DIR}/gemini.md 2>&1
```

### Mapping Scope to CLI Flags

The skill has already resolved the review scope and provided it in `{REVIEW_CONTEXT}`. Do NOT re-resolve scope. Map the provided context to each tool's CLI flags:

- **Scope type: branch_diff** → `codex review --base {BASE_BRANCH}`. For Kiro/Gemini prompts, reference `git diff {BASE_BRANCH}...HEAD`.
- **Scope type: commit** → `codex review --commit {COMMIT_SHA}`. For Kiro/Gemini, reference `git show {COMMIT_SHA}`.
- **Scope type: uncommitted** → `codex review --uncommitted`. For Kiro/Gemini, reference `git diff` (unstaged) and `git diff --staged`.
- **Scope type: pr** → `codex review --base {BASE_BRANCH}`. For Kiro/Gemini, reference the PR diff.

## Phase 2: Verify Claims

After all reviewers return (or timeout/fail), collect the results.

**Handling failures explicitly:** For each Bash reviewer (Codex, Kiro, Gemini), check the result:
- Non-zero exit code → failure. Record: "<Reviewer>: exited with code N"
- Timeout (Bash tool returns timeout error) → failure. Record: "<Reviewer>: timed out after 5 minutes"
- Empty output → failure. Record: "<Reviewer>: returned empty output"
- Error message instead of review content → failure. Record: "<Reviewer>: <first line of error>"
For the Claude subagent, if the Agent tool returns an error, record it the same way.

**Check quorum:** If fewer than 2 reviewers succeeded, STOP. Report the failures to the user:

```
## Committee Code Review — ABORTED

**Reason:** Only N of 4 reviewers completed successfully. Minimum quorum is 2.

**Failures:**
- <Reviewer>: <failure reason>
...

**Successful reviews are not shown** — insufficient reviewer diversity for a reliable committee review.
```

**If quorum met:** Check the size of each review before reading it into your context:

```bash
wc -l {SESSION_DIR}/claude.md {SESSION_DIR}/codex.md {SESSION_DIR}/kiro.md {SESSION_DIR}/gemini.md 2>/dev/null
```

**Context management:** For each review file:
- **Default (most reviews):** Read the file directly into your context. Most reviews will be a reasonable size.
- **If a review is large** (use your judgment, but ~500+ lines is a signal): Dispatch a summarizer subagent instead. Give it the file path and ask it to return a condensed summary that preserves all concrete claims, findings, and recommendations while removing verbose explanations.

Read the verifier prompt template at `prompts/verifier.md`. Fill in:
- `{SCOPE_DESCRIPTION}` — same as what you gave reviewers
- `{BASE_SHA}` and `{HEAD_SHA}` — the git range
- `{CLAUDE_REVIEW}` — review content (read directly or summarized) or "REVIEWER FAILED: <reason>"
- `{CODEX_REVIEW}` — same
- `{KIRO_REVIEW}` — same
- `{GEMINI_REVIEW}` — same

Also provide the temp file paths to the verifier so it can read original reviews if needed:
- `{SESSION_DIR}` — the temp directory containing all review files

Dispatch the verifier as a subagent via the Agent tool. Wait for it to return.

## Phase 3: Synthesize

Now produce the final report. You have:
- The raw review outputs
- The verifier's annotated claims

Synthesize into this format:

```
## Committee Code Review

**Scope:** {scope_description} ({base_sha}..{head_sha}, N files changed)
**Reviewers:** {list of reviewers that succeeded, note any that failed}

### Critical (Must Fix)
1. **<finding title>**
   - Flagged by: <reviewer(s) who raised this>
   - Status: ✅ Confirmed | ❌ Refuted | ⚠️ Unverifiable
   - Evidence: <file:line reference, test output, or verification notes>
   - Recommendation: <how to fix, if not obvious>

### Important (Should Fix)
<same format>

### Minor (Nice to Have)
<same format>

### Contradictions
- **<topic>**: <Reviewer A> says X, <Reviewer B> says Y.
  Verification found: <what the verifier determined, or "unresolvable">

### Unverifiable Claims
- "<claim>" (<reviewer>) — <why it couldn't be verified>

### Verdict
**Ready to merge?** Yes / No / With fixes
**Reasoning:** <1-2 sentences based on the verified evidence>
```

**Synthesis rules:**
- **Deduplicate.** Same issue from multiple reviewers = one entry, multiple attributions.
- **Keep refuted claims.** Show them in their severity section so the user sees what was checked and dismissed.
- **Assign severity from evidence.** A reviewer calling something "critical" that the verifier refuted → downgrade or keep with ❌ status.
- **Omit empty sections.** If no Critical findings, skip that section entirely.
- **Be honest about failures.** If a reviewer failed, say so in the header. Don't pretend you had 4 reviews when you had 3.
```

- [ ] **Step 2: Commit**

```bash
git add prompts/coordinator.md
git commit -m "Add coordinator subagent prompt template"
```

---

### Task 6: Skill Definition (SKILL.md)

**Files:**
- Create: `skills/committee/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

The skill is the single source of truth for review scope. It parses user input, resolves it to concrete git context (SHAs, branch, scope type), and dispatches the coordinator with that resolved context. The coordinator never re-resolves scope.

```markdown
---
name: committee
description: Run parallel code reviews from Claude, Codex, Kiro, and Gemini, verify claims, and synthesize a structured report. Use when you want a thorough multi-perspective review.
---

# Committee Code Review

Run a multi-perspective code review using four AI reviewers in parallel.

## Input Parsing

The user invokes `/committee` with optional arguments. Parse them to determine review scope:

1. Check for explicit flags:
   - `--base <branch>` → branch diff
   - `--commit <sha>` → single commit
2. Check for PR reference:
   - `#<number>` or a GitHub PR URL → PR review
3. Check for freeform text:
   - Anything else → pass as vague context
4. No arguments:
   - Auto-detect scope

## Context Gathering

Based on the parsed input, gather whatever concrete context you can. Run these commands as appropriate:

**For auto-detect (no args):**
```bash
# Check for uncommitted changes
git status --porcelain

# Check current branch
git rev-parse --abbrev-ref HEAD

# If on a feature branch, get the diff stat
git diff --stat main...HEAD 2>/dev/null || git diff --stat master...HEAD 2>/dev/null

# Get recent commits
git log --oneline -5
```

**For explicit git range:**
```bash
git diff --stat {base}...HEAD
git rev-parse HEAD
```

**For PR:**
```bash
gh pr view {number} --json title,baseRefName,headRefName,body
gh pr diff {number} --stat
```

**For vague input (e.g., "review the auth changes"):**
```bash
# You must resolve this to concrete git context. Use the description to find relevant commits:
git log --oneline --all --grep="auth" | head -10
# Or look at recently changed files:
git log --oneline -10 --name-only
# Then determine the appropriate scope type (branch_diff, commit, etc.) and resolve SHAs
```

**Always resolve to concrete context.** The coordinator does not re-resolve scope — it trusts what you provide.

## Dispatch Coordinator

Read the coordinator prompt template at `prompts/coordinator.md`.

Construct the `{REVIEW_CONTEXT}` section from the resolved context:

```
Scope type: <branch_diff | commit | uncommitted | pr>
Scope: <human-readable description>
Base SHA: <resolved SHA>
Head SHA: <resolved SHA>
Base branch: <branch name, if applicable>
PR number: <if applicable>
Diff stat:
<output of git diff --stat>
User's original input: <the raw args to /committee>
```

Dispatch a single subagent via the Agent tool:
- Description: "Committee code review"
- Prompt: The filled coordinator prompt
- Run in foreground (you need the result)

## Display Result

The coordinator returns the final synthesized report. Display it directly to the user — it's already formatted as markdown.

If the coordinator reports an abort (quorum not met), display that message instead.
```

- [ ] **Step 2: Commit**

```bash
git add skills/committee/SKILL.md
git commit -m "Add /committee skill definition"
```

---

### Task 7: Smoke Test

This is not automated testing — it's a manual verification that the skill works end-to-end.

- [ ] **Step 1: Verify prerequisites**

```bash
which codex && echo "codex: OK" || echo "codex: MISSING"
which kiro-cli && echo "kiro-cli: OK" || echo "kiro-cli: MISSING"
which gemini && echo "gemini: OK" || echo "gemini: MISSING"
```

All three must be present. If any are missing, install before proceeding.

- [ ] **Step 2: Verify authentication**

```bash
# Codex — should not error
codex review --commit HEAD 2>&1 | head -5

# Kiro — should not error about auth
kiro-cli chat --no-interactive "Say hello" 2>&1 | head -5

# Gemini — should not error about auth
gemini -p "Say hello" -o text 2>&1 | head -5
```

If any fail with auth errors, fix authentication before proceeding.

- [ ] **Step 3: Run /committee against this repo**

In a Claude Code session in the committee directory:

```
/committee --commit HEAD
```

This should:
1. Parse `--commit HEAD` as a single-commit review
2. Gather the HEAD commit SHA and diff stat
3. Dispatch the coordinator subagent
4. Coordinator dispatches 4 reviewers in parallel
5. Coordinator dispatches verifier
6. Coordinator synthesizes and returns the report

Verify the output contains:
- A `## Committee Code Review` header
- Scope information
- Reviewer attributions
- Findings with verification status
- A verdict

- [ ] **Step 4: Test auto-detect mode**

```
/committee
```

On the main branch with no uncommitted changes, this should review the last commit (same as `--commit HEAD`).

- [ ] **Step 5: Commit any fixes**

If smoke testing revealed issues with the prompts, fix them and commit:

```bash
git add -A
git commit -m "Fix issues found during smoke testing"
```
