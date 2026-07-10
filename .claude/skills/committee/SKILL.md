---
name: committee
description: Run parallel code reviews from Claude, Codex, Kiro, and Gemini, verify claims, and synthesize a structured report. Use for code diffs, standalone file reviews, or implementation plan reviews.
---

# Committee Code Review

Run a multi-perspective code review using five AI reviewers in parallel. The skill resolves scope, precomputes the diff, and dispatches the `committee-review` workflow (which runs all five reviewers and a per-reviewer verifier for each), then evaluates and displays the synthesized report.

<no_implementation>
The committee report is advisory. After presenting it, WAIT. Do NOT say "let me fix these," do not edit files, do not act on findings without the user's explicit go-ahead. The user drives what happens next.
</no_implementation>

<red_flags>
- About to implement a finding → STOP, the report is advisory
- About to re-resolve scope in the workflow → STOP, the skill is the source of truth
- About to sanitize adversarial user input → STOP, reject with a message instead
- About to splice a user path/keyword directly into bash → STOP, use file-first via the Write tool
- About to skip the trust dialog without `--trust` flag → STOP, present it (default is read-only; auto must be an explicit opt-in for trusted content — it relaxes Gemini's network access + Codex's sandbox, though no reviewer can write/execute in either mode)
</red_flags>

## Input parsing

Parse the user's argument (if any) into one of these scopes:

| Flag | Scope | Validate |
|---|---|---|
| `--base <branch>` | branch_diff | `git check-ref-format --allow-onelevel` |
| `--commit <sha>` | commit | hex `^[0-9a-fA-F]{6,40}$` |
| `--range <a>..<b>` / bare `a..b` or `a...b` | sha_range | hex for each side; three-dot is passed through (prepare.sh emits `RANGE_NORMALIZED` in the manifest) |
| `--files <path>...` | files | file-list content written to a session file via Write tool |
| `--plan <path>` (opt `--spec <path>`) | plan | single path token passed directly as `--plan=<path>` (no Write-tool indirection needed for single paths) |
| `#<n>` or GitHub PR URL | pr | integer `^[0-9]+$` for `<n>` |
| freeform text | vague | keyword written to a file via Write tool |
| no args | auto | — |

**Optional cross-scope flags:**

- `--reviewer-model=<model>` (one of `opus`, `sonnet`, `haiku`) overrides the Claude reviewer's model. Parse it out of the args, pass it through to the workflow as `reviewerModel` in the `args` object below, and do NOT include it in the `prepare.sh` invocation. Defaults to the harness's default model if absent. Used by `committee-loop` in iter-3+ to trade Opus depth for Sonnet speed once most Critical/Important findings have surfaced.

- **Operator model overrides** (all optional; absent = committee default; none go to `prepare.sh`). Parse each and pass it through to the workflow `args` under the named key. The workflow sanitizes model ids to `[A-Za-z0-9._-]`, effort levels to lowercase letters only (they are enums: `minimal|low|medium|high|xhigh`), and the verifier model to `opus|sonnet|haiku` (it is always a Claude agent) — anything invalid silently falls back to the default rather than erroring.
  - `--codex-model=<id>` → `codexModel` (e.g. `gpt-5.5`; default: codex CLI's configured model)
  - `--codex-effort=<level>` → `codexEffort` (lowercase, e.g. `xhigh`; default `high`)
  - `--gemini-model=<id>` → `geminiModel` (an `agy` model id; pins the primary Gemini reviewer, which runs via the `agy` CLI; default: `gemini-3.5-flash`, no fallback)
  - `--gemini-pro-model=<id>` → `geminiProModel` (an `agy` model id; pins the 5th Gemini-Pro reviewer, which runs via the `agy` CLI; default: the display name `Gemini 3.1 Pro (High)` — in agy v1.0.10 the High Pro tier is reachable only by display name; raw ids `gemini-3.1-pro-high`/`gemini-3.1-pro-medium`/bare `gemini-3.1-pro` silently fall back to Flash, and `gemini-3.1-pro-low` is the only working raw Pro id, giving the Low tier. An override goes through `MODEL_RE`, which rejects the display name's spaces/parens, so an operator can only pin a raw id like `gemini-3.1-pro-low`. At the default pin a single Pro→Flash retry to `gemini-3.5-flash` fires on empty output; passing `--gemini-pro-model` suppresses that retry.)
  - `--verifier-model=opus|sonnet|haiku` → `verifierModel` (default `sonnet`)
  - `--reviewers=<csv>` → `enabledReviewers` (a `,`-separated allowlist from `claude,codex,kiro,gemini,gemini-pro,fable`; runs ONLY those. Split on `,`, lowercase each, pass as a JSON array. Absent = the five defaults. `fable` is a 6th OPT-IN reviewer — a second Claude-family voice on the Fable model reusing the Claude reviewer lens; it joins only when named here, so the canonical 5-reviewer panel is unchanged for everyone else.)
  - `--fable-model=<id>` → `fableModel` (model for the opt-in Fable reviewer; default `fable`)
  - `--adjudications=<path>` → `adjudicationsPath` (single path token, argv-safe like `--plan`. A prior-adjudications context file — REFUTED/SETTLED/ACCEPTED-RISK items with evidence plus recently-edited regions. Primarily passed by `committee-loop`, which distills it from its decision ledger each round; the workflow injects it into every reviewer AND verifier prompt with a "re-raise only with NEW evidence" rule, and assigns one reviewer — Gemini-Pro when enabled, else Claude — an anti-recency coverage lens that hunts latent issues in NOT-recently-edited content. Constraints the workflow enforces (invalid → dropped with a logged warning): absolute path INSIDE the reviewed repo, charset `[A-Za-z0-9._/-]`, no `..` segments. Two carve-outs it logs rather than hides: on auto-trust commit/branch/uncommitted scopes the native `codex review` subcommand takes no prompt, so Codex misses the digest; a `--reviewers` subset excluding both gemini-pro and claude runs without the lens.)

  Effort is only honorable where the invocation exposes it: `--codex-effort` (Codex) and, in committee-loop, the inner-agent's spawn `--effort`. The in-workflow Claude reviewer / verifier / Gemini reviewers expose no per-agent effort knob, so only their **model** is overridable here. These are primarily driven by `committee-loop`'s operator model-override config (`.committee-loop-models.json`); a human can also pass them to a one-shot `/committee`.

- `--trust=<level>` (one of `auto`, `read-only`) pre-selects the trust level for CLI reviewers, skipping the interactive trust dialog below. Used by `committee-loop` to avoid blocking on the dialog in unattended `--dangerously-skip-permissions` sessions. Do NOT include in the `prepare.sh` invocation.

<validation>
Validate ALL user-supplied structured values BEFORE invoking `prepare.sh`:
- SHA / commit / range components: must match `^[0-9a-fA-F]{6,40}$` exactly.
- PR number: must match `^[0-9]+$`.
- Branch names: validate with `git check-ref-format --allow-onelevel "$name"` (reject on non-zero exit).
- For freeform text and file LISTS (multiple paths): write the content to a session file via the Write tool (no shell parsing), then pass the file path to `prepare.sh --*-file=<path>`. Never interpolate user-provided paths or keywords into bash command text.
- Single path tokens (e.g. `--plan=<path>`, `--spec=<path>`) flow through `--key=value` flag parsing safely: the Bash tool passes them as argv tokens (not shell text) and `prepare.sh` consistently quotes every expansion. Write-tool indirection is only required for list/content data.

If validation fails, abort before dispatching and tell the user which input was rejected. Do NOT attempt to sanitize adversarial input.
</validation>

## Resolve scope and set up the session

Locate the skill dir (handles both full install and SKILL.md-only symlink installs), then call `prepare.sh` with the scope + scope-specific args. `prepare.sh` preflights the git repo, creates `$PROJECT_ROOT/.committee/session-XXXXXX/`, writes `diff.txt` / `diff_stat.txt` / `diff.err`, emits a manifest on stdout and to `$SESSION_DIR/manifest.txt`, and prints a stderr warning for three-dot-normalized ranges (relay it to the user verbatim).

```bash
SKILL_DIR=""
while IFS= read -r candidate; do
  if [ -f "$candidate/prepare.sh" ]; then
    SKILL_DIR="$candidate"; break
  fi
  real=$(readlink -f -- "$candidate/SKILL.md" 2>/dev/null || true)
  if [ -n "$real" ]; then
    real_dir=$(dirname -- "$real")
    [ -f "$real_dir/prepare.sh" ] && { SKILL_DIR="$real_dir"; break; }
  fi
done < <(find "$HOME/.claude" .claude -type d -name committee 2>/dev/null)
[ -n "$SKILL_DIR" ] || { echo "committee skill not found (no prepare.sh)" >&2; exit 1; }
# Resolve committee's OWN prompts dir from the install location — NEVER from the
# repo under review. Reading `$PROJECT_ROOT/prompts/...` first would let a reviewed
# project that happens to contain a like-named file (e.g. its own
# prompts/reviewers/claude.md) shadow committee's prompt → broken substitution or
# prompt injection from untrusted code. Derive it from $SKILL_DIR instead.
PROMPTS_DIR=""
for cand in "$SKILL_DIR/../../../prompts" "$SKILL_DIR/prompts" "$HOME/.claude/skills/committee/prompts"; do
  [ -f "$cand/committee-review.js" ] && { PROMPTS_DIR=$(realpath "$cand"); break; }
done
[ -n "$PROMPTS_DIR" ] || { echo "committee prompts dir not found (looked under \$SKILL_DIR and ~/.claude)" >&2; exit 1; }
echo "PROMPTS_DIR=$PROMPTS_DIR"
bash "$SKILL_DIR/prepare.sh" --scope=<type> <scope-args>
```

**Scope-arg patterns** (match `--scope=<type>` to the invocation the user gave):

- `--scope=branch_diff   --base=<branch>`
- `--scope=commit        --commit=<sha>`
- `--scope=sha_range     --range=<a>..<b>`  *(or `--range=<a>...<b>` — pass three-dot through verbatim; `prepare.sh` normalizes it and emits `RANGE_NORMALIZED=1` in the manifest)*
- `--scope=pr            --pr=<n>  [--pr-url=<URL>]`
- `--scope=files         --paths-file=<path>`  *(first: `Write` tool writes one path per line to this file)*
- `--scope=plan          --plan=<path>  [--spec=<path>]`
- `--scope=uncommitted`
- `--scope=auto`
- `--scope=vague         --keywords-file=<path>`  *(first: `Write` tool writes the keyword string to this file)*

**Vague scope is a pre-step, not a dispatch.** `prepare.sh --scope=vague` lists candidate commits to stdout and exits 0 without creating a session. Show the output to the user and ask them to re-invoke `/committee` with an explicit scope.

Also capture `PROMPTS_DIR` from the `echo` above — the `committee-review` workflow and **every** committee prompt template it reads (reviewers/claude, reviewers/kiro, reviewers/gemini, verifier) load from `$PROMPTS_DIR`, never from `$PROJECT_ROOT`.

Parse the manifest to pull: `SESSION_DIR`, `PROJECT_ROOT`, `SCOPE_TYPE`, `SCOPE_DESCRIPTION`, `BASE_SHA`, `HEAD_SHA`, `COMMIT_SHA` (commit scope only), `BASE_BRANCH`, `HEAD_BRANCH`, `PR_NUMBER`, `PR_BASE_REF` (PR scope: the single ref prepare.sh fetched into the skill's `refs/pr-committee/` namespace; delete it on cleanup), `SPEC_PATH`, `RANGE_NORMALIZED` (sha_range scope: set to `1` when input was three-dot — surface this to the user verbatim: "Note: three-dot range was normalized to two-dot. Review covers changes between the two commits, not symmetric-diff against merge-base.").

## Progress notification

Before dispatching reviewers, tell the user the review has started and give a duration estimate:

> Starting committee review of <SCOPE_DESCRIPTION>. Running 5 reviewers in parallel — expect 8–10 minutes for the full report. I'll display it when complete.

A single commit is ~5–8 min; a large sha_range is ~8–10 min.

**Headroom routing (informational, optional).** committee can't wrap its own live session, but if you launched this session via `headroom wrap claude`, the Claude reviewer + all verifiers already route through Headroom (they inherit the session's `ANTHROPIC_BASE_URL`). Detect and report it — run:

```bash
HR_PORT="${HEADROOM_PORT:-8787}"
if [ -n "${ANTHROPIC_BASE_URL:-}" ] && command -v headroom >/dev/null 2>&1; then
  case "$ANTHROPIC_BASE_URL" in
    *":$HR_PORT"*) echo "routed-confirmed" ;;   # base URL points at the Headroom proxy port
    *)             echo "routed-maybe" ;;        # custom base URL, but not the Headroom port
  esac
fi
```

- `routed-confirmed`: tell the user "Claude reviewer + verifiers are routing through Headroom ✓ (your session is wrapped)."
- `routed-maybe`: tell the user "A custom Anthropic base URL is set; if you launched via `headroom wrap claude`, the Claude reviewer + verifiers route through Headroom."
- neither (no output): tell the user "(tip: launch your session via `headroom wrap claude` to route committee's Claude-side reviewers through Headroom — Codex/Kiro/Gemini stay native.)"

This changes nothing about the review itself — it is purely a status line.

## Trust level dialog

If `--trust=<level>` was parsed above, use that value directly and skip the interactive dialog.

Otherwise, call the `AskUserQuestion` tool with:
- **Question:** `What access level should the CLI reviewers (Gemini, Codex) have? (Gemini and Kiro can never write or run shell in either mode — this choice only affects Gemini's network access and Codex's sandbox.)`
- **Header:** `Trust level`
- **Option 1** — `Read-only (Recommended)` — `Safest; use for untrusted code. Gemini (agy) and Kiro run under a per-run-HOME permissions.deny lockdown — repo reads allowed, but writes, shell, AND URL/network fetch denied (fail-closed); Codex runs '--sandbox read-only'. Not exfil-safe: agy's reads are not filesystem-confined, so a prompt-injected diff could read local files and echo them into the review output (accepted risk).`
- **Option 2** — `Auto Mode` — `For TRUSTED content only. Relaxes the lockdown: Gemini (agy) may additionally use the network/web, and Codex follows your codex config's sandbox (which can allow writes if you widened it). Gemini and Kiro STILL cannot write to or run commands in your repo — writes/shell are denied in BOTH modes. The Claude reviewer inherits the parent session's auto-mode classifier either way.`

**Note for plan scope:** if the scope is `plan` (`--plan`/`--spec`), the workflow forces read-only regardless of the answer here. (As of 2026-06-23 no reviewer can write or execute in either mode anyway; forcing read-only for a plan additionally denies the network/URL exfil channel — the safest posture for untrusted imperative content.) You may still present the dialog (harmless), or just tell the user plan reviews always run read-only.

Record the answer as `auto` or `read-only`. Default to `read-only` if unanswered or on tool failure.

The value you record here is what you pass as the `trust` field in the workflow `args` object below (the **Dispatch the review workflow** section).

## Dispatch the review workflow

### Pre-dispatch check: the workflow file must exist

`prepare.sh` has already created `$SESSION_DIR` and (for PR scope) fetched `PR_BASE_REF` into the repo. BEFORE invoking the workflow, verify it exists at `$PROMPTS_DIR/committee-review.js`. (`$PROMPTS_DIR` was resolved from the install location above, so this also re-confirms the prompts dir is intact.)

If it is missing, abort cleanly:
1. Run `rm -rf -- "$SESSION_DIR"` to remove the session dir.
2. If the manifest has `PR_BASE_REF`, run `git update-ref -d "$PR_BASE_REF"` (single ref; no list parsing). The `refs/pull/$PR/head` ref is deliberately left alone — see the note in `prepare.sh`'s cleanup_on_exit.
3. Tell the user the workflow file was missing and stop.

### Build args and invoke the workflow

The `committee-review` workflow owns all five reviewers (Claude as a built-in `general-purpose` agent filled from `$PROMPTS_DIR/reviewers/claude.md`, the Codex/Kiro CLIs, plus both Gemini reviewers — which run via the `agy` (Antigravity) CLI, NOT the legacy `gemini` binary: the primary Gemini reviewer and a second Gemini pinned to the pro model via the display name `Gemini 3.1 Pro (High)`), runs a verifier agent per reviewer, and returns a structured result. The skill no longer dispatches Claude or any reviewer subagent itself, and it no longer fills the Claude template or picks the review lens — the workflow does that internally per `scopeType` (its `lensFor`/`focusAreas`).

Invoke the `Workflow` tool with `name: "committee-review"`. **If it errors as not-found / unknown workflow** (named user-scope resolution from `~/.claude/workflows/` is environment-dependent), immediately retry with `scriptPath` set to the **resolved** `$PROMPTS_DIR` value followed by `/committee-review.js` — substitute the absolute path (e.g. `/home/<you>/.claude/skills/committee/prompts/committee-review.js`), not the literal string `$PROMPTS_DIR`. Pass `args`:

```
{
  scopeType, scopeDescription, projectRoot,
  baseSha, headSha, commitSha, baseBranch, headBranch, prNumber, prBaseRef, specPath,
  sessionDir, promptsDir,
  diffPath: "<SESSION_DIR>/diff.txt", diffStatPath: "<SESSION_DIR>/diff_stat.txt",
  staticPath: "<SESSION_DIR>/static.txt",
  trust, reviewerModel,
  codexModel, codexEffort, geminiModel, geminiProModel, verifierModel, enabledReviewers,
  fableModel, adjudicationsPath
}
```

Substitute manifest values: `scopeType`=SCOPE_TYPE, `scopeDescription`=SCOPE_DESCRIPTION, `projectRoot`=PROJECT_ROOT, `promptsDir`=$PROMPTS_DIR (the install-resolved dir — the workflow loads every reviewer/verifier template from here, never from the repo under review), `sessionDir`=$SESSION_DIR, `baseSha`=BASE_SHA, `headSha`=HEAD_SHA, `commitSha`=COMMIT_SHA, `baseBranch`=BASE_BRANCH, `headBranch`=HEAD_BRANCH, `prNumber`=PR_NUMBER, `prBaseRef`=PR_BASE_REF, `specPath`=SPEC_PATH, `trust`=the recorded trust level, `reviewerModel`=the parsed `--reviewer-model` (omit if absent). The operator-override keys (`codexModel`/`codexEffort`/`geminiModel`/`geminiProModel`/`verifierModel`/`enabledReviewers`/`fableModel`/`adjudicationsPath`) come from the flags above — **omit any that weren't passed** (do NOT send empty strings; the workflow treats an omitted key as "use the default"). `enabledReviewers` is a JSON array of lowercase names. Omit fields you don't have (e.g. `prNumber`/`prBaseRef`/`baseBranch` outside their scopes). The workflow defaults absent SHAs to `none` and `commitSha` to `N/A`, sanitizes every override to `[A-Za-z0-9._-]` (dropping invalid ones), and accepts `args` whether the harness delivers it as an object or a JSON string.

## Failure modes

<failure_mode name="bash_error">
Any `prepare.sh` or pre-dispatch bash failure: print the error output to the user and STOP the workflow. `prepare.sh` cleans up its own session dir on error via its cleanup trap. Do not proceed to dispatch.
</failure_mode>

<failure_mode name="workflow_failed">
The `Workflow` call errored or returned no usable result → tell the user the review workflow failed, note that `$SESSION_DIR` is preserved for inspection, and STOP. Do not delete the session dir. For PR scope, still run `git update-ref -d "$PR_BASE_REF"` so the fetched `refs/pr-committee/*` ref is not left behind.
</failure_mode>

## Evaluate and display

The workflow returns `{ quorum, degraded, perReviewer: [{reviewer, ran_ok, note?, verified:[{title,severity,verdict,evidence,file?,detail?}]}] }`. `quorum` is the count of reviewers that ran (0–4); `degraded` is `quorum < 2`. Two extra shapes occur on degraded paths: a reviewer that ran clean has `verified:[]` (still counted in quorum); a reviewer whose verifier crashed has `verified:[]` plus a non-empty `findings:[…]` and a `note`.

1. If `degraded` is true (`quorum < 2`), present the degraded-quorum ABORT message — "Only N of 5 reviewers completed successfully. Minimum quorum is 2." — listing which reviewers failed (each `ran_ok:false` entry's `reviewer` + `note`), then go to **Cleanup**. No synthesis.
2. Otherwise invoke `superpowers:receiving-code-review` over the confirmed findings, then synthesize the **Critical/Important/Minor** report in the existing report format: dedup the same finding raised by multiple reviewers into one entry with multiple attributions; surface contradictions and refuted/unverifiable items; annotate any finding you judge technically unsound. **Verifier-failure fallback:** if a `perReviewer` entry has an empty `verified` array but a non-empty `findings` array plus a `note` indicating the verifier failed, surface those `findings` tagged `[Unverified]` rather than dropping them — the reviewer ran, only its verifier crashed.
3. Present the report. Then STOP (see `<no_implementation>` at top).

## Cleanup (after presenting)

Run `rm -rf -- "$SESSION_DIR"`. If PR scope and `PR_BASE_REF` is set, also `git update-ref -d "$PR_BASE_REF"`. If the `Workflow` call itself errored, do NOT delete `$SESSION_DIR` — tell the user it is preserved for inspection — but STILL run `git update-ref -d "$PR_BASE_REF"` for PR scope (committee's own `refs/pr-committee/*` namespace; leaving it leaks a stale ref).
