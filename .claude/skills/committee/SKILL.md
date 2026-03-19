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
   - Anything else → treat as vague context, resolve below
4. No arguments:
   - Auto-detect scope

## Context Gathering

You are the single source of truth for review scope. Resolve the input to concrete git context before dispatching the coordinator. The coordinator does not re-resolve scope.

**For auto-detect (no args):**
```bash
# Check for uncommitted changes
git status --porcelain

# Check current branch
git rev-parse --abbrev-ref HEAD

# Detect default branch dynamically
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'
# Falls back to: git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}'
# If neither works, fall back to trying main then master

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

# Fetch the PR branch so git diff works locally
gh pr checkout <number> --detach 2>/dev/null || git fetch origin "refs/pull/<number>/head:refs/pull/<number>/head"

gh pr diff <number> --stat
```

**For vague input (e.g., "review the auth changes"):**
```bash
# Use the description to find relevant commits
git log --oneline --all --grep="<keywords>" | head -10
# Or look at recently changed files
git log --oneline -10 --name-only
# Determine the appropriate scope type and resolve SHAs
```

Always resolve to concrete SHAs. If you cannot resolve the scope, tell the user what's ambiguous rather than dispatching with incomplete context.

## Dispatch Coordinator

Read the coordinator prompt template at `prompts/coordinator.md`.

Construct the `{REVIEW_CONTEXT}` section from the resolved context:

```
Scope type: <branch_diff | commit | uncommitted | pr>
Scope: <human-readable description>
Base SHA: <resolved SHA or "none" for uncommitted>
Head SHA: <resolved SHA>
Base branch: <branch name, if applicable>
PR number: <if applicable>
Diff stat:
<output of the diff --stat command>
User's original input: <the raw args passed to /committee>
```

Dispatch a single subagent via the Agent tool:
- Description: "Committee code review"
- Prompt: The coordinator prompt with {REVIEW_CONTEXT} filled in
- Run in foreground (you need the result to display to the user)

## Display Result

The coordinator returns the final synthesized report. Display it directly to the user — it is already formatted as markdown.

If the coordinator reports an abort (quorum not met), display that message instead.
