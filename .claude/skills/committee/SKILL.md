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
   - `--range <sha1>..<sha2>` → explicit SHA range
2. Check for bare SHA range pattern (e.g. `abc123..def456` or `abc123...def456`):
   - Matches `[0-9a-f]{6,40}\.\.\.?[0-9a-f]{6,40}` (two or three dots) → SHA range
   - Note: three-dot (`...`) symmetric diff semantics are not preserved — both are resolved as `sha1..sha2` two-dot range. Tell the user if they used `...` so they know the semantics shifted.
3. Check for PR reference:
   - `#<number>` or a GitHub PR URL → PR review
4. Check for freeform text:
   - Anything else → treat as vague context, resolve below
5. No arguments:
   - Auto-detect scope

## Context Gathering

You are the single source of truth for review scope. Resolve the input to concrete git context before dispatching the coordinator. The coordinator does not re-resolve scope.

**For `--range <sha1>..<sha2>` or bare SHA range:**
```bash
git rev-parse <sha1>           # resolve to full SHA
git rev-parse <sha2>           # resolve to full SHA
git diff --stat <sha1>..<sha2>
```
Scope type: sha_range, Base branch: none.

**For auto-detect (no args):**
```bash
# Check for uncommitted changes
git status --porcelain

# Check current branch
git rev-parse --abbrev-ref HEAD

# Detect default branch — remote tracking ref is most reliable
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'
# If that fails, try network (slower):
git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}'
# Last resort — local branch names only (use if/elif to avoid printing both):
if git rev-parse --verify main >/dev/null 2>&1; then
  echo "main"
elif git rev-parse --verify master >/dev/null 2>&1; then
  echo "master"
fi

# If on a feature branch, get the diff stat vs default branch
git diff --stat <default_branch>...HEAD

# Get recent commits for context
git log --oneline -5
```

Auto-detect priority: uncommitted changes → branch diff from default branch → last commit.

**For `--base <branch>`:**
```bash
git merge-base <branch> HEAD  # base SHA
git rev-parse HEAD             # head SHA
git diff --stat <branch>...HEAD
```

**For `--commit <sha>`:**
```bash
git rev-parse <sha>            # resolve to full SHA
git show --stat <sha>
```

**For PR (`#123` or PR URL):**
```bash
gh pr view <number> --json title,baseRefName,headRefName,url

# Fetch PR head as a stable local ref — no checkout, no state mutation
git fetch origin "refs/pull/<number>/head:refs/pull/<number>/head"

# Resolve SHAs — skill is the source of truth, coordinator must not re-resolve
BASE_SHA=$(git merge-base origin/<baseRefName> refs/pull/<number>/head)
HEAD_SHA=$(git rev-parse refs/pull/<number>/head)

gh pr diff <number> --stat
```

Set in REVIEW_CONTEXT:
- `Base SHA: <BASE_SHA from merge-base above>`
- `Head SHA: <HEAD_SHA from rev-parse above>`
- `Head branch: refs/pull/<number>/head` (the fetched ref — not the remote branch name)
- `PR cleanup ref: refs/pull/<number>/head` (coordinator cleans this up in Phase 3)

The coordinator maps PR scope to CLI flags using the pre-resolved SHAs and `refs/pull/<number>/head`. No `gh pr checkout` — that mutates the user's working tree.

**For vague input (e.g., "review the auth changes"):**
```bash
# Use the description to find relevant commits
git log --oneline --all --grep="<keywords>" | head -10
# Or look at recently changed files
git log --oneline -10 --name-only
# Determine the appropriate scope type and resolve SHAs
```

Always resolve to concrete SHAs. If you cannot resolve the scope, tell the user what's ambiguous rather than dispatching with incomplete context. For example:

> "Could not identify relevant commits for 'auth changes'. Recent commits: [list from git log --oneline -5]. Did you mean one of these? You can also use `/committee --commit <sha>` or `/committee --base <branch>` to be explicit."

## Progress Notification

Before running anything, tell the user the review has started and roughly how long it will take. Output a message like:

> Starting committee review of [scope description]. Running 4 reviewers in parallel — expect 8–10 minutes for the full report. I'll display it when complete.

Adjust the estimate based on scope: a single commit is ~5–8 min; a large multi-commit range (sha_range) is ~8–10 min.

## Setup

Create the session directory anchored to the project root. Using `git rev-parse --show-toplevel` ensures the path is correct even when Claude Code runs from a subdirectory. The `.committee/` directory is gitignored and accessible to all subagents via the Read tool.

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$PROJECT_ROOT/.committee"
SESSION_DIR=$(mktemp -d "$PROJECT_ROOT/.committee/session-XXXXXX") && echo "$SESSION_DIR"
# No trap here — trap fires on Bash subprocess exit (immediately), not session end.
# Cleanup is handled by the coordinator's explicit rm -rf at the end of Phase 3.
```

### Precompute the diff

Write the diff and diff stat to session files so reviewers don't need shell access to see the changes:

```bash
git diff {BASE_SHA}..{HEAD_SHA} > "{SESSION_DIR}/diff.txt" 2>&1
git diff --stat {BASE_SHA}..{HEAD_SHA} > "{SESSION_DIR}/diff_stat.txt" 2>&1
```

For uncommitted scope:
```bash
(git diff; git diff --staged) > "{SESSION_DIR}/diff.txt" 2>&1
(git diff --stat; git diff --staged --stat) > "{SESSION_DIR}/diff_stat.txt" 2>&1
```

For commit scope:
```bash
git show {COMMIT_SHA} > "{SESSION_DIR}/diff.txt" 2>&1
git show --stat {COMMIT_SHA} > "{SESSION_DIR}/diff_stat.txt" 2>&1
```

### Trust level dialog

Ask the user which trust level to use for CLI reviewers (Kiro, Gemini). This controls whether reviewers can explore the repo autonomously or are limited to reading the precomputed diff:

> **Reviewer access level:**
> 1. **Read-only** (recommended) — Reviewers read the precomputed diff file only. No shell access. Safe for untrusted code.
> 2. **Full access** — Reviewers can explore the repo autonomously (git log, grep, blame, etc). Richer reviews but exposes the repo to prompt injection from diff content.
>
> Choose [1] or [2] (default: 1):

Record the choice. If the user doesn't answer or says "1", use read-only. If they say "2" or "full", use full-access.

Note the SESSION_DIR path and trust level. You will pass both to the coordinator.

## Dispatch Claude Reviewer and Coordinator (in parallel)

The skill dispatches Claude in the background and the coordinator in the foreground simultaneously. This means Claude and the CLI reviewers (Codex, Kiro, Gemini) all run in parallel.

### Step 1: Dispatch Claude reviewer in background

Dispatch via Agent tool with `subagent_type: "superpowers:code-reviewer"` and `run_in_background: true`. Note: Agent tool has no explicit timeout — the coordinator's 10-minute polling window (20 × 30s) is the effective cap:
- WHAT_WAS_IMPLEMENTED: The changes being reviewed (use the scope description)
- PLAN_OR_REQUIREMENTS: Check the user's original input for a spec or plan file path. If referenced, use it. Otherwise: "General code review — no specific plan".
- BASE_SHA: The resolved base SHA (omit for uncommitted scope)
- HEAD_SHA: The resolved head SHA
- DESCRIPTION: Human-readable scope description

Append to the prompt: "Write your complete review to `<SESSION_DIR>/claude.md` using the Write tool before returning." (substitute the actual SESSION_DIR path)

**Uncommitted scope:** Omit BASE_SHA/HEAD_SHA and describe the uncommitted changes in WHAT_WAS_IMPLEMENTED instead.

**Fallback:** If the background dispatch fails, dispatch `general-purpose` instead with the prompt template at `prompts/reviewers/claude.md`, filling in these placeholders (also in background):
- `{WHAT_WAS_IMPLEMENTED}` — scope description
- `{PLAN_OR_REQUIREMENTS}` — spec path if mentioned, else "General code review — no specific plan" (appears twice in template — fill both with the same value)
- `{DESCRIPTION}` — same as WHAT_WAS_IMPLEMENTED
- `{BASE_SHA}` — resolved base SHA (omit for uncommitted scope)
- `{HEAD_SHA}` — resolved head SHA
- `{COMMIT_SHA}` — same as HEAD_SHA for commit scope; omit for other scopes

### Step 2: Dispatch coordinator in foreground (immediately after)

Read the coordinator prompt template at `prompts/coordinator.md`.

Construct the `{REVIEW_CONTEXT}` section from the resolved context:

```
Scope type: <branch_diff | commit | uncommitted | pr | sha_range>
Scope: <human-readable description>
Base SHA: <resolved SHA or "none" for uncommitted>
Head SHA: <resolved SHA or "none" for uncommitted>
Commit SHA: <resolved SHA, for commit scope only>
Base branch: <branch name, if applicable>
Head branch: <refs/pull/<n>/head for PR scope, or remote branch name otherwise>
PR number: <if applicable>
PR cleanup ref: <refs/pull/<n>/head — coordinator deletes this in Phase 3, if PR scope>
Diff stat:
<output of the diff --stat command>
Session dir: <the SESSION_DIR path>
Trust level: <read-only | full-access>
Claude review: background (coordinator must poll for SESSION_DIR/claude.md)
User's original input: <the raw args passed to /committee>
```

Dispatch a single subagent via the Agent tool:
- Description: "Committee code review"
- Prompt: The coordinator prompt with {REVIEW_CONTEXT} filled in
- Run in foreground (you need the result to display to the user)

## Evaluate and Display Result

Before presenting the coordinator's report to the user, apply `superpowers:receiving-code-review` to evaluate the findings:

```
Skill tool: superpowers:receiving-code-review
```

This will guide you to treat the committee report as external reviewer feedback — verify technical claims against the actual codebase, check whether findings hold for this specific project, and flag any suggestions that seem questionable. Do not performatively accept all findings; evaluate each one.

After evaluation, present the report to the user with any technically unsound or questionable findings annotated with your assessment.

If the coordinator reports an abort (quorum not met), display that message instead — no evaluation needed.
