# Committee → Workflow Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the coordinator-subagent half of `/committee` with a workflow that owns all four reviewers → per-reviewer verify → returns structured findings, eliminating the fragile `claude -p` verifier improvisation.

**Architecture:** The `/committee` skill keeps prep (scope, `prepare.sh`, diff, trust dialog, `PROMPTS_DIR`) and synthesis (`receiving-code-review` + Critical/Important/Minor report). A new workflow `prompts/committee-review.js` dispatches Claude + Codex/Kiro/Gemini in parallel, then per-reviewer verifier agents, and returns a structured result. The skill invokes it via `Workflow({name:"committee-review", args})` (scriptPath fallback).

**Tech Stack:** Claude Code skills (markdown), the Workflow tool (JS orchestration), Bash CLIs (codex/kiro/gemini), `prepare.sh`.

**Spec:** `docs/superpowers/specs/2026-06-01-committee-workflow-migration-design.md`

**Domain note:** This is prompt/workflow engineering. There is no unit-test harness; each task's verification step is a real smoke run, grep, or fresh-session check (the spec §5 acceptance criteria). Commit after each task.

**Grep-exit convention:** several verification steps below run a `grep` that "expects no matches". A `grep` with no match exits non-zero (1). Treat a non-zero exit / empty output from those "expect nothing" greps as **PASS**, not failure — do not let an automated executor read exit 1 there as a failed step.

---

## Execution preamble (read first)

**Driver:** execute task-by-task with `superpowers:subagent-driven-development` (fresh subagent per task, two-stage review between tasks) — or `superpowers:executing-plans` for inline batch execution.

**Verification gate (every task):** before checking a task's boxes done, invoke `superpowers:verification-before-completion` — run the task's verification step(s) and paste the ACTUAL output; never call a task green on assertion alone. Honor the **grep-exit convention** above. Task 1 Step 3 is an explicit BLOCKING gate — a green grep does not substitute for a successful smoke run.

**Order & dependencies:** tasks are sequential. CRITICAL ordering: Task 3 Step 1a (re-point the `PROMPTS_DIR` sentinel) and Task 2 Step 2 (re-point install.sh's existence guard) MUST land before Task 4 deletes `coordinator.md`, or every `/committee` run aborts. Decide `name` vs `scriptPath` in Task 2 Step 5 and carry that decision into Task 3 Step 1.

**Fresh-session steps (cannot run mid-session):** Task 2 Step 5 (named-workflow registration loads at session start) and all of Task 6 (live `/committee` loads the skill at session start) require a NEW Claude Code session — pause and restart at those points.

**Key commands & runtimes:**
- Smoke run (Task 1 Step 3): the `Workflow` tool, ~5–8 min (4 reviewers + verifiers).
- `./install.sh` (Task 2): idempotent symlink install, seconds.
- Full `/committee --commit <sha>` (Task 6 Step 1): ~5–8 min.
- `/committee-loop` regression (Task 6 Step 4): long (multi-iteration) — optional dry check.

**Context the executor needs:**
- Spec: `docs/superpowers/specs/2026-06-01-committee-workflow-migration-design.md`.
- Repo conventions/gotchas (`CLAUDE.md`): committee installs via **symlinks** (edits go live only on a fresh session); `codex review` writes its review to **stderr**; the Claude reviewer dispatches as the built-in **`general-purpose`** agent; `PROMPTS_DIR` resolves from the install location, never `$PROJECT_ROOT`.
- Deferred ledger (items intentionally NOT applied): `.git/committee-loop/<session>/deferred.md` — notably the read-only Gemini `-e code-review`-without-`-y` hang risk (confirm at Task 6 Step 2).

---

## File Structure

- **Create:** `prompts/committee-review.js` — the committee workflow (reviewers → verify → structured return). Repo source of truth; rides the `prompts/` symlink.
- **Modify:** `install.sh` — add one symlink `~/.claude/workflows/committee-review.js` → repo `prompts/committee-review.js`.
- **Modify:** `.claude/skills/committee/SKILL.md` — replace the "Dispatch Claude + coordinator" section with the Workflow invocation + result handling; keep prep, synthesis, cleanup.
- **Delete:** `prompts/coordinator.md` — its job moves into the workflow. (Reviewer/verifier/kiro/gemini templates stay — the workflow agents read them.)
- **Modify:** `CLAUDE.md`, `README.md` — reflect the workflow architecture.

---

## Task 1: Author the committee workflow script

**Files:**
- Create: `prompts/committee-review.js`

- [ ] **Step 1: Write the workflow script**

Create `prompts/committee-review.js` with this exact content:

```js
export const meta = {
  name: 'committee-review',
  description: 'Committee multi-reviewer code review: Claude + Codex/Kiro/Gemini in parallel, per-reviewer verify, structured return',
  phases: [
    { title: 'Review', detail: 'Claude + Codex/Kiro/Gemini in parallel' },
    { title: 'Verify', detail: 'per-reviewer claim verification' },
  ],
}

const a = args || {}
const trust = a.trust === 'read-only' ? 'read-only' : 'auto'
const baseSha = a.baseSha || 'none'
const headSha = a.headSha || 'none'
const commitSha = a.commitSha || 'N/A'

// Shell-quote a value for safe interpolation into a shell command: wrap in single
// quotes and escape any embedded single-quote as the POSIX '\'' idiom. Used for every
// path/branch that reaches a shell (a repo cloned under e.g. /home/o'reilly would
// otherwise break or inject). NOT used for agent-prose interpolations (Read-tool paths).
const shq = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'"

const FINDINGS = {
  type: 'object', additionalProperties: false,
  // `reviewer` is NOT required: the agent isn't prompted to emit it and the pipeline
  // backfills it (x.reviewer || r.name). Requiring it risks a schema-validation
  // failure/retry before the backfill runs.
  required: ['ran_ok', 'findings'],
  properties: {
    reviewer: { type: 'string' },
    ran_ok: { type: 'boolean', description: 'did this reviewer actually produce a review' },
    note: { type: 'string', description: 'how output was obtained, or failure reason' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['severity', 'file', 'title', 'detail'],
        properties: {
          severity: { type: 'string', enum: ['critical', 'important', 'minor'] },
          file: { type: 'string' }, title: { type: 'string' }, detail: { type: 'string' },
        },
      },
    },
  },
}

const VERIFIED = {
  type: 'object', additionalProperties: false,
  // `reviewer` backfilled by the verify stage (...v, reviewer: rev.reviewer); not required.
  required: ['verified'],
  properties: {
    reviewer: { type: 'string' },
    verified: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'severity', 'verdict', 'evidence'],
        properties: {
          title: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'important', 'minor'] },
          verdict: { type: 'string', enum: ['confirmed', 'refuted', 'unverifiable'] },
          evidence: { type: 'string' },
          file: { type: 'string', description: 'file:line carried from the finding (for synthesis attribution)' },
          detail: { type: 'string', description: 'finding detail carried through for synthesis' },
        },
      },
    },
  },
}

// Per-scope review lens — mirrors the SKILL.md table.
function lensFor(t) {
  if (t === 'pr') return 'Pull-request review. Treat the changes as one cohesive unit and assess whether they fully and safely accomplish the PR\'s stated purpose; flag anything that should block merge. Findings are independently re-verified downstream, so report genuine concerns rather than self-suppressing borderline ones.'
  if (t === 'plan') return 'Implementation-plan review. The content is a plan document, not code. Evaluate whether an implementing agent could follow it without ambiguity — missing steps, undefined terms, unstated assumptions, ordering hazards, verification gaps. Severity reflects how badly each gap would derail implementation.'
  if (t === 'files') return 'Standard code review of the source files provided (a set of files, not a diff).'
  if (t === 'uncommitted') return 'Code review of the uncommitted working-tree changes.'
  return 'Standard code review of the changes in the git range.'
}

// Scope-conditional focus areas — mirrors coordinator.md's {FOCUS_AREAS} so the CLI
// reviewers get the same coverage guidance the old coordinator filled in verbatim.
function focusAreas(t) {
  if (t === 'plan') return 'Completeness (every step described, no TODO/figure-out-X placeholders); feasibility with the named tools/APIs; task decomposition (single-session pieces); architectural soundness + missing edge cases (error paths, concurrency, partial failure); YAGNI; actionability (no unanticipated judgment calls)'
  if (t === 'files') return 'Code quality (clarity, duplication); correctness (logic, edge cases); security (injection, unsafe patterns); API contracts vs callers; design (coupling, layering, abstraction)'
  return 'Correctness (logic, off-by-one, edge cases, races); shell safety (quoting, injection, TOCTOU, temp-file races); API/contract consistency; error handling (unchecked exits, swallowed errors); security (priv-esc, data leakage); test coverage'
}

// How each reviewer should obtain the changes, by trust level.
const gitInstr = trust === 'read-only'
  ? `Read the precomputed diff at ${a.diffPath} (summary at ${a.diffStatPath}). Do NOT run git.`
  : (a.scopeType === 'commit'
      ? `Run: git show ${commitSha}`
      : (a.scopeType === 'files' || a.scopeType === 'plan' || a.scopeType === 'uncommitted'
          ? `Read ${a.diffPath} (the precomputed changes to review — files/plan content, or uncommitted diff).`
          : `Run: git diff ${baseSha}..${headSha}`))

const staticNote = a.staticPath
  ? `If ${a.staticPath} exists and is non-empty, also read it — advisory static-analysis findings; verify each applies before flagging.`
  : ''

// Spec/plan-requirements directive — mirrors coordinator.md's spec-read trigger for CLI reviewers.
const specNote = a.specPath ? `Also read ${a.specPath} for the design requirements behind these changes.` : ''

const claudePrompt = `You are committee's Claude reviewer. Working dir is the repo at ${a.projectRoot || '.'}.
Read the template at ${a.promptsDir}/reviewers/claude.md and follow it. Fill: WHAT_WAS_IMPLEMENTED=${a.scopeDescription}; PLAN_OR_REQUIREMENTS=${a.specPath || 'General code review — no specific plan'}; BASE_SHA=${baseSha}; HEAD_SHA=${headSha}; COMMIT_SHA=${commitSha}; REVIEW_LENS=${lensFor(a.scopeType)}.
${gitInstr}
${staticNote}
Return structured findings (set ran_ok=true).`

const codexPrompt = `Run the Codex CLI to review, then return its findings.
${staticNote}
${trust === 'read-only'
  ? `Read-only: review the precomputed diff at ${a.diffPath}. Run with a 540 s shell timeout (600 s for files/plan):\n  cd ${shq(a.projectRoot || '.')} && timeout ${(a.scopeType === 'files' || a.scopeType === 'plan') ? 600 : 540} codex exec -c model_reasoning_effort=high -s read-only --ephemeral -o ${shq(a.sessionDir)}/codex.md - 2> ${shq(a.sessionDir)}/codex.err <<'P'\nRead and review the precomputed diff at ${a.diffPath}. Do not explore beyond it. Output Critical/Important/Minor with file:line.\nP`
  : `Run with a 540 s shell timeout (600 s for files/plan — codex may explore aux code). Each branch cd's to the project root and self-redirects (codex review captures stdout; codex exec writes via -o):\n  cd ${shq(a.projectRoot || '.')} && ${a.scopeType === 'commit'
        ? `timeout 540 codex review -c model_reasoning_effort=high --commit ${commitSha} > ${shq(a.sessionDir)}/codex.md 2> ${shq(a.sessionDir)}/codex.err`
        : a.scopeType === 'branch_diff'
          ? `timeout 540 codex review -c model_reasoning_effort=high --base '${a.baseBranch.replace(/'/g, "'\\''")}' > ${shq(a.sessionDir)}/codex.md 2> ${shq(a.sessionDir)}/codex.err`
          : a.scopeType === 'uncommitted'
            ? `timeout 540 codex review -c model_reasoning_effort=high --uncommitted > ${shq(a.sessionDir)}/codex.md 2> ${shq(a.sessionDir)}/codex.err`
            : (a.scopeType === 'files' || a.scopeType === 'plan')
              ? `timeout 600 codex exec -c model_reasoning_effort=high --ephemeral -o ${shq(a.sessionDir)}/codex.md - 2> ${shq(a.sessionDir)}/codex.err <<'P'\nRead and review the file(s)/plan content at ${a.diffPath}. Output Critical/Important/Minor with file:line.\nP`
              : `timeout 540 codex exec -c model_reasoning_effort=high --ephemeral -o ${shq(a.sessionDir)}/codex.md - 2> ${shq(a.sessionDir)}/codex.err <<'P'\nReview the changes between ${baseSha} and ${headSha}: run git diff --stat ${baseSha}..${headSha} then git diff ${baseSha}..${headSha}. Output Critical/Important/Minor with file:line.\nP`}`}
IMPORTANT: \`codex review\` writes its ENTIRE output — including the final review — to STDERR, not stdout. After it runs, on a clean exit, if ${a.sessionDir}/codex.md is empty but ${a.sessionDir}/codex.err is non-empty, the review is in codex.err — read that. (codex exec writes its -o file directly and needs no recovery.) If codex exited non-zero with no review, set ran_ok=false with the reason. Parse the review into findings.`

const kiroPrompt = `Run the Kiro CLI to review. Read ${a.promptsDir}/reviewers/kiro.md for the review framing (its {PLACEHOLDER} tokens are NOT pre-filled — interpret them from the scope and paths given in this prompt).
Run with a 300000 ms Bash timeout:
${trust === 'read-only'
  ? `  cd ${shq(a.projectRoot || '.')} && timeout 300 kiro-cli chat --no-interactive --trust-tools=fs_read "Read '${a.diffPath}' (the diff) and review it. Report Critical/Important/Minor with file:line." > ${shq(a.sessionDir)}/kiro.md 2> ${shq(a.sessionDir)}/kiro.err`
  : `  cd ${shq(a.projectRoot || '.')} && timeout 300 kiro-cli chat --no-interactive --trust-all-tools "${a.scopeType === 'commit' ? `Review the changes (git show ${commitSha}).` : (a.scopeType === 'files' || a.scopeType === 'plan' || a.scopeType === 'uncommitted') ? `Read '${a.diffPath}' (the precomputed changes) and review it.` : `Review the changes (git diff ${baseSha}..${headSha}).`} Report Critical/Important/Minor with file:line." > ${shq(a.sessionDir)}/kiro.md 2> ${shq(a.sessionDir)}/kiro.err`}
Focus areas: ${focusAreas(a.scopeType)}.
${specNote}
${staticNote}
Parse the output into findings. If it errors or returns nothing, set ran_ok=false with the reason.`

const geminiPrompt = `Run the Gemini CLI to review. Read ${a.promptsDir}/reviewers/gemini.md for the review framing (its {PLACEHOLDER} tokens are NOT pre-filled — interpret them from the scope and paths given in this prompt).
Do NOT pass any -m model pin (let the CLI fallback chain handle capacity). Run with a 300000 ms Bash timeout:
${trust === 'read-only'
  ? `  cd ${shq(a.projectRoot || '.')} && cat ${shq(a.diffPath)} | timeout 300 gemini -p "Review the diff on stdin. Report Critical/Important/Minor with file:line." -e code-review -o text > ${shq(a.sessionDir)}/gemini.md 2> ${shq(a.sessionDir)}/gemini.err`
  : `  cd ${shq(a.projectRoot || '.')} && ${a.scopeType === 'commit' ? `git show ${commitSha}` : (a.scopeType === 'files' || a.scopeType === 'plan' || a.scopeType === 'uncommitted') ? `cat ${shq(a.diffPath)}` : `git diff ${baseSha}..${headSha}`} | timeout 300 gemini -p "Review the changes on stdin. Report Critical/Important/Minor with file:line." -e code-review -y -o text > ${shq(a.sessionDir)}/gemini.md 2> ${shq(a.sessionDir)}/gemini.err`}
Focus areas: ${focusAreas(a.scopeType)}.
${specNote}
${staticNote}
Parse the output into findings. If it errors or returns nothing, set ran_ok=false with the reason.`

function verifyPrompt(rev) {
  return `You are committee's verifier for the ${rev.reviewer} reviewer. Read ${a.promptsDir}/verifier.md and follow it (its {PLACEHOLDER} tokens are NOT pre-filled — interpret them from the reviewer name, scope, and paths given in this prompt). NOTE: the findings to verify are inlined below — there is NO separate review file, so ignore verifier.md's "{REVIEW_FILE_PATH}" / "read the review file first" step and work directly from the FINDINGS block.
Verify each finding below against the actual code in ${a.projectRoot || '.'} (${baseSha !== 'none' ? `git range ${baseSha}..${headSha}, or ` : ''}read the precomputed changes at ${a.diffPath}; for uncommitted scope use git diff / git diff --staged). Tag each confirmed / refuted / unverifiable with one-line evidence. Default to refuted/unverifiable unless you can confirm it is real. Preserve each finding's severity, file, and detail in your output.

FINDINGS:
${(rev.findings || []).map((f, i) => `${i + 1}. [${f.severity}] ${f.file} — ${f.title}: ${f.detail}`).join('\n')}`
}

phase('Review')
const reviewers = [
  { name: 'Claude', prompt: claudePrompt, model: a.reviewerModel },
  { name: 'Codex', prompt: codexPrompt },
  { name: 'Kiro', prompt: kiroPrompt },
  { name: 'Gemini', prompt: geminiPrompt },
]

// pipeline() fans stage-1 (review) out across all reviewers concurrently — this IS
// the spec's "parallel() Review" — then streams each reviewer into stage-2 (verify)
// as it completes (no barrier between stages).
const results = await pipeline(
  reviewers,
  r => agent(r.prompt, Object.assign({ label: `review:${r.name}`, phase: 'Review', schema: FINDINGS }, r.model ? { model: r.model } : {}))
        .then(x => ({ ...x, reviewer: x.reviewer || r.name }))
        .catch(() => ({ reviewer: r.name, ran_ok: false, note: 'agent error', findings: [] })),
  rev => {
    if (!rev || !rev.ran_ok) {
      // reviewer genuinely failed (no review produced) — drop from quorum
      return { reviewer: rev?.reviewer ?? '?', ran_ok: false, note: rev?.note, verified: [] }
    }
    if (!(rev.findings || []).length) {
      // reviewer ran successfully but found nothing — keep ran_ok=true so it
      // still counts toward quorum; nothing to verify
      return { reviewer: rev.reviewer, ran_ok: true, note: rev.note, verified: [] }
    }
    return agent(verifyPrompt(rev), { label: `verify:${rev.reviewer}`, phase: 'Verify', schema: VERIFIED, model: 'sonnet' })
      .then(v => ({ ...v, reviewer: rev.reviewer, ran_ok: true }))
      // Verifier crashed but the reviewer DID run: keep ran_ok=true, flag the
      // failure via note, and carry the unverified findings forward so they are
      // not silently lost (the skill surfaces them as unverified).
      .catch(() => ({ reviewer: rev.reviewer, ran_ok: true, verified: [], findings: rev.findings, note: 'verifier agent failed; findings unverified' }))
  }
)

const ran = results.filter(r => r.ran_ok)
log(`committee: ${ran.length}/4 reviewers ran; quorum ${ran.length >= 2 ? 'met' : 'NOT met'}`)
return { quorum: ran.length, degraded: ran.length < 2, perReviewer: results }
```

- [ ] **Step 2: Structural sanity check**

Do NOT use `node --check` / `node` — workflow scripts combine `export`, top-level `await`, top-level `return`, and runtime-injected globals (`args`/`agent`/`phase`/`pipeline`/`log`); no Node parse mode accepts that combination, so Node would report false syntax errors. The Workflow runtime is the only correct parser — Step 3's smoke run is the real syntax+semantics gate.
Run: `grep -c "export const meta" prompts/committee-review.js && grep -c "phase('Review')\|await pipeline" prompts/committee-review.js`
Expected: `meta` present once; the phase/pipeline calls present. Eyeball brace/paren balance.

- [ ] **Step 3: Smoke-run the workflow via scriptPath against a small commit**

Pick a small recent commit first: `SHA=$(git -C <repo> rev-parse HEAD)` (and `BASE=$(git -C <repo> rev-parse HEAD~1)`). Then `mkdir -p /tmp/committee-smoke && git -C <repo> show "$SHA" > /tmp/committee-smoke/diff.txt`, and invoke the Workflow tool with `{ scriptPath: "<repo>/prompts/committee-review.js", args: { scopeType:"commit", scopeDescription:"commit $SHA", commitSha:"$SHA", baseSha:"$BASE", headSha:"$SHA", projectRoot:"<repo>", promptsDir:"<repo>/prompts", sessionDir:"/tmp/committee-smoke", diffPath:"/tmp/committee-smoke/diff.txt", diffStatPath:"/tmp/committee-smoke/diff_stat.txt", trust:"auto" } }` (substitute the actual `$SHA`/`$BASE`/`<repo>` values into the args).
Expected: workflow completes; returns `{ quorum: >=2, perReviewer: [...] }`; verifiers ran as agents (visible in `/workflows`); no `claude -p` anywhere.

**This is a BLOCKING gate, not a checklist item.** If the return does not include `quorum` ≥ 2, or any reviewer's command form errored (e.g. an invalid `codex` invocation, a malformed heredoc, a `git diff none..none`), STOP and debug the failing scope branch before proceeding to Task 2. A green Step 2 grep does not substitute for a successful run here — this is the only real syntax+semantics gate for the workflow (per Step 2's note).

- [ ] **Step 4: Commit**

```bash
git add prompts/committee-review.js
git commit -m "feat(committee): add committee-review workflow (reviewers -> verify -> structured return)"
```

---

## Task 2: Install symlink + verify named resolution

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: Read install.sh's symlink section**

Run: `grep -n "safe_symlink\|ln -sfn\|skills/committee" install.sh`
Identify the function (`safe_symlink`) and where committee artifacts are linked.

- [ ] **Step 2: Add the workflow symlink**

In `install.sh`, after the existing committee symlinks, add (using the repo's existing `safe_symlink` helper and absolute repo path variable — match the surrounding style):

```bash
# Named user-scope workflow so the skill can invoke Workflow({name:"committee-review"}).
mkdir -p "$HOME/.claude/workflows"
safe_symlink "$REPO_DIR/prompts/committee-review.js" "$HOME/.claude/workflows/committee-review.js"
```

(Use whatever variable `install.sh` already uses for the repo root in place of `$REPO_DIR` — it is `REPO_ROOT`.)

Also in the same edit, **update install.sh's existence-guard loop** (the `for f in … ; do [ -f "$f" ] || …` block near the top) so it no longer requires the about-to-be-deleted `coordinator.md`: replace the `"$REPO_ROOT/prompts/coordinator.md"` entry with `"$REPO_ROOT/prompts/committee-review.js"`. Without this, `./install.sh` exits 1 once Task 4 removes `coordinator.md`.
Verify after this task: `grep -n 'coordinator.md' install.sh` returns nothing.

- [ ] **Step 3: Run the installer**

Run: `./install.sh`
Expected: completes without error.

- [ ] **Step 4: Verify the symlink**

Run: `ls -l ~/.claude/workflows/committee-review.js`
Expected: symlink → `<repo>/prompts/committee-review.js`.

- [ ] **Step 5: Verify named resolution in a FRESH session (the spec's open item)**

Start a new Claude Code session, then invoke the Workflow tool with `{ name: "committee-review", args: {...minimal smoke args as Task 1 Step 3...} }`.
Expected: resolves and runs. **If it errors "not found":** the symlink-registration path does not work — record this and use the `scriptPath` fallback in Task 3 Step 1 (the `Workflow` invocation) instead of `name`. Either way the workflow file is unchanged.

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "build(committee): install committee-review as a user-scope named workflow"
```

---

## Task 3: Rewrite SKILL.md to invoke the workflow

**Files:**
- Modify: `.claude/skills/committee/SKILL.md` — two regions: (a) the `PROMPTS_DIR` resolution stanza in `## Resolve scope and set up the session` (Step 1a below), and (b) the `## Dispatch Claude + coordinator (parallel)` section through `## Failure modes` (Steps 1–3).

- [ ] **Step 1a: Re-point the `PROMPTS_DIR` resolution sentinel (CRITICAL — outside the dispatch section)**

In `## Resolve scope and set up the session`, the `for cand in … ; do [ -f "$cand/coordinator.md" ] && …` loop keys `PROMPTS_DIR` discovery on `coordinator.md`. Once Task 4 deletes that file, the loop never resolves and **every** `/committee` run aborts with "committee prompts dir not found" before reaching dispatch. Change the sentinel from `coordinator.md` to a file that survives — `committee-review.js` (or `reviewers/claude.md`).
Verify after this task: `grep -n 'coordinator.md' .claude/skills/committee/SKILL.md` returns nothing (the pre-dispatch check in Step 1 and any other live refs are also gone).

- [ ] **Step 1: Replace the dispatch section**

Replace the entire `### Claude reviewer (background)` + `### Coordinator (foreground)` subsections (under `## Dispatch Claude + coordinator (parallel)`) with a single `## Dispatch the review workflow` section containing:

```markdown
## Dispatch the review workflow

After the pre-dispatch check (the old template-existence check now verifies `$PROMPTS_DIR/committee-review.js` instead of the removed template — abort cleanly the same way if missing), build the `args` object from the manifest and invoke the committee workflow:

Invoke the `Workflow` tool with `name: "committee-review"` (fallback: `scriptPath` set to the **resolved** `$PROMPTS_DIR` value + `/committee-review.js` — substitute the absolute path, not the literal string `$PROMPTS_DIR` — if Task 2 Step 5 showed named resolution does not work) and `args`:

​```
{
  scopeType, scopeDescription, projectRoot,
  baseSha, headSha, commitSha, baseBranch, headBranch, prNumber, prBaseRef, specPath,
  sessionDir, promptsDir,
  diffPath: "<SESSION_DIR>/diff.txt", diffStatPath: "<SESSION_DIR>/diff_stat.txt",
  staticPath: "<SESSION_DIR>/static.txt",
  trust, reviewerModel,
  userInput: "<raw /committee args>"
}
​```

Pass the manifest values; the workflow defaults absent SHAs to `none` and `commitSha` to `N/A`.
```

- [ ] **Step 2: Replace the synthesis/cleanup tail**

Replace `## Evaluate and display` to consume the workflow's structured return instead of reading session files:

```markdown
## Evaluate and display

The workflow returns `{ quorum, degraded, perReviewer: [{reviewer, ran_ok, note?, verified:[{title,severity,verdict,evidence,file?,detail?}]}] }`. Two extra shapes occur on degraded paths: a reviewer that ran clean has `verified:[]` (and is still counted in quorum); a reviewer whose verifier crashed has `verified:[]` plus a non-empty `findings:[…]` and a `note` (handled by the verifier-failure fallback in step 2).

1. If `quorum < 2` (`degraded: true`), present the degraded-quorum ABORT message (same wording as before) listing which reviewers failed (`ran_ok:false` + `note`), then go to cleanup.
2. Otherwise invoke `superpowers:receiving-code-review` over the confirmed findings, then synthesize the **Critical/Important/Minor** report (dedup the same finding across reviewers into one entry with multiple attributions; surface contradictions and refuted/unverifiable items) in the existing report format. Annotate any finding you judge technically unsound. **Verifier-failure fallback:** if a `perReviewer` entry has an empty `verified` array but a non-empty `findings` array plus a `note` indicating the verifier failed, surface those `findings` in the report tagged `[Unverified]` rather than dropping them — the reviewer ran, only its verifier crashed.
3. Present the report. Then STOP (`<no_implementation>`).

## Cleanup (after presenting)

Run `rm -rf -- "$SESSION_DIR"`. If PR scope and `PR_BASE_REF` is set, also `git update-ref -d "$PR_BASE_REF"`. If the `Workflow` call itself errored, do NOT delete `$SESSION_DIR` — tell the user it is preserved for inspection and stop — but STILL run `git update-ref -d "$PR_BASE_REF"` for PR scope (it is committee's own `refs/pr-committee/*` namespace; leaving it leaks a stale ref).
```

- [ ] **Step 3: Update the failure-modes section**

In `## Failure modes`, delete `<failure_mode name="claude_dispatch_failed">` and `<failure_mode name="coordinator_failed">` (both obsolete) and add:

```markdown
<failure_mode name="workflow_failed">
The `Workflow` call errored or returned no usable result → tell the user the review workflow failed, note that `$SESSION_DIR` is preserved for inspection, and STOP. Do not delete the session dir. For PR scope, still run `git update-ref -d "$PR_BASE_REF"` so the fetched `refs/pr-committee/*` ref is not left behind.
</failure_mode>
```

Keep `<failure_mode name="bash_error">` unchanged.

- [ ] **Step 4: Verify no dangling references**

Run: `grep -nE "coordinator|background|claude\.md poll|run_in_background|claude -p" .claude/skills/committee/SKILL.md`
Expected: no references to the old coordinator dispatch, background Claude dispatch, claude.md polling, or `claude -p` remain (matches in unrelated prose are fine — inspect each).

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/committee/SKILL.md
git commit -m "refactor(committee): invoke committee-review workflow instead of coordinator subagent"
```

---

## Task 4: Delete coordinator.md and confirm template wiring

**Files:**
- Delete: `prompts/coordinator.md`

- [ ] **Step 1: Confirm nothing else loads coordinator.md**

Run: `grep -rn "coordinator.md\|coordinator template" .claude prompts install.sh README.md CLAUDE.md | grep -v docs/superpowers`
Expected: **no live references remain** — Task 2 Step 2 already re-pointed install.sh's existence guard, Task 3 Step 1a re-pointed SKILL.md's `PROMPTS_DIR` sentinel, and Task 3 Step 1 replaced the pre-dispatch check. Any remaining match (other than past-tense prose in README.md/CLAUDE.md, handled in Task 5) is a live load — fix it before deleting.

- [ ] **Step 2: Confirm the workflow's template reads are correct**

Run: `grep -n "promptsDir}/reviewers\|promptsDir}/verifier" prompts/committee-review.js`
Expected: Claude→`reviewers/claude.md`, Kiro→`reviewers/kiro.md`, Gemini→`reviewers/gemini.md`, verifier→`verifier.md` all present and reading from `${a.promptsDir}`.

- [ ] **Step 3: Delete the file**

Run: `git rm prompts/coordinator.md`

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(committee): remove coordinator.md (role moved into committee-review workflow)"
```

---

## Task 5: Update docs

**Files:**
- Modify: `CLAUDE.md`, `README.md`

- [ ] **Step 1: Update CLAUDE.md**

In `CLAUDE.md`, update the architecture/dispatch note: the coordinator subagent is replaced by the `committee-review` workflow (`prompts/committee-review.js`), which runs all four reviewers + per-reviewer verifiers; the skill does prep + synthesis. Update the Project Structure list: remove `prompts/coordinator.md`, add `prompts/committee-review.js — committee review workflow (reviewers → verify → structured return)`. Update the Developing & deploying section to mention the `~/.claude/workflows/committee-review.js` symlink.

- [ ] **Step 2: Update README.md**

In `README.md`, update the Architecture diagram and any prose so the Claude+CLI reviewers and verifiers run inside the `committee-review` workflow (not a coordinator subagent / `claude -p`). Reviewer table mechanism for all four becomes "workflow agent".

- [ ] **Step 3: Verify the docs match reality**

Run: `grep -ni "coordinator\|claude -p" README.md CLAUDE.md`
Expected: no stale claims that committee uses a coordinator subagent or `claude -p` (historical mentions, if any, must be clearly past-tense).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs(committee): describe the committee-review workflow architecture"
```

---

## Task 6: End-to-end acceptance (spec §5)

**Files:** none (verification only)

- [ ] **Step 1: Full run, auto trust** — in a fresh session: `/committee --commit <sha>`.
  Expected: all four reviewers appear in the report (Codex included via stderr recovery); the report is the usual Critical/Important/Minor format; `/workflows` shows verifier *agents* (no `claude -p`).

- [ ] **Step 2: Read-only trust** — `/committee --files <small file> --trust=read-only`.
  Expected: completes; CLI reviewers used no-shell invocations (Kiro `--trust-tools=fs_read`, Gemini stdin); report produced.

- [ ] **Step 3: Reviewer dropout + degraded quorum** — temporarily make one CLI unavailable (e.g. `PATH` without `codex`) and run `/committee --commit <sha>`.
  Expected: report still produced from the remaining 3 reviewers; the failed reviewer is listed (`ran_ok:false` + `note`) but **there is NO degraded-quorum ABORT** — quorum is 3, above the `< 2` threshold, so `degraded:false`. Do not expect a degraded note here; an executor that does would wrongly fail a correct implementation. To exercise the actual `degraded:true` ABORT path, make THREE CLIs unavailable (leaving only Claude): then `quorum < 2` and the degraded-quorum abort message appears. No crash in either case.

- [ ] **Step 4: committee-loop regression** — `/committee-loop <small file>` (or a dry iter-2 path) to confirm the unchanged `/committee` interface still drives it.
  Expected: iter-2+ `/committee --files … --trust=auto` runs through the workflow and returns a report.

- [ ] **Step 5: Final commit (if any doc/verification tweaks)**

```bash
git add -A && git commit -m "test(committee): verify workflow migration end-to-end" || echo "nothing to commit"
```

---

## Final verification (before declaring the migration complete)

Invoke `superpowers:verification-before-completion` and confirm, with pasted evidence (evidence before assertions):
- Task 1 smoke run returned `quorum ≥ 2` with verifier **agents** (no `claude -p` anywhere).
- Task 6 Step 1 live `/committee --commit <sha>` showed all four reviewers in the report, **Codex included** (via stderr recovery), in the usual Critical/Important/Minor format.
- `grep -rn "coordinator\|claude -p" .claude prompts install.sh` is clean (grep-exit convention: no output / exit 1 = PASS).
- `grep -rn "coordinator.md" .claude/skills/committee/SKILL.md install.sh` is clean (the `PROMPTS_DIR` sentinel + install guard were re-pointed).
- Task 6 Step 4: `/committee-loop` iter-2 still drives `/committee` through the workflow.

Only after every item above is evidenced may the migration be called complete.

## Self-Review notes (for the executor)

- **Spec coverage:** §1 boundary → Tasks 3–4; §2 deploy → Task 2; §3 args/data-flow → Tasks 1 & 3; §4 error/quorum/trust/codex → Task 1 (workflow logic) + Task 3 (degraded handling); §5 acceptance → Task 6.
- **Open item:** Task 2 Step 5 decides `name` vs `scriptPath` — carry that decision into Task 3 Step 1.
- **Type consistency:** the return shape `{quorum, degraded, perReviewer:[{reviewer, ran_ok, note?, verified:[{title,severity,verdict,evidence,file?,detail?}]}]}` is produced in Task 1 and consumed verbatim in Task 3 Step 2 (which also handles the clean `verified:[]` and verifier-crash `findings:[…]` fallback shapes).
- **No silent loss:** workflow-level failure preserves `$SESSION_DIR` (Task 3 Steps 2–3).
