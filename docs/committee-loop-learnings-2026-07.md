# committee-loop learnings — refining specs & plans (2026-07)

Evidence-based learnings mined from two full `committee-loop` runs (Loop 3 and Loop 4)
plus a follow-up soundness-gated confirming pass, all against ONE target: the
`2026-07-01-codex-coordinator-committee-loop-design.md` design spec (a ~1,300–1,850-line
prose security spec for unwritten code). Purpose: improve the `committee-loop` skill,
especially its ability to refine **specs and plans** (as opposed to code).

> How to use this doc: §7 is the prioritized, file-scoped work list for an improvement
> session. §1–§5 are the evidence behind it. §6 is what must NOT be broken.

---

## 0. Evidence base (raw metrics)

- **2 loops, both EXHAUSTED at 10/10.** Loop 3 and Loop 4 each ran the full iteration
  budget without ever reaching "clean"/converged. Git history shows 4 `EXHAUSTED` terminal
  commits.
- **Every iteration applied ≥1 verified Important.** Across 20 loop iterations + 2
  confirming rounds, no round ever came back "nothing applicable." There was never a
  zero-application round under the default gate.
- **The spec GREW under review: 1,296 → 1,846 lines (+42%, +550 lines) during Loop 4 + 2
  confirming rounds** (git: `a81173c` "Loop 4 reset" vs HEAD). Reviewing a growing
  document is reviewing an expanding target.
- **26 fix commits** in Loop 4 + confirming passes.
- **The same mechanism was challenged as "critical" and refuted repeatedly.** The
  setsid/timeout PGID-capture was flagged critical and REFUTED at least 3 separate times
  (Loop 4 iter-7, iter-9, confirming round 1) — each verifier **empirically reproduced**
  the refutation. (`grep -c refuted .committee-loop-decisions.md` → 32.)
- **Reviewer availability was the dominant operational failure.** Kiro (AWS Q) hit
  `ServiceQuotaExceededException` and produced ZERO usable reviews across the entire loop
  (~every round). Anthropic session-limits blocked whole rounds (Loop 4 iter-10 needed
  **three** dispatch attempts — one full quorum-0). Gemini-Pro intermittently timed out →
  Flash retry.

---

## 1. Headline finding

**`committee-loop`'s convergence model was built for CODE and does not terminate on a
prose SPEC/PLAN.** Code converges against an oracle (tests: green bar = done). A design
spec has no oracle — reviewers verify claims against *other parts of the doc* and against
CLI/tool facts, which is unbounded. Point 4–5 premium adversarial models at 1,800 lines of
security-sensitive prose and they will ALWAYS surface a legitimate precision/completeness
finding. The default gate ("apply any verified Important; converge only on a zero-finding
polish round") therefore has an effectively unreachable exit condition, so the loop
**exhausts its budget instead of converging** — as it did, twice.

The fix that provably works (see §2) is to change WHAT COUNTS as blocking, not to review
harder.

---

## 2. Learning: split the severity gate into SOUNDNESS vs POLISH  ⟵ highest leverage

**Observation.** The default gate treats all verified Important as blocking, conflating
"the design is unsound" with "the doc could be more precise/complete." The second class is
inexhaustible on a large prose doc.

**Evidence.** In the confirming pass I re-ran committee under a **soundness-only gate**
(apply/block only on security/correctness/liveness/load-bearing-contradiction findings;
route documentation precision/AC-completeness/terminology to a non-blocking backlog). It
cleanly separated the two classes every round:

| Round | Soundness (blocking) | Polish / deferred / refuted (non-blocking) |
|---|---|---|
| Confirming R1 | 2 | ~6 (incl. the setsid "critical" — refuted a 4th time) |
| Confirming R2 | 4 (1 Critical + 3 Important) | ~7 |

Under the *default* gate all ~6–11 of those per round would have blocked. The soundness
gate makes "is it clean?" answerable. Real soundness examples the gate correctly KEPT:
the reap-ordering TOCTOU (Loop 4 iter-10), the CONVERGED-copy forgery hole (iter-7), the
danger-mode Gemini-drop (iter-8), a `SIGTERM`-catchable reap (confirming R2). Real polish
examples it correctly SHED: prose density, terminology collisions, `-c`-key re-verify
notes, "e.g." vs normative filenames, missing ACs for already-specified behavior.

**Recommendation.** For `scopeType` in {plan, spec/design-doc}, ship a two-tier severity
gate. A shipped rubric already exists — reuse it verbatim:
`.committee-loop-SOUNDNESS-GATE.md` (written during the confirming pass; tie-breaker:
"would the BUILT system be broken/insecure without this change?"). Converge on **"no new
soundness Critical/Important for N consecutive rounds,"** not "zero findings." A promise,
if used, means "SOUNDNESS CLEAN," and the polish backlog may be non-empty at convergence
(it's addressed in a later editorial pass or folded during implementation).

---

## 3. Learning: the loop's OWN edits are a top finding source (self-generated churn)

**Observation.** A large fraction of findings were corrections of the *prior iteration's
own edits*. Each fix adds prose → new reviewable surface → new findings. The fixpoint
recedes as you approach it.

**Evidence.**
- Loop 4 iters 1–4 were dominated by corrections of my own edits (the INREPO_HOME
  neutralization layer, the `$ART_DIR` marker reads, the symlink-safety asymmetry, the
  PGID-capture recipe, the prompt-file filename). I logged a "CASCADE STATUS" note in the
  ledger nearly every iteration.
- The confirming pass is the cleanest proof: **round 1's two soundness bugs were BOTH
  defects in iter-10's own fix** (an execution-order self-contradiction; a `CODEX_RC`
  unbound-variable crash on the happy path). Round 2 found four more — **three in the same
  subsystem I had just been editing.**
- The document grew +42% *while being "refined."*

**Recommendations.**
1. **Prefer edit-in-place / tighten over append.** Instruct the coordinator to REPLACE or
   shrink, resist adding new prose/claims, and treat doc-size growth as a smell. Track and
   report line count per iteration; flag net growth.
2. **Per-fix focused self-review BEFORE the next full round.** After applying a fix, the
   coordinator should re-review *just the changed lines/diff* of its own edits for
   internal consistency and introduced defects — cheaply, without spending a full committee
   round to discover its own bug next iteration. (The existing "consistency sweep" is the
   right instinct but ran too shallow: it caught stale cross-refs but missed the iter-10
   reorder's two behavioral bugs.)
3. **Mandate the consistency sweep as a gated step**, and expand it from "stale cross-refs"
   to "did this edit change a behavior/ordering/contract that other passages still assert
   the old way?" (the iter-10 reorder failed exactly this.)

---

## 4. Learning: reviewers re-litigate settled/refuted items — feed the ledger to them

**Observation.** Reviewers are stateless across rounds; the same concern recurs and burns a
full verifier cycle each time to re-refute it.

**Evidence.** The setsid/timeout PGID-capture mechanism was raised as **critical and
refuted ≥3 times** (Loop 4 iter-7, iter-9, confirming R1), each time re-derived from
scratch and empirically reproduced by the verifier — pure wasted compute. Meanwhile the
anti-thrash **ledger** (a coordinator-side gate) *did* prevent me from re-applying reversed
decisions — but it lived only in the coordinator's context, never in the reviewers'.

**Recommendation.** Inject the ledger's **REFUTED / SETTLED / ACCEPTED-RISK preamble into
each reviewer's and verifier's prompt** ("These were previously adjudicated with evidence;
raise them again ONLY with NEW verification evidence of equal-or-greater weight — a
different reviewer's opinion is not new evidence"). Concretely: `committee-review.js` should
accept a `priorAdjudications` arg and the reviewer/verifier templates
(`prompts/reviewers/*.md`, `prompts/verifier.md`) should render it. This turns the
anti-thrash gate from coordinator-only into panel-wide and stops re-refutation cycles.

---

## 5. Learning: no oracle → the convergence signal is NOISY; and intricate subsystems resist prose review

**Observation.** With no ground truth, reviewers sample the finding-space; they fixate on
salient/recently-edited areas and miss quiet latent issues. "No findings" ≠ "no defects."

**Evidence.**
- The genuinely-critical **reap-ordering TOCTOU went undetected for iters 1–9** and
  surfaced only at iter-10 (one reviewer, Gemini-Pro) — while the *adjacent, non-defect*
  PGID-capture concern got 3× the attention. The panel spent nine rounds on the wrong
  thing.
- One subsystem — the runner's **adversarial-reap + teardown ordering** — produced a real
  soundness defect at *every* fix: iter-10's reorder had 2 bugs (found confirming R1);
  fixing those exposed 4 more (confirming R2), 3 in the same subsystem (`SIGTERM`-catchable
  reap; a missed credential-purge path on post.sh guardrail-abort; a `rm -f`-aborts-on-dir
  hazard). These are things a **20-line test nails deterministically** and a prose panel
  keeps circling.

**Recommendations.**
1. **Hot-subsystem detector.** Track where verified findings cluster (by section/line
   range) across rounds. If an area yields N soundness findings over M rounds, surface it
   to the operator: *"this subsystem has resisted N fixes — it likely needs a prototype/test,
   not more spec review."* This is the single most useful signal the loop could add for
   specs.
2. **Coverage/anti-recency prompt dimension.** Dedicate at least one reviewer per round to
   hunting **latent** issues in areas NOT recently edited (counter the recency fixation
   that hid the TOCTOU for 9 rounds).
3. **State the honest terminal bar for specs.** Convergence = "reviewers stop finding new
   soundness defects and agree on the same accepted-residual set" — explicitly best-effort,
   NOT a correctness proof. Say so in the report so nobody mistakes SOUNDNESS-CLEAN for
   verified-correct.
4. **Route, don't grind.** The strongest recommendation for both specs and plans: review to
   a **"sound enough to implement"** bar, then IMPLEMENT with the ACs as the test outline.
   The loop should not try to make a spec "clean"; a spec becomes truly verifiable only
   once it has an executable oracle. Detect diminishing soundness returns and *recommend
   implementation* rather than another round.

---

## 6. What WORKED — do not regress these

- **Per-reviewer verifier stage.** Load-bearing. It refuted the setsid "critical" ≥3×,
  downgraded overstated severities (e.g. confirming R2's "important"→"minor" credential
  residual), and caught reviewers inventing sections/mechanisms. Keep it; it's the main
  defense against acting on plausible-but-wrong findings.
- **Ledger anti-thrash gate** (coordinator side) — prevented reversing settled decisions.
  Keep it; extend it to reviewers (§4).
- **Fail-closed transient handling.** Session-limits / 429s / classifier-unavailable were
  correctly treated as NEVER a blocker and NEVER grounds for a false promise — always
  backoff+retry until the review actually ran (Loop 4 iter-10 recovered after 3 attempts).
  Keep this discipline exactly.
- **Model-diverse panel, incl. a 6th reviewer.** Adding **Fable** (`claude-fable-5`)
  alongside Opus added real value: Fable independently found the iter-7 CONVERGED-copy
  forgery hole and co-confirmed several criticals. Model diversity — even same-family —
  pays off. The roster should be arbitrary/extensible, not a fixed 5.
- **Structured ledger + DEFERRED sidecars** gave continuity across a stateless loop.
- **Consistency sweep** (keep, but deepen — §3).

---

## 7. Prioritized, file-scoped change list (for the improvement session)

**P0 — makes specs/plans converge at all**
1. **Two-tier severity gate for plan/spec scope** (soundness-blocking vs polish-backlog).
   - Where: `.claude/skills/committee-loop/inner-agent.md` (the gating instructions);
     ship the rubric from `.committee-loop-SOUNDNESS-GATE.md`; add a `.committee-loop-POLISH.md`
     backlog sidecar alongside `DEFERRED`.
   - Convergence = "N consecutive rounds with 0 new soundness findings"; promise means
     "SOUNDNESS CLEAN"; polish backlog may be non-empty.
2. **Soundness-quiet stopping / diminishing-returns exit.**
   - Where: `inner-agent.md`. Track per-round soundness-finding count; converge when it
     hits 0 for N rounds even if polish continues (resolves the early-stop-vs-latent-critical
     tension: keep going until soundness-quiet, then stop regardless of polish volume).

**P1 — cuts wasted cycles & self-inflicted churn**
3. **Feed REFUTED/SETTLED/ACCEPTED preamble to reviewers + verifiers.**
   - Where: `prompts/committee-review.js` (new `priorAdjudications` arg), `prompts/reviewers/*.md`,
     `prompts/verifier.md`. Stops re-refutation of settled items (the setsid 3× problem).
4. **Drop persistently-failing reviewers for the rest of a loop.**
   - Where: the loop driver / `committee-review.js`. Evidence: Kiro produced 0 usable
     reviews all loop yet was re-dispatched every round (wasted latency + AWS overage). After
     K consecutive failures, drop it and proceed on the rest; report the reduced panel.
5. **Edit-in-place discipline + per-fix diff self-review + doc-size tracking.**
   - Where: `inner-agent.md`. Prefer replace/shrink over append; self-review the just-applied
     diff for introduced defects before the next round; log line-count delta and flag growth.
6. **Deepen the consistency sweep** to "did this edit change a behavior/ordering/contract
   other passages still assert the old way?" (the iter-10 reorder failed exactly this).
   - Where: `inner-agent.md`.

**P2 — better signal & scale**
7. **Hot-subsystem detector** — cluster findings by section/line-range; flag an area that
   resists N fixes and RECOMMEND prototyping/testing it. Where: `inner-agent.md` + report.
8. **Anti-recency coverage lens** — assign ≥1 reviewer/round to latent issues in
   not-recently-edited areas. Where: `prompts/reviewers/*.md` (a per-round lens arg) +
   `committee-review.js`.
9. **Scope segmentation for large specs.** A monolithic 1,800-line spec was re-reviewed
   whole every round (~40 min, ~0.7–1.5M tokens/round). For large specs/plans, review by
   section/changed-region across rounds rather than the entire doc each time. Where:
   `SKILL.md` + `inner-agent.md` (the loop already mentions "target segmentation"; extend it
   to intra-file sections for a single large target).
10. **First-class per-loop config for panel + gate.** The premium+Fable panel and the
    soundness gate had to be injected via a hand-written "LOOP OVERRIDE" in the instructions
    + ledger. Make reviewer-roster, per-reviewer model, and gate-mode first-class
    `spawn.sh --models`/`--gate` inputs. Where: `spawn.sh` + `.committee-loop-models.json`
    schema + `SKILL.md`.

---

## 8. Evidence artifacts (in the loop worktree)

- Decision ledgers: `.committee-loop-decisions.md` (Loop 4) + `.loop{1,2,3}.md` archives —
  per-iteration findings, verdicts, and CASCADE STATUS notes.
- Polish/deferred backlogs: `.committee-loop-POLISH.md`, `.committee-loop-DEFERRED.md`.
- The soundness rubric: `.committee-loop-SOUNDNESS-GATE.md`.
- Terminal signals: `.committee-loop-EXHAUSTED.loop4.txt` (Loop 4 whole-loop assessment).
- Git history: `fix L3-iter-*`, `fix L4-iter-*`, `Soundness confirming-pass round {1,2}`,
  and the `EXHAUSTED` commits.
- The reviewed target: `docs/superpowers/specs/2026-07-01-codex-coordinator-committee-loop-design.md`.

## 9. One-paragraph summary for the improvement session

`committee-loop` refines *code* well but cannot terminate on a large *spec/plan* because
its convergence gate is oracle-shaped and prose findings are inexhaustible. Two loops
EXHAUSTED 10/10; the doc grew +42% under "refinement"; the loop's own edits were a top
finding source; one intricate subsystem produced a real defect at every fix. A soundness-only
gate (P0) provably fixes termination by blocking only on security/correctness/liveness/
contradiction and backlogging polish; a soundness-quiet stop (P0), a reviewer-visible
anti-thrash preamble (P1), dropping dead reviewers (P1), and a hot-subsystem→"go implement
it" detector (P2) address the rest. Keep the verifier stage, ledger, fail-closed transient
handling, and model-diverse panel — they all demonstrably worked.
