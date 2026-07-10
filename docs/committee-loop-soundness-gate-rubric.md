# Soundness-only gate (post-Loop-4 reconfiguration)

Rationale: Loops 3 and 4 each ran the full 10/10 budget without converging because the
severity gate treated ANY verified Important as blocking — including documentation
precision/completeness/terminology findings on a 1,650-line prose spec, whose supply is
effectively inexhaustible. This gate refines the SEVERITY gate only (quorum + ledger
anti-thrash gates UNCHANGED) so that convergence is judged on DESIGN SOUNDNESS, with
doc-quality findings routed to a non-blocking polish backlog.

## Classify every verified Critical/Important finding as SOUNDNESS or POLISH

**SOUNDNESS-BLOCKING** — APPLY it, and it BLOCKS a clean verdict. Qualifies ONLY if,
taking the spec AS WRITTEN, a competent implementer would build something INCORRECT,
INSECURE, or NON-FUNCTIONAL. At least one of:
- (S1) SECURITY: a described mechanism fails to close a stated threat, or opens a new
  exfil / RCE / privilege-escalation / forgery / resource-exhaustion vector.
  (Loop examples: iter-10 reap-ordering TOCTOU; iter-7 CONVERGED-copy forgery; iter-8
  danger-mode Gemini-drop; iter-2 INREPO_HOME ambient bypass.)
- (S2) CORRECTNESS / LIVENESS: the described control flow, ordering, gate, or
  classification produces a wrong outcome or hangs.
  (Loop examples: step-2 write into a not-yet-mkdir'd $ART_DIR → watcher hang;
  branch-restored stale manifest/intent honored; `rm -f` aborting spawn on a planted dir.)
- (S3) LOAD-BEARING CONTRADICTION: two parts mandate incompatible behavior so an
  implementer cannot build both / would build the broken one.
  (Loop examples: prompt-file filename mismatch → empty codex stdin; "logic unchanged"
  vs "logic modified" for the watcher bodies.)

**POLISH** — route to `.committee-loop-POLISH.md`; does NOT block a clean verdict. A
legitimate improvement where a competent implementer would STILL build the correct,
secure, functional thing:
- Documentation precision / wording / terminology / readability / prose density.
- AC / test-list completeness for behavior that IS already specified correctly (a missing
  AC bullet, a re-verify-on-upgrade note, a platform-scope note).
- Change-surface / enumeration completeness where the obligation is already stated in prose.
- Non-behavioral cross-reference drift, stale meta-notes, section decomposition,
  normative-vs-"e.g." wording where intent is unambiguous from context.

**Tie-breaker:** "Would the BUILT system be broken/insecure without this change?"
yes → SOUNDNESS; no → POLISH.

## Unchanged
- MINOR findings → `.committee-loop-DEFERRED.md` (as before).
- QUORUM gate (≥2 reviewers agree, or single-reviewer + verifier-confirmed) — unchanged.
- LEDGER anti-thrash gate — unchanged.
- REFUTED findings — no action.

## Convergence criterion (under this gate)
A round with ZERO soundness-blocking findings is **SOUNDNESS-CONVERGED** — even if the
polish backlog is non-empty. That is the terminal state for a design spec (the polish
backlog is addressed by a later editorial pass or folded during implementation). If a
"promise" is used, it means **SOUNDNESS CLEAN**, not "every documentation nit resolved."
