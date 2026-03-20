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
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || \
git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || \
# Last resort: check for common names
git rev-parse --verify main >/dev/null 2>&1 && echo "main" || \
git rev-parse --verify master >/dev/null 2>&1 && echo "master"
# Note: checking local main/master last — a stray local branch with that
# name does not mean it's the default upstream branch

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

Always resolve to concrete SHAs. If you cannot resolve the scope, tell the user what's ambiguous rather than dispatching with incomplete context. For example:

> "Could not identify relevant commits for 'auth changes'. Recent commits: [list from git log --oneline -5]. Did you mean one of these? You can also use `/committee --commit <sha>` or `/committee --base <branch>` to be explicit."

## Setup

Create a temp directory for reviewer outputs. The skill creates this — not the coordinator — because the Claude reviewer is dispatched here.

```bash
SESSION_DIR=$(mktemp -d /tmp/committee-XXXXXX) && echo "$SESSION_DIR"
```

Note the SESSION_DIR path. You will write Claude's review here and pass it to the coordinator.

## Dispatch Claude Reviewer

The skill runs at the top level of the Claude Code session where `superpowers:code-reviewer` is available. Dispatch it here, before the coordinator, so the coordinator doesn't need plugin access.

Dispatch via Agent tool with `subagent_type: "superpowers:code-reviewer"`:
- WHAT_WAS_IMPLEMENTED: The changes being reviewed (use the scope description)
- PLAN_OR_REQUIREMENTS: Check the user's original input for a spec or plan file path. If referenced, use it. Otherwise: "General code review — no specific plan".
- BASE_SHA: The resolved base SHA (omit for uncommitted scope)
- HEAD_SHA: The resolved head SHA
- DESCRIPTION: Human-readable scope description

**Uncommitted scope:** Omit BASE_SHA/HEAD_SHA and describe the uncommitted changes in WHAT_WAS_IMPLEMENTED instead.

**Fallback:** If the Agent tool returns an error (plugin not available), dispatch `general-purpose` instead with the prompt template at `prompts/reviewers/claude.md`, filling in the same placeholders.

**After the subagent returns:** Write its response to `$SESSION_DIR/claude.md` using the Write tool. Record whether this succeeded or failed.

## Dispatch Coordinator

Read the coordinator prompt template at `prompts/coordinator.md`.

Construct the `{REVIEW_CONTEXT}` section from the resolved context:

```
Scope type: <branch_diff | commit | uncommitted | pr | sha_range>
Scope: <human-readable description>
Base SHA: <resolved SHA or "none" for uncommitted>
Head SHA: <resolved SHA>
Base branch: <branch name, if applicable>
PR number: <if applicable>
Diff stat:
<output of the diff --stat command>
Session dir: <the SESSION_DIR path>
Claude review: <"ready" if claude.md was written successfully, or "REVIEWER FAILED: <reason>">
User's original input: <the raw args passed to /committee>
```

Dispatch a single subagent via the Agent tool:
- Description: "Committee code review"
- Prompt: The coordinator prompt with {REVIEW_CONTEXT} filled in
- Run in foreground (you need the result to display to the user)

## Display Result

The coordinator returns the final synthesized report. Display it directly to the user — it is already formatted as markdown.

If the coordinator reports an abort (quorum not met), display that message instead.
