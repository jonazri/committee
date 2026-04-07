---
name: committee
description: Run parallel code reviews from Claude, Codex, Kiro, and Gemini, verify claims, and synthesize a structured report. Use for code diffs, standalone file reviews, or implementation plan reviews.
---

# Committee Code Review

Run a multi-perspective code review using four AI reviewers in parallel.

## Input Parsing

The user invokes `/committee` with optional arguments. Parse them to determine review scope:

1. Check for explicit flags:
   - `--base <branch>` → branch diff
   - `--commit <sha>` → single commit
   - `--range <sha1>..<sha2>` → explicit SHA range (note: `...` three-dot is normalized to `..` two-dot — tell the user if this happens)
   - `--files <path1> [path2...]` → file review (not a diff — review the files themselves)
   - `--plan <path>` → plan review (review an implementation plan for quality, completeness, feasibility)
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

**For `--files <path1> [path2...]` (file review):**

Read each file and concatenate them into a single review document. This is NOT a diff — reviewers see the complete file contents and review them for quality, bugs, design, etc.

```bash
# For each file path provided:
cat <path1> <path2> ... # verify files exist
wc -l <path1> <path2> ... # get line counts
```

Scope type: files, Base SHA: none, Head SHA: none.

The file list and a brief summary (names + line counts) go into REVIEW_CONTEXT. The full file contents are written to `{SESSION_DIR}/diff.txt` during setup (the precompute step), with each file preceded by a header:
```
=== FILE: <path> ===
<file contents>
```

**For `--plan <path>` (plan review):**

Read the plan file. Reviewers evaluate it as an implementation plan — not code. Review criteria shift to: completeness, feasibility, task decomposition, architectural soundness, missing edge cases, YAGNI violations, and whether the plan is actionable by an implementing agent.

```bash
cat <path>  # verify plan file exists
wc -l <path>
```

Scope type: plan, Base SHA: none, Head SHA: none.

If the user's input also mentions a spec file (e.g., `/committee --plan plan.md --spec spec.md` or "review this plan against the spec at spec.md"), note it as Additional context in REVIEW_CONTEXT so reviewers can cross-reference.

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
Set `Head SHA = <sha>` in REVIEW_CONTEXT. For `Base SHA`, use `<sha>~1` — but check first:
```bash
git rev-parse <sha>~1 2>/dev/null || echo "none"
```
If the commit is the repo's initial commit, `<sha>~1` doesn't exist — set `Base SHA: none` and the verifier will fall back to reading the diff file.

**For PR (`#123` or PR URL):**
```bash
gh pr view <number> --json title,baseRefName,headRefName,url

# Fetch PR head AND refresh base branch tracking ref
git fetch origin "refs/pull/<number>/head:refs/pull/<number>/head"
git fetch origin <baseRefName>

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

**Shell safety:** When constructing bash commands with branch names, PR refs, or user-provided strings, always quote them in the bash command (e.g., `git merge-base "origin/$BASE_REF" "refs/pull/$NUM/head"`). Branch names can contain characters that are valid in git but dangerous in shell.

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
git diff HEAD > "{SESSION_DIR}/diff.txt" 2>&1
git diff --stat HEAD > "{SESSION_DIR}/diff_stat.txt" 2>&1
```

For commit scope:
```bash
git show {COMMIT_SHA} > "{SESSION_DIR}/diff.txt" 2>&1
git show --stat {COMMIT_SHA} > "{SESSION_DIR}/diff_stat.txt" 2>&1
```

For files scope:
```bash
# Concatenate all files with headers into diff.txt
for f in <path1> <path2> ...; do
  echo "=== FILE: $f ===" >> "{SESSION_DIR}/diff.txt"
  cat "$f" >> "{SESSION_DIR}/diff.txt"
  echo "" >> "{SESSION_DIR}/diff.txt"
done
# Create a stat summary
wc -l <path1> <path2> ... > "{SESSION_DIR}/diff_stat.txt" 2>&1
```

For plan scope:
```bash
cp <plan_path> "{SESSION_DIR}/diff.txt"
wc -l <plan_path> > "{SESSION_DIR}/diff_stat.txt" 2>&1
```

### Trust level dialog

Use the AskUserQuestion tool to present a proper selection menu:

```
AskUserQuestion:
  questions:
    - question: "What access level should CLI reviewers (Kiro, Gemini) have?"
      header: "Trust level"
      multiSelect: false
      options:
        - label: "Read-only (Recommended)"
          description: "Reviewers read the precomputed diff file only. No shell access. Safe for untrusted code."
        - label: "Sandboxed (nah)"
          description: "Reviewers have shell access guarded by nah — context-aware safety hook that classifies commands and blocks dangerous operations. Requires nah to be installed (pip install nah)."
        - label: "Full access"
          description: "Reviewers can explore the repo autonomously (git log, grep, blame). Allows arbitrary command execution if diff contains adversarial content."
```

Record the user's selection. Default to read-only if no answer.

**If "Sandboxed (nah)" is selected:** Verify nah is installed:
```bash
which nah
```
If not found, tell the user: "nah is not installed. Install with `pip install nah && nah install`, then retry. Falling back to read-only mode." and use read-only.

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

**Files scope:** Set WHAT_WAS_IMPLEMENTED to "Source files for review: <file list>". Set PLAN_OR_REQUIREMENTS to "General code review — review the files for quality, bugs, design, security." Omit BASE_SHA/HEAD_SHA. Append to the prompt: "The files to review are at `<SESSION_DIR>/diff.txt`, each preceded by a `=== FILE: <path> ===` header. Read that file."

**Plan scope:** Set WHAT_WAS_IMPLEMENTED to "Implementation plan: <plan path>". Set PLAN_OR_REQUIREMENTS to the spec file if referenced, otherwise "Review this plan for completeness, feasibility, task decomposition, and architectural soundness." Omit BASE_SHA/HEAD_SHA. Append to the prompt: "The plan to review is at `<SESSION_DIR>/diff.txt`. Read it and evaluate whether an implementing agent could follow it without ambiguity."

**Fallback:** If the background dispatch fails, dispatch `general-purpose` instead with the prompt template at `prompts/reviewers/claude.md` (or `~/.claude/skills/committee/prompts/reviewers/claude.md` for user-scope), filling in these placeholders (also in background):
- `{WHAT_WAS_IMPLEMENTED}` — scope description
- `{PLAN_OR_REQUIREMENTS}` — spec path if mentioned, else "General code review — no specific plan" (appears twice in template — fill both with the same value)
- `{DESCRIPTION}` — same as WHAT_WAS_IMPLEMENTED
- `{BASE_SHA}` — resolved base SHA (omit for uncommitted scope)
- `{HEAD_SHA}` — resolved head SHA
- `{COMMIT_SHA}` — same as HEAD_SHA for commit scope; omit for other scopes

### Step 2: Dispatch coordinator in foreground (immediately after)

Read the coordinator prompt template. Check these locations in order:
1. `prompts/coordinator.md` (project-scope install)
2. `~/.claude/skills/committee/prompts/coordinator.md` (user-scope install)

Construct the `{REVIEW_CONTEXT}` section from the resolved context:

```
Scope type: <branch_diff | commit | uncommitted | pr | sha_range | files | plan>
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
Trust level: <read-only | nah | full-access>
Claude review: background (coordinator must poll for SESSION_DIR/claude.md)
User's original input: <the raw args passed to /committee>
```

Dispatch a single subagent via the Agent tool:
- Description: "Committee code review"
- Prompt: The coordinator prompt with {REVIEW_CONTEXT} filled in
- Run in foreground (you need the result to display to the user)

## Handle Coordinator Failure

If the coordinator agent returns an error, times out, or returns an empty/malformed report:

1. **Do NOT delete the session directory.** The review files may still be useful.
2. Check which review files exist and their sizes:
   ```bash
   wc -c "{SESSION_DIR}"/*.md 2>/dev/null
   ```
3. If review files exist, inform the user:
   > "Coordinator failed to synthesize. Individual reviews are available at `{SESSION_DIR}/`. I can read them directly and produce a synthesis."
4. Read the available review files yourself (use `offset` and `limit` if any exceed 10K tokens) and produce a manual synthesis following the same Critical/Important/Minor format the coordinator would have used.
5. Clean up the session directory only after presenting results to the user.

## Evaluate and Display Result

Before presenting the coordinator's report to the user, apply `superpowers:receiving-code-review` to evaluate the findings:

```
Skill tool: superpowers:receiving-code-review
```

This will guide you to treat the committee report as external reviewer feedback — verify technical claims against the actual codebase, check whether findings hold for this specific project, and flag any suggestions that seem questionable. Do not performatively accept all findings; evaluate each one.

After evaluation, present the report to the user with any technically unsound or questionable findings annotated with your assessment.

**CRITICAL — recommendations only, no implementation:**
The committee report is advisory. You MUST NOT implement any suggestions, make any code changes, or take any action on the findings without the user's explicit consent. Present the report, then wait for the user to decide what to act on. Do not say "let me fix these" or start editing files. The user drives what happens next.

If the coordinator reports an abort (quorum not met), display that message instead — no evaluation needed.
