# Soundness gate — severity classification rubric for spec/plan targets

Copied to the worktree as `.committee-loop-SOUNDNESS-GATE.md` at spawn. Used by the inner
agent's `<gate name="class">` when the loop runs under the soundness gate (doc targets, or
`--gate soundness`). Why it exists: a prose spec has no oracle, so documentation
precision/completeness findings are inexhaustible — a gate that blocks on ALL verified
Importants never converges (two 10/10-EXHAUSTED loops proved this). This rubric refines the
SEVERITY gate only; the quorum + ledger anti-thrash gates are UNCHANGED.

## Classify every verified Critical/Important finding as SOUNDNESS or POLISH

**SOUNDNESS-BLOCKING** — APPLY it, and it BLOCKS a clean verdict. Qualifies ONLY if,
taking the target AS WRITTEN, a competent implementer would build something INCORRECT,
INSECURE, or NON-FUNCTIONAL. At least one of:
- (S1) SECURITY: a described mechanism fails to close a stated threat, or opens a new
  exfil / RCE / privilege-escalation / forgery / resource-exhaustion vector.
  (Real examples: a reap-ordering TOCTOU exfil window; a terminal-marker forgery hole;
  a trust-mode config that silently dropped a reviewer lockdown.)
- (S2) CORRECTNESS / LIVENESS: the described control flow, ordering, gate, or
  classification produces a wrong outcome or hangs.
  (Real examples: a write into a not-yet-created directory → watcher hang; a stale
  restored manifest honored as fresh; `rm -f` aborting a script on a planted directory.)
- (S3) LOAD-BEARING CONTRADICTION: two parts mandate incompatible behavior so an
  implementer cannot build both / would build the broken one.
  (Real examples: a prompt-file filename mismatch → empty reviewer stdin; "logic
  unchanged" vs "logic modified" asserted about the same component.)

**POLISH** — append to `.committee-loop-POLISH.md`; does NOT block a clean verdict and is
NOT applied by the loop. A legitimate improvement where a competent implementer would
STILL build the correct, secure, functional thing:
- Documentation precision / wording / terminology / readability / prose density.
- AC / test-list completeness for behavior that IS already specified correctly (a missing
  AC bullet, a re-verify-on-upgrade note, a platform-scope note).
- Change-surface / enumeration completeness where the obligation is already stated in prose.
- Non-behavioral cross-reference drift, stale meta-notes, section decomposition,
  normative-vs-"e.g." wording where intent is unambiguous from context.

**Tie-breaker:** "Would the BUILT system be broken/insecure without this change?"
yes → SOUNDNESS; no → POLISH. When genuinely unsure, classify SOUNDNESS — this gate must
never backlog a disguised defect.

## Unchanged
- MINOR findings → `.committee-loop-DEFERRED.md` (as before).
- QUORUM gate (≥2 reviewers agree, or single-reviewer + verifier-confirmed) — unchanged.
- LEDGER anti-thrash gate — unchanged.
- REFUTED findings — no action.

## Convergence criterion (under this gate)
A round with ZERO soundness-blocking findings is **SOUNDNESS-CONVERGED** — even if the
polish backlog is non-empty. That is the terminal state for a spec/plan target (the polish
backlog is addressed by a later editorial pass or folded during implementation). The
`REVIEW CLEAN` promise then means **SOUNDNESS CLEAN** — best-effort adversarial review,
not a correctness proof — never "every documentation nit resolved."
