# Committee → Workflow Migration (design)

**Status:** Approved design, 2026-06-01. Supersedes the coordinator-subagent half of the
original committee architecture (`docs/superpowers/specs/2026-03-17-committee-design.md`).

## Problem

`/committee` dispatches a **coordinator** as a subagent. Subagents cannot call the Agent/Task
tool (no nested agent spawning), so the coordinator cannot dispatch its verifiers as real
agents. It silently improvises `claude -p "$(cat …)" --model sonnet` CLI subprocesses. A
`/committee` review of that code (commit `b0e26cc`) confirmed the improvisation is fragile:
`2>/dev/null` + backgrounding discards exit codes and stderr (so the `--model sonnet` fallback
can never fire; failure detection is empty-file-only), and `claude -p "$(cat …)"` risks ARG_MAX.

A workflow's **runtime is the orchestrator** — it spawns every agent at the same level, so the
nesting limitation disappears, verifiers become real `agent({schema})` calls with validated
output, and `parallel()`/`pipeline()` express the fan-out deterministically. A proof-of-concept
(`committee-as-workflow-poc`) ran all four reviewers (Claude as an agent; Codex/Kiro/Gemini
shelling out inside agents, including the codex-stderr recovery) plus per-reviewer verifiers and
reached quorum 4 — confirming the CLI-in-agent path works.

## Goal / non-goals

- **Goal:** replace the coordinator half of `/committee` with a workflow that owns all four
  reviewers → per-reviewer verify → returns structured findings.
- **Non-goals:** changing the `/committee` external interface (flags, report format) or
  `/committee-loop` (it calls `/committee`, unchanged). No change to `prepare.sh`, scope
  resolution, the trust dialog, or `PROMPTS_DIR` resolution (the P1 fix stays).

## §1 Architecture & boundary

```
/committee SKILL.md (top-level agent)
  1. parse args, validate, trust dialog            ← unchanged
  2. prepare.sh → manifest, diff.txt, PROMPTS_DIR  ← unchanged
  3. Workflow({ name: "committee-review", args })  ← NEW (replaces Claude-dispatch + coordinator)
  4. receive structured result → superpowers:receiving-code-review
     → synthesize Critical/Important/Minor → present
  5. cleanup (rm sessionDir; delete PR ref)        ← skill-owned, AFTER presenting
committee-review.js (the workflow)
  phase Review:  parallel() — Claude (agent) + Codex/Kiro/Gemini (CLI-in-agent), trust-conditioned
  phase Verify:  pipeline() → per-reviewer verifier agent ({schema}, model: sonnet)
  return:        { quorum, degraded, perReviewer:[{reviewer, ran_ok, note, verified:[…]}] }
```

**Deletes:** `prompts/coordinator.md`, the `claude -p` verifier mechanism, the `claude.md`
poll (P3 becomes moot), and the skill's separate Claude-reviewer dispatch.
**Keeps:** `prepare.sh`, `PROMPTS_DIR` (P1), the trust dialog, the reviewer/verifier prompt
templates (now consumed by workflow agents), and skill-side synthesis + `receiving-code-review`.

## §2 Deployment & invocation

The workflow is a versioned file in the repo and is invoked **programmatically by the skill**
(not as a user-typed slash command), so named-workflow user-facing perks (slash command,
autocomplete) do not apply — the choice is purely resolution robustness.

- **Primary:** ship `committee-review.js` as a **user-scope named workflow**. `install.sh`
  symlinks it into `~/.claude/workflows/committee-review.js`. Per Claude Code docs, user-scope
  workflows "remain personal and available across all projects," which matches committee's
  global-install / review-any-repo model. Skill calls `Workflow({ name: "committee-review", args })`.
- **Open verification item (blocking for primary):** confirm in a **fresh session** that an
  install-*symlinked* workflow registers by name (the docs describe the `/workflows` save UI, not
  a symlink drop; the registry loads at session start). A mid-session hand-dropped `.js` did NOT
  resolve — that was a session-start-loading artifact, not proof of non-support.
- **Fallback (if symlink registration does not take):** keep the file under the already-symlinked
  `prompts/` tree (e.g. `prompts/committee-review.js`) and invoke
  `Workflow({ scriptPath: "$PROMPTS_DIR/committee-review.js", args })` — an absolute,
  install-resolved path is cwd-independent and needs no registry. The script body is identical
  either way; only the invocation line differs.

**Repo source location:** one file, `prompts/committee-review.js` (rides the existing `prompts/`
symlink, so the `scriptPath` fallback needs no new install step). For the primary path,
`install.sh` adds one symlink: `~/.claude/workflows/committee-review.js` → repo
`prompts/committee-review.js`. A single repo file serves both invocation styles.

## §3 Args contract & data flow

The skill passes one `args` object (the workflow script cannot read files; its agents do):

```js
args = {
  scopeType, scopeDescription,
  baseSha, headSha, commitSha, baseBranch, headBranch, prNumber, prBaseRef,
  sessionDir, promptsDir,              // absolute paths (promptsDir = P1 resolution)
  diffPath, diffStatPath, staticPath,  // precomputed by prepare.sh
  trust,                               // 'auto' | 'read-only'
  reviewerModel,                       // optional → Claude reviewer agent
  userInput,                           // raw /committee args, sentinel-fenced (untrusted data)
}
```

Flow:
1. Skill → `prepare.sh` → builds `args` → `Workflow(...)`.
2. **phase Review** — `parallel()` of 4 agents; each reads its template from `promptsDir` and
   fills from `args`, runs, returns `FINDINGS`.
3. **phase Verify** — `pipeline()`: each reviewer's findings → verifier agent (reads
   `verifier.md`, `model:"sonnet"`), returns `VERIFIED`.
4. Workflow returns the structured result object (no file re-reads).
5. Skill synthesizes from the structured result, applies `receiving-code-review`, presents, then
   cleans up.

Schemas (validated at the agent boundary):

```
FINDINGS = { reviewer, ran_ok, note?, findings:[{severity:critical|important|minor, file, title, detail}] }
VERIFIED = { reviewer, verified:[{title, severity, verdict:confirmed|refuted|unverifiable, evidence}] }
```

## §4 Error handling, quorum, trust, codex

- **Per-reviewer isolation:** each reviewer agent catches its own CLI failure → `{ran_ok:false, note}`;
  `parallel()` turns a crashed agent into `null` (filtered). One reviewer failing never sinks the run.
- **Quorum:** workflow counts `ran_ok` reviewers; `<2` → `degraded:true`; skill reports degraded
  quorum (same policy as today's coordinator).
- **Codex recovery:** in the Codex agent's prompt — run `codex review` (note: `codex review`
  writes its review to STDERR), promote `codex.err` to the review on clean-exit-empty-stdout, then
  parse. Same logic as the current coordinator fix, relocated into the agent.
- **Trust:** from `args.trust`. `read-only` → no-shell CLI invocations (Kiro `--trust-tools=fs_read`,
  Gemini stdin-only, Claude reads `diffPath`); `auto` → shell-enabled flags. The reviewer agent is a
  launcher+parser, so the untrusted diff reaches the *CLI*, not the agent-as-instructions — same
  guarantee as today's read-only mode.
- **Workflow-level failure:** if the `Workflow` call itself errors, the skill reports failure and
  **preserves `sessionDir`** for manual inspection (no silent loss).

## §5 Verification (acceptance)

- Fresh-session check that `Workflow({name:"committee-review"})` resolves from the install symlink;
  if not, switch the invocation line to the `scriptPath` fallback.
- `/committee --commit <sha>` end-to-end: all four reviewers appear in the report (Codex included
  via stderr recovery); verifiers run as agents (no `claude -p`); report format unchanged.
- `--trust=read-only` run: CLI reviewers use no-shell invocations.
- A forced single-reviewer failure still produces a report on quorum.
- `/committee-loop` iter-2+ (which calls `/committee`) still works end-to-end.

## Out of scope / future

- Folding synthesis itself into the workflow (kept skill-side so `receiving-code-review` and the
  advisory `<no_implementation>` gate stay at the top level).
- Switching to a `name`-based invocation if/when a future CLI scans `~/.claude/workflows/` for
  symlinked files reliably (script body is unchanged; only the invocation differs).
