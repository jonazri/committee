# Committee-Loop Inner Agent Instructions

You run inside a detached worktree. Ralph-loop feeds you this prompt each iteration. Your job: review the target file(s) named in the prologue above, verify each finding, apply only vetted Critical/Important ones, and stop when clean OR converged.

## Red flags — STOP if you are about to:

- Apply a finding without logging it in `.committee-loop-decisions.md`
- Reverse a prior iteration's fix because a *different* reviewer complained (that is not new evidence)
- Edit for a Minor finding (route to `.committee-loop-DEFERRED.md` instead)
- Skip the verification command for a single-reviewer Critical
- Edit any file other than the target(s) or `.committee-loop-*` sidecars at the worktree root

<scope>
You may only modify:
- The target file(s) named in the prologue above this file's header
- `.committee-loop-*` sidecars at the worktree root (reviewer outputs, `decisions.md`, `DEFERRED.md`, sentinels, `FINAL-PASS-DONE`, `post.sh` — the last one ONLY when Generated-file sync applies, see below)

NO implementation work in this session.
</scope>

## Exit protocol (read before doing anything else)

<exit_protocol>
Ralph-loop's stop-hook matches `<promise>...</promise>` by **exact string equality**. Prose will NOT release the loop. Your final message MUST contain the literal tag:

    <promise>REVIEW CLEAN</promise>

Both clean AND converged exits use this same tag. Convergence reason lives in `.committee-loop-CONVERGED.txt`.

**Run `bash .committee-loop-post.sh` BEFORE emitting the promise.** If the promise goes first, ralph may terminate before post.sh runs.

**Never emit the promise if `.committee-loop-BLOCKED.txt` exists after post.sh returns.** post.sh exits 0 on BLOCKED; the sidecar is the signal. On BLOCKED, do NOT emit the promise — let ralph terminate via iteration exhaustion. The watcher will report BLOCKED to the invoker.

**The authoritative clean-exit signal is the `DONE` sentinel written by post.sh — not the promise.** On the clean path post.sh's last step is `tmux kill-session`, which kills this agent's shell; the promise may not land before the session dies. That's fine — the watcher classifies on `DONE`, and ralph-loop terminates along with the session. Always emit the promise anyway so the stop-hook has a chance to fire if it runs before session teardown.
</exit_protocol>

## Per-iteration workflow

### 1. Simplify pre-pass (iter-1 only)

Dispatch `simplify` CONCURRENTLY with the reviewers in step 2. Pass `model: "sonnet"` on the Agent call — simplify's sub-agents do narrow pattern-matching work (find duplication, dead code, unused params) where Sonnet matches Opus at ~2× the throughput. All four (simplify + Claude + Kiro + Codex) run in parallel against the baseline. Wall-time is bounded by the slowest, not the sum.

Apply simplify's non-contentious fixes, commit as `simplify iter-1: <brief summary>` BEFORE the `fix iter-1` commit, so the ledger and `git diff HEAD~1` references resolve correctly. If simplify returns nothing, commit nothing and move on.

SKIP simplify on iter-2+. Reviewers cover remaining simplification as Minor findings. Simplify also runs at convergence exit (see end-pass below).

**De-duplication:** reviewers running in parallel may flag issues simplify has already fixed. Verifiers in step 3 probe the current file state — if a claim no longer holds, the verifier reports "not present" and the ledger records the finding as "resolved by simplify" (rejection). No special-case logic needed.

### 2. Review

**Iter-1 — fast mode (Claude + Kiro + Codex, skip Gemini).** Dispatch three reviewers in parallel, concurrent with simplify. For multi-target runs, pass ALL target paths together in each reviewer's prompt (one reviewer call per reviewer, not one per file) so the quorum gate operates on a single unified report per reviewer:

a. `superpowers:code-reviewer` subagent (Agent tool, default model — Opus for iter-1's baseline review) with prompt: *"Review <TARGET...> for code quality, bugs, design, shell safety. Output a Critical/Important/Minor list with line references and verification commands where possible."* The Agent tool has no explicit timeout flag — the harness bounds it internally. If the subagent is still running 15 minutes after dispatch, abandon it (stop waiting for its result) and proceed with the remaining reviewers.

b. `timeout 900 kiro-cli chat --no-interactive --trust-tools=fs_read` with the same prompt listing every target path. Write output to `.committee-loop-iter1-kiro.txt`. On timeout, `rm -f .committee-loop-iter1-kiro.txt` before synthesis so a partial report isn't parsed; 2-of-3 quorum from Claude+Codex still holds.

c. `timeout 900 codex exec --skip-git-repo-check --sandbox read-only -c model_reasoning_effort=high -o .committee-loop-iter1-codex.txt "Review <TARGET...> ..."` (same prompt, explicit `high` reasoning — user's global config may default to `xhigh` which takes ~2× as long with negligible findings-quality gain for this review scale). The 15m wall-clock cap prevents a hung Codex from blocking iter-1 indefinitely; on timeout, `rm -f .committee-loop-iter1-codex.txt` before synthesis to avoid parsing a truncated report — 2-of-3 quorum from Claude+Kiro still holds.

Do NOT use `/committee` in iter-1 — its coordinator includes Gemini and its own synthesis. Synthesize the three reports into a single Critical/Important/Minor list yourself.

**Iter-2+ — full mode.** Use `/committee --files <TARGET...>` (all 4 reviewers including Gemini). In multi-target runs, pass every `TARGET_FILES` entry as separate space-separated arguments after `--files`. Gemini's perspective joins once the file is already cleaner from iter-1 fixes, reducing noise.

<target_segmentation>
Before dispatching `/committee` in iter-N (N≥2), filter `TARGET_FILES` to only those changed since the iter-(N−1) commit:

```bash
git diff HEAD~1 --name-only -- <TARGET_FILES> 2>/dev/null
```

Pass ONLY the changed subset to `/committee --files`. Unchanged targets were already reviewed at this baseline in iter-(N−1) — re-reviewing them is pure waste. Ledger per-file convergence is tracked implicitly: a file that stops changing stops being reviewed.

If the filter yields ZERO files (nothing changed since iter-(N−1)), that IS the `clean` convergence trigger — go directly to step 6 convergence check without dispatching `/committee`.
</target_segmentation>

<model_selection>
Starting in iter-3, pass `--reviewer-model=sonnet` to `/committee` to select Sonnet for the Claude reviewer:

```
/committee --files <changed-target-list> --reviewer-model=sonnet
```

Rationale: iter-1 and iter-2 use Opus because the ledger architecture is still forming and the broadest-possible review is worth the wall-time. By iter-3, the Critical/Important findings that are easy to surface have been surfaced; remaining issues are subtler but still within Sonnet's range. Sonnet returns reviews in ~3 min vs Opus's ~8 min. The quorum gate tolerates any per-reviewer miss. If review quality visibly degrades (sudden spike in iter-3+ rejected findings or re-flagged issues), revert this flag.

Keep Opus for iter-1 and iter-2 by omitting `--reviewer-model` entirely (harness default).
</model_selection>

### 3. Classify with streaming verifier dispatch

**Dispatch model:**
- **Iter-1 (direct dispatch):** three reviewers each have their own completion signal (Agent tool return OR background-Bash task-notification). As each reviewer completes, IMMEDIATELY dispatch its verifier subagent in parallel to still-running reviewers and in-flight verifiers. Do NOT wait for all three reviewers to finish first — streaming saves 3-7 minutes per iteration.
- **Iter-2+ / final pass (`/committee` synthesis):** one synthesized report. Dispatch a single verifier.

Each verifier:
- Reads its reviewer's report
- Runs verification commands for each Critical/Important claim (e.g. `claude --help | grep -- --effort`, `grep -n`, actual bash tests)
- Returns a decision proposal per finding with its verification evidence

Write ledger entries serially once all verifiers return (append-order matters). Apply the three gates below — ALL must pass to apply a finding:

<gate name="severity">
Only CRITICAL and IMPORTANT findings are candidates for application. Append Minor findings verbatim to `.committee-loop-DEFERRED.md` and move on.
</gate>

<gate name="quorum">
Apply a finding if EITHER:
- Two or more reviewers flagged substantively the same issue (in iter-1 with 3 reviewers, any 2-of-3 agreement), OR
- A single reviewer flagged it AND the verifier's probe confirmed the claim.

Single-reviewer claims without a passing verification probe do NOT pass this gate.
</gate>

<gate name="ledger">
Read `.committee-loop-decisions.md` if it exists. If this finding (or its inverse) was previously decided, you may NOT reverse that decision without new evidence of equal or greater weight — a new verification probe whose output contradicts the prior one. A different reviewer's opinion is NOT new evidence.
</gate>

Append one entry per Critical/Important finding regardless of outcome:

```
## <iteration>-<reviewer>-<short-id>
- **Severity:** critical | important
- **Claim:** <one-line summary>
- **Verification:** <command run> -> <outcome>
- **Decision:** applied | rejected | deferred
- **Rationale:** <why>
```

### 4. Apply sequentially

Same-file edits cannot be parallelized safely. Apply "applied" findings one at a time with the SMALLEST edit that addresses each. Commit with a message naming finding IDs: `fix iter-<N>: apply <id1>, <id2>, ...`.

### 5. Generated-file sync (only when reviewing committee-loop itself)

Runtime files that spawn generates from the skill's source: `.committee-loop-post.sh` (← `post-body.sh`), `.committee-loop-watcher.sh` (← `watcher-body.sh`), `.committee-loop-instructions.md` (← `inner-agent.md`), `.committee-loop-prompt.txt` (← the prompt heredoc in `spawn.sh`). If your fix edits a source region whose content was copied into a runtime file, apply the equivalent edit directly to the runtime file in the same commit.

Only `.committee-loop-post.sh` actually runs after the fix; the others are moot post-spawn but syncing them keeps the ledger's `git diff HEAD~1` references consistent.

### 6. Convergence check

<convergence_exit>
Any of these triggers runs the end-pass below (entry conditions are mutually exclusive — use the first that applies):

<trigger name="clean">Zero Critical+Important findings this iteration. No CONVERGED.txt is written.</trigger>

<trigger name="reversal">A new iteration's fixes would REVERSE any prior-iteration change. Write `.committee-loop-CONVERGED.txt` naming the oscillator.</trigger>

<trigger name="re-flag-only">This iteration only re-flags findings already ledgered as rejected. Write `.committee-loop-CONVERGED.txt` naming the re-flag(s).</trigger>
</convergence_exit>

## End-pass (runs AT MOST ONCE per session)

This is the "end" half of the "simplify at beginning and end" design. Simplify potentially changes the file; a final full committee pass verifies the result is still clean.

Use `.committee-loop-FINAL-PASS-DONE` as a single-shot flag. If it exists, skip to step 5.

<skip_check>
**Step 0. Skip-check (runs first).** Count `Decision: applied` entries in `.committee-loop-decisions.md` for EACH of the two most recent iterations (use the iteration headers in the ledger to delimit sections). If BOTH counts are zero, the codebase has stabilized — the final pass's safety-net value no longer justifies its wall-time cost. Skip steps 1–2 and jump to step 3.

If only the current iteration had zero applies but iter-(N−1) had ≥1, run the full pass below — the safety net is still warranted.
</skip_check>

1. Run `simplify` on the target with `model: "sonnet"` (same workflow as iter-1's simplify). Apply non-contentious fixes, commit as `simplify final: <summary>`. If nothing, no commit.
2. Run a full committee pass (`/committee --files <TARGET...> --reviewer-model=sonnet` — all 4 reviewers including Gemini, Claude reviewer at Sonnet) using the section-3 and section-4 workflow (verifier dispatch, three gates, sequential apply). Commit applied fixes as `fix final: ...`. In multi-target runs, apply target segmentation here too — only pass files that changed since the last iteration's commit.
3. Run `bash .committee-loop-post.sh`.
4. Create `.committee-loop-FINAL-PASS-DONE` (empty marker) AFTER post.sh returns. The flag only matters on the BLOCKED path where post.sh preserves the worktree and ralph-loop may re-feed the prompt; the flag suppresses redundant re-entry. On CLEAN, post.sh tears down the worktree + tmux session itself and the flag is moot. AFTER is the safe ordering: a crash between post.sh and flag-creation re-runs the final pass with consistent already-committed-or-BLOCKED state; the inverse ordering would let a crash between flag-creation and post.sh skip copy-back entirely.
5. If `.committee-loop-BLOCKED.txt` now exists → STOP, do NOT emit the promise. Otherwise emit `<promise>REVIEW CLEAN</promise>`.

The final pass is a safety net, not a regular iteration. Whatever it applies or rejects is trusted on the same gates as any other iteration, and the session ends after step 5 regardless of what the final pass surfaces. The ledger captures all findings for post-mortem inspection.
