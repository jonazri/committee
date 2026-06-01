# Committee → Workflow Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the coordinator-subagent half of `/committee` with a workflow that owns all four reviewers → per-reviewer verify → returns structured findings, eliminating the fragile `claude -p` verifier improvisation.

**Architecture:** The `/committee` skill keeps prep (scope, `prepare.sh`, diff, trust dialog, `PROMPTS_DIR`) and synthesis (`receiving-code-review` + Critical/Important/Minor report). A new workflow `prompts/committee-review.js` dispatches Claude + Codex/Kiro/Gemini in parallel, then per-reviewer verifier agents, and returns a structured result. The skill invokes it via `Workflow({name:"committee-review", args})` (scriptPath fallback).

**Tech Stack:** Claude Code skills (markdown), the Workflow tool (JS orchestration), Bash CLIs (codex/kiro/gemini), `prepare.sh`.

**Spec:** `docs/superpowers/specs/2026-06-01-committee-workflow-migration-design.md`

**Domain note:** This is prompt/workflow engineering. There is no unit-test harness; each task's verification step is a real smoke run, grep, or fresh-session check (the spec §5 acceptance criteria). Commit after each task.

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

const FINDINGS = {
  type: 'object', additionalProperties: false,
  required: ['reviewer', 'ran_ok', 'findings'],
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
  required: ['reviewer', 'verified'],
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
        },
      },
    },
  },
}

// Per-scope review lens — mirrors the SKILL.md table.
function lensFor(t) {
  if (t === 'pr') return 'Pull-request review. Treat the changes as one cohesive unit; assess whether they fully and safely accomplish the PR\'s stated purpose; flag anything that should block merge. Findings are independently re-verified downstream, so report genuine concerns.'
  if (t === 'plan') return 'Implementation-plan review. The content is a plan document, not code. Evaluate whether an implementing agent could follow it without ambiguity — missing steps, undefined terms, ordering hazards, verification gaps.'
  if (t === 'files') return 'Standard code review of the source files provided (a set of files, not a diff).'
  return 'Standard code review of the changes in the git range.'
}

// How each reviewer should obtain the changes, by trust level.
const gitInstr = trust === 'read-only'
  ? `Read the precomputed diff at ${a.diffPath} (summary at ${a.diffStatPath}). Do NOT run git.`
  : (a.scopeType === 'commit'
      ? `Run: git show ${commitSha}`
      : (a.scopeType === 'files' || a.scopeType === 'plan'
          ? `Read ${a.diffPath} (the files/plan to review).`
          : `Run: git diff ${baseSha}..${headSha}`))

const staticNote = a.staticPath
  ? `If ${a.staticPath} exists and is non-empty, also read it — advisory static-analysis findings; verify each applies before flagging.`
  : ''

const claudePrompt = `You are committee's Claude reviewer. Working dir is the repo at ${a.projectRoot || '.'}.
Read the template at ${a.promptsDir}/reviewers/claude.md and follow it. Fill: WHAT_WAS_IMPLEMENTED=${a.scopeDescription}; PLAN_OR_REQUIREMENTS=${a.specPath || 'General code review — no specific plan'}; BASE_SHA=${baseSha}; HEAD_SHA=${headSha}; COMMIT_SHA=${commitSha}; REVIEW_LENS=${lensFor(a.scopeType)}.
${gitInstr}
${staticNote}
Return structured findings (set ran_ok=true).`

const codexPrompt = `Run the Codex CLI to review, then return its findings.
${trust === 'read-only'
  ? `Read-only: review the diff at ${a.diffPath}. Run with a 540000 ms Bash timeout:\n  codex review -c model_reasoning_effort=high - < ${a.diffPath} > ${a.sessionDir}/codex.md 2> ${a.sessionDir}/codex.err`
  : `Run with a 540000 ms Bash timeout (cd ${a.projectRoot || '.'} first):\n  ${a.scopeType === 'commit'
        ? `codex review -c model_reasoning_effort=high --commit ${commitSha}`
        : a.scopeType === 'branch_diff'
          ? `codex review -c model_reasoning_effort=high --base ${a.baseBranch}`
          : a.scopeType === 'uncommitted'
            ? `codex review -c model_reasoning_effort=high --uncommitted`
            : `codex exec -c model_reasoning_effort=high --ephemeral -o ${a.sessionDir}/codex.md - <<'P'\nReview the changes between ${baseSha} and ${headSha}: run git diff --stat ${baseSha}..${headSha} then git diff ${baseSha}..${headSha}. Output Critical/Important/Minor with file:line.\nP`} > ${a.sessionDir}/codex.md 2> ${a.sessionDir}/codex.err`}
IMPORTANT: \`codex review\` writes its ENTIRE output — including the final review — to STDERR, not stdout. After it runs, on a clean exit, if ${a.sessionDir}/codex.md is empty but ${a.sessionDir}/codex.err is non-empty, the review is in codex.err — read that. (codex exec writes its -o file directly and needs no recovery.) If codex exited non-zero with no review, set ran_ok=false with the reason. Parse the review into findings.`

const kiroPrompt = `Run the Kiro CLI to review. Read ${a.promptsDir}/reviewers/kiro.md for the review framing.
Run with a 320000 ms Bash timeout (cd ${a.projectRoot || '.'} first):
${trust === 'read-only'
  ? `  timeout 300 kiro-cli chat --no-interactive --trust-tools=fs_read "Read ${a.diffPath} (the diff) and review it. Report Critical/Important/Minor with file:line." > ${a.sessionDir}/kiro.md 2> ${a.sessionDir}/kiro.err`
  : `  timeout 300 kiro-cli chat --no-interactive --trust-all-tools "Review the changes (${a.scopeType === 'commit' ? `git show ${commitSha}` : `git diff ${baseSha}..${headSha}`}). Report Critical/Important/Minor with file:line." > ${a.sessionDir}/kiro.md 2> ${a.sessionDir}/kiro.err`}
Parse the output into findings. If it errors or returns nothing, set ran_ok=false with the reason.`

const geminiPrompt = `Run the Gemini CLI to review. Read ${a.promptsDir}/reviewers/gemini.md for the review framing.
Do NOT pass any -m model pin (let the CLI fallback chain handle capacity). Run with a 320000 ms Bash timeout (cd ${a.projectRoot || '.'} first):
${trust === 'read-only'
  ? `  cat ${a.diffPath} | gemini -p "Review the diff on stdin. Report Critical/Important/Minor with file:line." -e code-review -o text > ${a.sessionDir}/gemini.md 2> ${a.sessionDir}/gemini.err`
  : `  git ${a.scopeType === 'commit' ? `show ${commitSha}` : `diff ${baseSha}..${headSha}`} | gemini -p "Review the diff on stdin. Report Critical/Important/Minor with file:line." -e code-review -y -o text > ${a.sessionDir}/gemini.md 2> ${a.sessionDir}/gemini.err`}
Parse the output into findings. If it errors or returns nothing, set ran_ok=false with the reason.`

function verifyPrompt(rev) {
  return `You are committee's verifier for the ${rev.reviewer} reviewer. Read ${a.promptsDir}/verifier.md and follow it.
Verify each finding below against the actual code in ${a.projectRoot || '.'} (git range ${baseSha}..${headSha}; for uncommitted use git diff / git diff --staged; or read ${a.diffPath}). Tag each confirmed / refuted / unverifiable with one-line evidence. Default to refuted/unverifiable unless you can confirm it is real. Preserve each finding's severity.

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

const results = await pipeline(
  reviewers,
  r => agent(r.prompt, Object.assign({ label: `review:${r.name}`, phase: 'Review', schema: FINDINGS }, r.model ? { model: r.model } : {}))
        .then(x => ({ ...x, reviewer: x.reviewer || r.name }))
        .catch(() => ({ reviewer: r.name, ran_ok: false, note: 'agent error', findings: [] })),
  rev => {
    if (!rev || !rev.ran_ok || !(rev.findings || []).length) {
      return { reviewer: rev && rev.reviewer ? rev.reviewer : '?', ran_ok: !!(rev && rev.ran_ok), note: rev && rev.note, verified: [] }
    }
    return agent(verifyPrompt(rev), { label: `verify:${rev.reviewer}`, phase: 'Verify', schema: VERIFIED, model: 'sonnet' })
      .then(v => ({ ...v, reviewer: rev.reviewer, ran_ok: true }))
      .catch(() => ({ reviewer: rev.reviewer, ran_ok: true, verified: [] }))
  }
)

const ran = results.filter(r => r.ran_ok)
log(`committee: ${ran.length}/4 reviewers ran; quorum ${ran.length >= 2 ? 'met' : 'NOT met'}`)
return { quorum: ran.length, degraded: ran.length < 2, perReviewer: results }
```

- [ ] **Step 2: Structural sanity check**

Do NOT use `node --check` / `node` — workflow scripts combine `export`, top-level `await`, top-level `return`, and runtime-injected globals (`args`/`agent`/`phase`/`pipeline`/`log`); no Node parse mode accepts that combination, so Node would report false syntax errors. The Workflow runtime is the only correct parser — Step 3's smoke run is the real syntax+semantics gate.
Run: `grep -c "export const meta" prompts/committee-review.js && grep -c "phase('Review')\|phase('Verify')\|await pipeline" prompts/committee-review.js`
Expected: `meta` present once; the phase/pipeline calls present. Eyeball brace/paren balance.

- [ ] **Step 3: Smoke-run the workflow via scriptPath against a small commit**

Invoke the Workflow tool with `{ scriptPath: "<repo>/prompts/committee-review.js", args: { scopeType:"commit", scopeDescription:"commit <sha>", commitSha:"<sha>", baseSha:"<sha>^", headSha:"<sha>", projectRoot:"<repo>", promptsDir:"<repo>/prompts", sessionDir:"/tmp/committee-smoke", diffPath:"/tmp/committee-smoke/diff.txt", diffStatPath:"/tmp/committee-smoke/diff_stat.txt", trust:"auto" } }` after `mkdir -p /tmp/committee-smoke && git -C <repo> show <sha> > /tmp/committee-smoke/diff.txt`.
Expected: workflow completes; returns `{ quorum: >=2, perReviewer: [...] }`; verifiers ran as agents (visible in `/workflows`); no `claude -p` anywhere.

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

(Use whatever variable `install.sh` already uses for the repo root in place of `$REPO_DIR`.)

- [ ] **Step 3: Run the installer**

Run: `./install.sh`
Expected: completes without error.

- [ ] **Step 4: Verify the symlink**

Run: `ls -l ~/.claude/workflows/committee-review.js`
Expected: symlink → `<repo>/prompts/committee-review.js`.

- [ ] **Step 5: Verify named resolution in a FRESH session (the spec's open item)**

Start a new Claude Code session, then invoke the Workflow tool with `{ name: "committee-review", args: {...minimal smoke args as Task 1 Step 3...} }`.
Expected: resolves and runs. **If it errors "not found":** the symlink-registration path does not work — record this and use the `scriptPath` fallback in Task 3 Step 2 instead of `name`. Either way the workflow file is unchanged.

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "build(committee): install committee-review as a user-scope named workflow"
```

---

## Task 3: Rewrite SKILL.md to invoke the workflow

**Files:**
- Modify: `.claude/skills/committee/SKILL.md` (the `## Dispatch Claude + coordinator (parallel)` section through `## Failure modes`)

- [ ] **Step 1: Replace the dispatch section**

Replace the entire `### Claude reviewer (background)` + `### Coordinator (foreground)` subsections (under `## Dispatch Claude + coordinator (parallel)`) with a single `## Dispatch the review workflow` section containing:

```markdown
## Dispatch the review workflow

After the pre-dispatch check (the `$PROMPTS_DIR/coordinator.md` check is replaced by a `$PROMPTS_DIR/committee-review.js` check — abort cleanly the same way if missing), build the `args` object from the manifest and invoke the committee workflow:

Invoke the `Workflow` tool with `name: "committee-review"` (fallback: `scriptPath: "$PROMPTS_DIR/committee-review.js"` if Task 2 Step 5 showed named resolution does not work) and `args`:

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

Use `none` for absent SHAs and `N/A` for `commitSha` outside commit scope (the workflow already defaults these, but pass the manifest values).
```

- [ ] **Step 2: Replace the synthesis/cleanup tail**

Replace `## Evaluate and display` to consume the workflow's structured return instead of reading session files:

```markdown
## Evaluate and display

The workflow returns `{ quorum, degraded, perReviewer: [{reviewer, ran_ok, note, verified:[{title,severity,verdict,evidence}]}] }`.

1. If `quorum < 2` (`degraded: true`), present the degraded-quorum ABORT message (same wording as before) listing which reviewers failed (`ran_ok:false` + `note`), then go to cleanup.
2. Otherwise invoke `superpowers:receiving-code-review` over the confirmed findings, then synthesize the **Critical/Important/Minor** report (dedup the same finding across reviewers into one entry with multiple attributions; surface contradictions and refuted/unverifiable items) in the existing report format. Annotate any finding you judge technically unsound.
3. Present the report. Then STOP (`<no_implementation>`).

## Cleanup (after presenting)

Run `rm -rf -- "$SESSION_DIR"`. If PR scope and `PR_BASE_REF` is set, also `git update-ref -d "$PR_BASE_REF"`. If the `Workflow` call itself errored, do NOT delete `$SESSION_DIR` — tell the user it is preserved for inspection and stop.
```

- [ ] **Step 3: Update the failure-modes section**

In `## Failure modes`, delete `<failure_mode name="claude_dispatch_failed">` and `<failure_mode name="coordinator_failed">` (both obsolete) and add:

```markdown
<failure_mode name="workflow_failed">
The `Workflow` call errored or returned no usable result → tell the user the review workflow failed, note that `$SESSION_DIR` is preserved for inspection, and STOP. Do not delete the session dir.
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
Expected: only the now-replaced SKILL.md preflight reference (already handled in Task 3) — if any live load remains, fix it.

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

- [ ] **Step 3: Degraded quorum** — temporarily make one CLI unavailable (e.g. `PATH` without `codex`) and run `/committee --commit <sha>`.
  Expected: report still produced from the remaining reviewers with a degraded-quorum note; no crash.

- [ ] **Step 4: committee-loop regression** — `/committee-loop <small file>` (or a dry iter-2 path) to confirm the unchanged `/committee` interface still drives it.
  Expected: iter-2+ `/committee --files … --trust=auto` runs through the workflow and returns a report.

- [ ] **Step 5: Final commit (if any doc/verification tweaks)**

```bash
git add -A && git commit -m "test(committee): verify workflow migration end-to-end" || echo "nothing to commit"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** §1 boundary → Tasks 3–4; §2 deploy → Task 2; §3 args/data-flow → Tasks 1 & 3; §4 error/quorum/trust/codex → Task 1 (workflow logic) + Task 3 (degraded handling); §5 acceptance → Task 6.
- **Open item:** Task 2 Step 5 decides `name` vs `scriptPath` — carry that decision into Task 3 Step 1.
- **Type consistency:** the return shape `{quorum, degraded, perReviewer:[{reviewer, ran_ok, note, verified:[{title,severity,verdict,evidence}]}]}` is produced in Task 1 and consumed verbatim in Task 3 Step 2.
- **No silent loss:** workflow-level failure preserves `$SESSION_DIR` (Task 3 Steps 2–3).
