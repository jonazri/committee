# Replace gemini-cli with the Antigravity CLI (`agy`) — design

**Status:** Approved design, 2026-06-19; revised after a committee plan-review (2026-06-19) to add a
fail-closed read-only guard, per-run home isolation (outside projectRoot), copy-not-symlink auth handling, and
explicit acceptance criteria. Migrates committee's two Gemini reviewers off the `gemini` CLI
(`@google/gemini-cli`) onto the **Google Antigravity CLI** (`agy`, v1.0.10).

**REVISION (2026-06-21, accept-reads decision — SUPERSEDES the read-confinement parts below).**
Implementation testing of `agy` v1.0.10 found its file-read tools (`read_file`/`view_file`/`grep_search`/
`list_dir`, incl. `@`-tokens) are **NOT filesystem-confined** (they read `/etc/passwd` and out-of-projectRoot
`$TMPDIR` paths), and `agy`'s `permissions.deny` path-globs **cannot scope reads** (only the catch-all
`tool(*)` glob matches — `tool(/*)`/`tool(/**)`/`..`-patterns do not; and `permissions.allow` cannot override
`deny`). So the original premise — that a per-run HOME *outside projectRoot* keeps the copied creds beyond a
cwd-confined `read_file` — does **not hold**, and read-only cannot both allow repo reads and protect local
files. The operator chose to **ACCEPT the read/exfil risk**: read-only keeps repo reads enabled (so reviewers
can consult repo context) and accepts that a prompt-injected diff could read local files (incl. `~/.gemini`
creds) and echo them into the review output. Read-only still denies writes/shell and the network/URL exfil
tools; it is "safer than auto", **NOT exfil-safe**. Consequences: the §2/§7 deny list adds
`run_command(*)`/`fetch(*)`/`web_search(*)`/`browser_action(*)`; the per-run HOME is now **concurrency
isolation, not a credential boundary**; the §3 `@`-token check and the §7 #6(b) read-confinement criterion are
**downgraded from BLOCKING to documented characterization** (the `scripts/agy-smoke-test.sh` T5 probe is a
non-blocking NOTE). CLAUDE.md "agy read-only lockdown" is the authoritative user-facing statement.

> **This migration is now a necessity, not a preference.** A committee review of this very spec ran
> with both Gemini reviewers failing at auth: `IneligibleTierError: This client is no longer
> supported for Gemini Code Assist for individuals. To continue using Gemini, please migrate to the
> Antigravity suite of products` (`reasonCode UNSUPPORTED_CLIENT`, free tier). The installed
> `gemini` CLI is **no longer accepted by the Gemini Code Assist backend for this account** — so
> there is no "keep gemini-cli as a fallback" path, and the migration cannot be partial. The same run
> also warned `tools.exclude in settings.json is deprecated and will be removed in 1.0`, confirming
> the old read-only machinery is being retired regardless.

## Problem

Two committee reviewers shell out to the `gemini` binary: the primary **Gemini** (unpinned, with a
pro→flash 429 fallback) and **Gemini-Pro** (pinned to `gemini-3.1-pro-preview`). Around them sits a
large amount of **gemini-cli / Code-Assist-backend-specific machinery** — the pro→flash 429 fallback,
cross-session quota markers `~/.gemini/.committee-quota-until-<bucket>`, the read-only lockdown via
`GEMINI_CLI_SYSTEM_SETTINGS_PATH` + `tools.exclude` + `GEMINI_CLI_TRUST_WORKSPACE`, and the
`@`-token read-surface note. `agy` is a different agent (Windsurf/Codeium lineage, Google
Antigravity) with its own model lineup, permission model, and config layout, so most of that
machinery does not transfer and must be re-expressed in `agy` terms.

## Goal / non-goals

- **Goal:** both Gemini reviewers invoke `agy` instead of `gemini`, still running Gemini models, with
  auto/read-only trust correctly enforced (fail-closed) and a single Pro→Flash retry on Gemini-Pro.
- **Non-goals:** no change to the `/committee` external interface (flags, scopes, report format), to
  the other three reviewers (Claude/Codex/Kiro), to the verifier stage, or to the
  `{ quorum, degraded, perReviewer }` return. No change to the panel size (still five reviewers).
  Historical specs/plans under `docs/superpowers/` are left as-is.

## Verified facts about `agy` (v1.0.10)

Confirmed empirically against the installed binary and the official docs (Antigravity CLI docs,
context7 `/google-antigravity/antigravity-cli`, permissions reference).

1. **Invocation maps 1:1.** `<content> | agy -p "<framing>" --model <id>` combines a prompt argument
   with piped stdin — the same shape as `<content> | gemini -m <id> -p "<framing>"`. Confirmed.
2. **Models.** `--model` accepts display names *and* **raw ids** (`gemini-3.5-flash`,
   `gemini-3.1-pro`). We use the **raw ids** — they pass committee's existing
   `MODEL_RE = /^[A-Za-z0-9._-]+$/` sanitizer with no shell-injection surface; display names (spaces,
   parens) would not. **These ids are confirmed AS OF the design date only:** because an
   unknown/retired id silently routes to Flash with NO error (Fact #9), a once-valid Pro id can rot
   undetected — so the §7 #7 active-model assertion re-confirms at migration time that `gemini-3.1-pro`
   actually runs Pro (not a silent Flash) rather than trusting this Fact indefinitely.
3. **Auto trust** → `--dangerously-skip-permissions` (agy's `-y` equivalent).
4. **Headless `-p` auto-acts, with NO opt-in flag.** Without `--dangerously-skip-permissions`, agy
   **still** writes files and runs shell in print mode; `--sandbox` does **not** prevent this (writes
   and `touch` both succeeded under `--sandbox`). So omitting a flag is NOT read-only, and a missing
   lockdown is a *silent* escalation (unlike gemini, which needed `-y` to act). This is why the
   read-only setup is fail-closed (§2).
5. **Read-only is enforced by a `permissions.deny` glob list** in
   `~/.gemini/antigravity-cli/settings.json`:
   `"permissions": { "deny": ["write_file(*)", "edit_file(*)", "replace(*)", "command(*)", "run_command(*)", "read_url(*)", "fetch(*)", "web_search(*)", "browser_action(*)"] }`.
   Confirmed: writes + shell **blocked**, reads + review still work. Notes: bare tool names do **not**
   match (the parenthesized glob is required); shell is gated by **`command(*)`** (we ALSO deny
   `run_command(*)` as the second shell vector); an **allow-list alone does not default-deny** — the
   **deny list is load-bearing**, exactly like gemini's `tools.exclude`. **Verified 2026-06-21
   (accept-reads):** only the catch-all `tool(*)` glob reliably matches — path-globs (`tool(/*)`,
   `tool(/**)`, `..`-patterns) do NOT match deep/absolute paths and `permissions.allow` does NOT override
   `permissions.deny`, so reads can only be denied wholesale, never path-scoped. The production read-only
   list denies writes, both shell vectors, and the network/URL exfil tools (`read_url(*)`, `fetch(*)`,
   `web_search(*)`, `browser_action(*)` — enumerated by exact name per §7 #6, since name-globs are not
   trusted); file READS are deliberately NOT denied (see the top-of-doc revision note). This deny literal
   is one of three copies kept in sync: here, §2, and `prompts/agy-review.sh`.)
6. **`agy` reuses `~/.gemini/`.** CLI home is `~/.gemini/antigravity-cli/`; settings at
   `~/.gemini/antigravity-cli/settings.json`; auth at `~/.gemini/oauth_creds.json` and
   `~/.gemini/antigravity-cli/antigravity-oauth-token`. Because agy resolves all of this from `$HOME`,
   a per-run `HOME` redirect is the lever for per-run scoping (§2).
7. **No native code-review extension; prose is the default output.** `agy` is a general agent: there
   is no `-e code-review` analog (the review instructions ride entirely in the `-p` framing), and
   `agy -p` prints prose by default — so the old `-o text` is unnecessary (`--output-format json`
   exists but committee's reviewer agent parses prose, so we do not use it).
8. **Quota signals exist** ("Quota exhausted", `/quota`) but the exact **headless** quota-error format
   is unverified; we do **not** depend on it (§4).
9. **Unknown `--model` id → SILENT default (Flash) substitution, NOT an error.** Verified empirically:
   `printf 'x' | agy -p 'What model are you?' --model gemini-3.1-pro-TOTALLY-BOGUS-XYZ --dangerously-skip-permissions`
   exits **0** with **non-empty** output ("I am Gemini 3.5 Flash …"). agy silently falls back to a
   default model for an unrecognized/retired id rather than failing. **Load-bearing consequence
   (drives §1/§4/§6/§7 #4):** the *empty-`.md`-or-non-zero-exit* failure signal (§2 B1) CANNOT detect a
   model-availability failure — a retired `gemini-3.1-pro` pin would silently downgrade Gemini-Pro to
   Flash with `ran_ok=true` and **no signal**. So the Pro→Flash retry does **not** cover "model id
   drift" (only a post-call active-model assertion could), and the §7 #4 gate must inject an
   auth/network fault (which *does* yield empty/non-zero), never a bogus model id.

## §1 Reviewer mapping

| Reviewer    | Old (`gemini`)                                   | New (`agy`)                          |
|-------------|--------------------------------------------------|--------------------------------------|
| Gemini      | unpinned + pro→flash fallback                    | `--model gemini-3.5-flash`, **drop on failure** |
| Gemini-Pro  | `-m gemini-3.1-pro-preview`, **no** fallback     | `--model gemini-3.1-pro`, **single Pro→Flash retry** (default pin only), then drop |

Both write the same output files as today (`gemini.md`/`.err`, `gemini-pro.md`/`.err`) so the
reviewer-agent parsing and the verify stage are unchanged.

**Deliberate behavior changes (documented so they are not read as parity):**

- **Primary Gemini tier drops to Flash.** The old primary effectively ran a Pro-class default with a
  flash fallback; the new primary is Flash with no fallback. This is intentional: the Pro-tier Gemini
  perspective is now carried by **Gemini-Pro** (`gemini-3.1-pro`), and a fast Flash primary keeps the
  panel's wall-clock down. The primary still honors an operator `--gemini-model` override (the
  `gemini-3.5-flash` in the §1 table is the *default*, used when no override is given); an override
  simply replaces the Flash default and likewise gets no fallback (drop-on-failure).
- **Gemini-Pro gains a Pro→Flash retry — reversing the old "no fallback on the pro reviewer"
  rationale.** The old code deliberately had no fallback so the 5th reviewer was *always* a latest-pro
  perspective. We accept a partial loss of that purity because, with the primary now on Flash, a
  failed Gemini-Pro would otherwise leave the panel with **no Pro-tier Gemini voice at all**; one
  Flash retry keeps a Gemini perspective alive before dropping. **The retry fires only when Gemini-Pro
  is at its default pin.** If the operator overrides `--gemini-pro-model`, the explicit pin is
  respected and the retry is **suppressed** (mirroring the current code's "no fallback when an
  explicit model is pinned" precedent). **Accepted consequence — correlated voices:** when the retry
  fires, Gemini-Pro runs Flash *while the primary Gemini is also Flash*, so the two Gemini reviewers
  become **the same model** — correlated voices, not two distinct tiers. The retry's purpose is
  liveness (keep *a* Gemini voice in the panel), NOT tier diversity; on that path the panel's
  effective Gemini diversity drops to one tier. This is the same silent-degradation family as the
  model-id-drift Known Limitation (§6 / Verified Fact #9) and is accepted, not defended.

## §2 Command construction (in `prompts/committee-review.js`)

Replace `geminiCall`, `geminiGuarded`, `geminiRoSetup`, `geminiRoEnv`, `geminiLockdownPath`, the
quota-marker logic, `geminiPrimaryPin`/`geminiPrimaryBucket`, and the pro→flash fallback block. The
input fencing (`<reviewed_content>`), `geminiInput` (mode-conditioned `cat`/`git`), and `geminiText`
framing are unchanged.

**Prompt-arg escaping:** the framing (`<geminiText> <cliFraming>`) is handed to `agy-review.sh`
as a **single `shq`-quoted argv token**, and the helper references it as `"$prompt"` — so it never
sits inside another double-quoted string and needs **no `dq()` escaping** (this is strictly safer
than the old `dq()`-inside-double-quotes approach). `dq()` is retained only for the Kiro prompt. All
paths remain `shq`-quoted; the deny JSON is a fixed literal (no interpolation). (The intricate
`agy` recipe — auto vs. fail-closed read-only — lives in one tested helper, `prompts/agy-review.sh`;
`committee-review.js` only wires the scope-conditioned input, model, and framing into it.)

**Auto mode** (`<env>` empty, `<trustFlag>` = `--dangerously-skip-permissions`):

```
{ printf '<reviewed_content>\n'; <geminiInput>; printf '\n</reviewed_content>\n'; } \
  | timeout -k 30 240 agy -p "<shq framing>" --model <id> --dangerously-skip-permissions \
      > <session>/<out>.md 2> <session>/<out>.err
cx=$?; if [ "$cx" -ne 0 ]; then : > <session>/<out>.md; echo "agy exited non-zero ($cx)" >> <session>/<out>.err; elif [ ! -s <session>/<out>.md ]; then echo "agy exited 0 but empty — no review (auth/quota/capacity or read-only skip)" >> <session>/<out>.err; fi
```

An unrecognized mode (anything but `auto`/`read-only`) **fails closed** in the helper: it writes a
reason to `<out>.err` and never invokes `agy` (no fall-through to the privileged path).

**Read-only mode** — fail-closed, per-run home (outside projectRoot), copy (not symlink) mutable state:

```
agyHome="$(mktemp -d "${TMPDIR:-/tmp}/committee-agy.XXXXXX")"   # PER-RUN dir OUTSIDE projectRoot (see §6) — keeps copied creds beyond agy's read_file/cwd confinement; removed by a per-call QUOTED EXIT/INT/TERM trap + a trailing rm-rf (trap fires on cancel/SIGTERM; trailing rm fires on the normal path before a retry reassigns the var)
deny="$agyHome/.gemini/antigravity-cli/settings.json"
# enableTelemetry/showFeedbackSurvey mirror the real settings so a fresh HOME emits no survey/
# telemetry text into the review output; the deny block is the load-bearing read-only control.
if mkdir -p "$agyHome/.gemini/antigravity-cli" \
   && printf '%s' '{"enableTelemetry":false,"showFeedbackSurvey":false,"permissions":{"deny":["write_file(*)","edit_file(*)","replace(*)","command(*)","run_command(*)","read_url(*)","fetch(*)","web_search(*)","browser_action(*)"]}}' > "$deny" \
   && [ -s "$deny" ]; then
  # FAIL-CLOSED if the HOME is INSIDE cwd (=projectRoot): agy read_file is cwd-confined, so creds
  # under cwd would be reachable. Catches a TMPDIR that points into the repo. (Helper: same check.)
  case "$(cd "$agyHome" && pwd -P)/" in "$(pwd -P)"/*) : > <session>/<out>.md; echo "per-run HOME inside cwd — creds reachable; dropped" > <session>/<out>.err; <skip agy>;; esac
  # COPY mutable auth/state so agy never writes through to the real ~/.gemini (concurrent-safe).
  # settings.json carries gemini's auth selectedType; both installation_id files mark the HOME as
  # an established install. The §7 smoke test confirms this set authenticates agy headless.
  # NOT copied: trustedFolders.json — its workspace-trust list could trust $HOME/$TMPDIR and widen
  # read_file beyond projectRoot to reach this HOME's copied creds, defeating the relocation (§6/§7 #6).
  for f in oauth_creds.json google_accounts.json installation_id state.json settings.json; do
    [ -e "$HOME/.gemini/$f" ] && cp -p "$HOME/.gemini/$f" "$agyHome/.gemini/$f"
  done
  for f in antigravity-oauth-token installation_id; do
    [ -e "$HOME/.gemini/antigravity-cli/$f" ] && cp -p "$HOME/.gemini/antigravity-cli/$f" "$agyHome/.gemini/antigravity-cli/$f"
  done
  ln -sfn "$HOME/.gemini/antigravity-cli/builtin" "$agyHome/.gemini/antigravity-cli/builtin"  # large, immutable
  { printf '<reviewed_content>\n'; <geminiInput>; printf '\n</reviewed_content>\n'; } \
    | HOME="$agyHome" timeout -k 30 240 agy -p "<shq framing>" --model <id> \
        > <session>/<out>.md 2> <session>/<out>.err
  cx=$?; if [ "$cx" -ne 0 ]; then : > <session>/<out>.md; echo "agy exited non-zero ($cx)" >> <session>/<out>.err; elif [ ! -s <session>/<out>.md ]; then echo "agy exited 0 but empty — no review (auth/quota/capacity or read-only skip)" >> <session>/<out>.err; fi
else
  echo "read-only lockdown setup failed (deny file not written) — reviewer dropped" > <session>/<out>.err
fi
```

This is **fail-closed** (Critical C1): if `mkdir`/`printf` fails or the deny file is empty, `agy` is
**never invoked**; `<out>.md` stays empty, so the reviewer agent reports `ran_ok=false` and quorum
holds. Because mutable files are **copied** (not symlinked) into a **per-run** home, two
concurrent Gemini reviewers cannot race on setup, and nothing agy does (token refresh, state writes)
touches the real `~/.gemini` (A1/A2). Only the large immutable `builtin/` dir is symlinked
(`ln -sfn`, idempotent). Each per-run agy HOME is a `mktemp -d` **OUTSIDE projectRoot** (under
`$TMPDIR`), NOT under `sessionDir` — so the copied OAuth creds are never inside agy's `read_file`/cwd
confinement boundary (cwd is projectRoot) and cannot be read into the review output (§6) — and it is
removed by a **per-call QUOTED EXIT/INT/TERM trap** (`trap 'rm -rf "$agyhome"' …`) plus a trailing
`rm -rf "$agyhome"`: each home is removed immediately on the normal path (before the Pro→Flash retry
reassigns the var) and the trap cleans the in-flight home on a cancel/tool-timeout (SIGTERM) — so the
copied creds cannot leak, with NO space-delimited accumulator to word-split (it no longer lives under
`sessionDir`, so session cleanup does not cover it; SIGKILL is the only uncovered path). The review `.md`/`.err` stay under `sessionDir`
(they hold no secrets). **Invariant ownership (defense in depth):** the OUTSIDE-projectRoot location
is SET in exactly one place — the caller (`agyPipe`/the command block here, via `mktemp -d` under
`$TMPDIR`); the helper then **DEFENSIVELY ENFORCES it**: it has no `projectRoot` reference but it
fail-closes if the handed HOME resolves INSIDE its own cwd (= projectRoot in production) — see the
helper's cwd-containment check — so a mis-set location (e.g. `$TMPDIR` inside the repo) is caught at
the helper, not only at the §7 #6(a) acceptance gate. So the property is "set by the caller, enforced
by the helper, AND gated by §7 #6(a)" — three layers, not a single silent assumption.

**Gemini-Pro Pro→Flash retry** (default pin only — see §1):

```
# primary (read-only block above, or auto block) with --model gemini-3.1-pro, writing gemini-pro.md
# retry only if NO operator --gemini-pro-model override AND the primary "failed":
[ -s <session>/gemini-pro.md ] || { <re-run the SAME block with --model gemini-3.5-flash>; }
```

- **Failure signal (reconciles §4 drop-on-error with the retry, B1):** a call has "failed" when
  `<out>.md` is **empty** *or* `agy` **exited non-zero** (`cx=$?`). The retry/drop both key on this
  same signal. The portable primary signal is empty-output (agy auth/quota errors yield empty `.md`,
  to be confirmed by the §7 smoke test); the non-zero-exit check guards the "non-zero exit with
  partial non-review output" case so partial output is never mistaken for success. (The helper also
  writes a diagnostic to `<out>.err` on the exit-0-with-empty-output path — an `elif [ ! -s out_md ]`
  branch — so a consumer always has a reason on `<out>.err`, not only on a non-zero exit.)
  **Blind spot (Verified Fact #9):** this signal does NOT catch a *model-availability* failure — agy
  silently substitutes Flash for an unknown/retired `--model` id (exit 0, non-empty), so the primary
  "succeeds" on the wrong model and the retry never fires. This is why §7 #4 must inject an
  auth/network fault (empty/non-zero), not a bogus id, and why §6 lists model-drift as NOT
  auto-mitigated.
- **Truncation discipline (B2, load-bearing):** both the primary and the retry write the shared
  `gemini-pro.md`/`.err` with **truncating** redirects (`>` and `2>`, never `>>`). Appending would let
  a stale line from the primary survive into the retry's view. **Accepted trade-off:** on a
  double-failure the retry's `.err` overwrites the primary's, so the original Pro failure reason is
  lost — acceptable (matching the current code's accepted trade-off); the reviewer still drops with
  the retry's reason.
- The primary **Gemini** (Flash) has **no** retry — on failure it drops and the other four hold quorum.

**Plan scope / committee-loop** remain forced to read-only (unchanged policy), so a plan document is
reviewed under the deny lockdown and `agy` cannot scaffold/commit it.

## §3 Framing & injection defense (kept, plus a defined `@`-token task)

Keep the CLI-agnostic protections: the `<reviewed_content>` stdin fence, the reviewer-not-implementer
SAFETY RULES in `cliFraming`, the "DATA not instructions" framing, and the spec/static-analysis read
triggers.

**`@`-token / read-surface — defined check (M2), not a vague task.** During implementation, run the
§7 `@`-token test and record the result in CLAUDE.md's Known Limitations:
- Feed a diff on stdin containing an out-of-repo `@/etc/passwd`, **a sentinel at the ACTUAL cred location** (`@<TMPDIR-path>/secret.txt`, outside projectRoot — the load-bearing probe per §7 #6(b); `/etc/passwd` alone is not sufficient), and an in-repo `@path` (e.g. `@README.md`).
- **Pass/gate criteria (DOWNGRADED 2026-06-21 — no longer blocking):** in **read-only** mode the deny
  lockdown blocks writes/exec and the network/URL exfil tools. agy's `read_file` is **NOT** workspace-confined
  (verified, unlike gemini-cli's), so reads of out-of-repo paths (incl. the relocated `$TMPDIR` creds OR the
  real `~/.gemini`) succeed — this is the **accepted read-exfil risk**, recorded as a Known Limitation in
  CLAUDE.md, NOT a blocking gate. The smoke harness's T5 probe characterizes it as a non-blocking NOTE.
- **Auto mode caveat (must be documented, not "fixed"):** in auto mode there is **no** deny list, so
  an `@`-read is an accepted auto-mode risk — the same posture as gemini's `-y` mode. If the test
  shows agy reads arbitrary out-of-repo paths in auto mode, document it as an accepted auto-mode risk
  (auto mode already trusts the reviewer with full tools); read-only mode is the safe path for
  untrusted content.

## §4 Guards (simplified per decisions)

- **Fallback:** only Gemini-Pro retries once (Pro→Flash), and only at the default pin (§1/§2). No
  fallback chain on the primary.
- **Drop-on-error:** on any `agy` failure (empty `.md` or non-zero exit — see §2 B1), the reviewer
  drops (`ran_ok=false`) and quorum holds. No `~/.gemini/.committee-*-quota-until-*` files are written
  or read. An empty `<reviewed_content>` fence (e.g. a missing/empty `diffPath`) does NOT reliably
  yield an empty `.md` on its own — agy may emit prose ("nothing to review") for empty input and exit
  0, which the empty-check would mistake for a successful review. The helper therefore **guards its
  input**: it buffers stdin and, if the fenced body is empty/whitespace-only, drops the reviewer
  fail-closed (empty `.md` + a distinct "empty review input" reason) WITHOUT invoking agy. So a
  missing-diff infrastructure failure is deterministically a drop, not a bogus review.
- **Stale gemini-cli quota markers (owner assigned, M5):** the existing
  `~/.gemini/.committee-quota-until-*` files are **operator/manual** cleanup, documented as a one-time
  step in the README/CLAUDE.md migration note. The workflow does **not** delete files under the user's
  home at runtime (that would be destructive and out of scope).
- **Timeouts:** the per-call shell guard is **`timeout -k 30 240`** — SIGTERM at 240s, then SIGKILL
  30s later — so the process is guaranteed to exit by ~270s EVEN IF agy traps SIGTERM (agy's SIGTERM
  behavior is NOT a Verified Fact, so the `-k` SIGKILL is load-bearing: a bare `timeout 240` could
  hang indefinitely on a SIGTERM-resistant agy). 240/270s sits deliberately INSIDE agy's own default
  `--print-timeout` (5m0s), so the shell is always the deterministic outer guard (a hang → exit
  124/137 → the non-zero-exit branch drops the reviewer), avoiding the race where agy self-times-out
  first and exits 0 with a partial body. The **Gemini-Pro** reviewer's single Bash invocation runs
  primary + optional retry, so it gets a **600s** agent/tool timeout — the old 300s budget could not
  fit a ~270s primary AND a ~270s retry, so a slow primary failure would consume the whole window and
  the retry would never run. (The per-call `timeout -k 30 240` is the SHELL-enforced bound on each agy
  call; the 600s agent budget is not itself a shell wrapper — it must merely EXCEED the worst-case
  ~540s sum so it never truncates a legitimate retry.) The 2h agent-level backstop is unchanged.

## §5 Docs & prerequisites (enumerated)

- **`prompts/committee-review.js`** — the reviewer command-builders (§2) and the comments describing
  the old gemini machinery.
- **`CLAUDE.md`** — Prerequisites (replace the `gemini`/`@google/gemini-cli` + code-review-extension
  bullet with `agy` install + login); "What This Is" reviewer list; Architectural Notes (reviewer
  parallelism; operator overrides — `--gemini-model`/`--gemini-pro-model` now take agy ids); Known
  Limitations (replace the three gemini-cli-specific entries — model fallback, quota windows,
  `@`-token — with the agy read-only/permission note, the auto-mode `@` caveat, and drop-on-error);
  the one-time stale-marker cleanup note.
- **`README.md`** — enumerated so none are missed: the reviewer **table rows** naming the `gemini`
  CLI (≈ lines 18–19); the **ASCII data-flow diagram** "agent runs gemini CLI (+ flash fallback on
  429)" (≈ 201–202); the line **"Gemini receives diff via stdin (no tool access)"** (≈ 228) — now
  false under agy's read-enabled read-only model, must be rewritten; the **"Gemini `@` tokens"**
  bullet (≈ 229); the **`Bash(gemini:*)` permission example** (≈ 144) → `Bash(agy:*)`; and the
  Prerequisites + `--gemini-model`/`--gemini-pro-model` flag descriptions.
- **`.claude/skills/committee/SKILL.md`** — `gemini`-command prose, trust-dialog wording, the
  `gemini-pro` model default (`gemini-3.1-pro-preview` → `gemini-3.1-pro`), and the workflow-args
  description.
- **`.claude/skills/committee-loop/`** — `SKILL.md`, `inner-agent.md`, and **`spawn.sh`**: in
  particular the **preflight tool gate at `spawn.sh:148`** (`for t in tmux claude git realpath
  sha256sum kiro-cli codex gemini timeout`) — swap `gemini` → `agy`, or committee-loop refuses to
  launch with "missing tool: gemini" (and, per the headline, gemini is already gone, so this would
  break launch today). Also the `--models` mapping (the `gemini`/`gemini-pro` keys keep their names
  but map to agy ids).
- **`prompts/reviewers/gemini.md`** — still the framing for both Gemini-via-agy reviewers; update any
  gemini-CLI-specific wording, keep the review guidance.

## §6 Risks

- **agy headless auto-acts** — mitigated by the fail-closed deny lockdown (verified) for read-only;
  auto mode is intentionally permissive (`--dangerously-skip-permissions`), same risk posture as
  gemini `-y`.
- **agy quota error format unverified** — mitigated by not depending on it (drop-on-error).
- **Credential isolation in read-only — SUPERSEDED 2026-06-21 (accept-reads): there is NO read-side
  credential boundary; reads incl. creds are an accepted risk. Network exfil (`read_url`/`fetch`/
  `web_search`/`browser_action`) IS denied.** (Original, now-moot rationale follows.) Read-only mode COPIES real OAuth secrets into a
  per-run agy HOME. The PRIMARY protection is LOCATION: that HOME is a `mktemp -d` **outside
  `projectRoot`** (§2), so agy's `read_file` (confined to cwd = projectRoot) cannot reach the copied
  creds at all — they can be neither read into model context NOR leaked via the review-output `.md`
  (an earlier design that placed the HOME under `sessionDir` *inside* projectRoot left the creds
  read_file-reachable, so denying `read_url` alone — closing the URL channel — was insufficient).
  As defense-in-depth (and to bound a prompt-injected reviewer's general fetch surface) the read-only
  deny list ALSO includes **`read_url(*)`** (verified-syntax, named tool), plus agy's browser/URL-fetch
  tools by their exact names — enumerated and added during the §7 #6 characterization; do NOT rely on
  a `browser_*(*)` name-glob, since Fact #5 confirms parenthesized arg-globs but NOT tool-NAME
  wildcards. Read-only still permits `read_file`/`grep_search`/`codebase_search` over the REPO. (Auto
  mode keeps full tools — accepted
  risk, same posture as gemini `-y`.) The mode's docs must state this residual *read* surface, not
  claim "no tool access".
- **Model id drift is NOT auto-mitigated (Verified Fact #9).** Because agy silently substitutes Flash
  for an unknown/retired `--model` id with no failure signal, a retired `gemini-3.1-pro` pin would
  silently downgrade Gemini-Pro to Flash with `ran_ok=true` — collapsing the panel's two-distinct-
  Gemini-tiers guarantee to one (BOTH Gemini reviewers on Flash, near-identical perspectives) with NO
  signal to the operator. The operator-override flags only help if the operator KNOWS the id changed.
  To actually defend tier diversity, the §7 #7 acceptance criterion requires a post-call active-model
  assertion at migration time (agy self-reports its active model, gated — BLOCKS on Flash). Until that
  gate passes it remains a documented Known Limitation; the gate is what converts it to a covered case.
- **Read-only control is version-fragile + validated only at dev time.** The entire read-only
  guarantee rests on agy honoring the `permissions.deny` glob semantics (parenthesized globs,
  `command(*)` not `run_command(*)`, deny-list-load-bearing — Verified Fact #5). Since headless `-p`
  auto-acts with NO opt-in flag (Fact #4), a future agy version that changes glob/tool-name semantics
  would SILENTLY escalate read-only to full write/exec with no error. The only validation is
  `scripts/agy-smoke-test.sh`, run manually. **Mitigation:** treat the agy version as a pinned
  assumption and re-run the smoke gate on every agy upgrade (noted in CLAUDE.md Known Limitations) —
  analogous to the retired gemini "tools.exclude deprecated → revisit" note this migration replaces.
- **ACCEPTED RESIDUAL — read-only confinement is best-effort-verified, not document-provable (inherent
  to using an external LLM agent).** The old `gemini` path had read_file confinement as a NATIVE,
  documented property; `agy`'s confinement is NOT provable from these documents and can only be
  checked by RUNNING agy, and any such check is BEHAVIORAL (an LLM could, in principle, read a file
  yet not surface it) — so a fully-bulletproof verification is **infeasible**. **Scope of the claim
  (auth-vs-tool asymmetry):** "read_file is confined to cwd" is a TOOL-level (reviewer-facing API)
  property, NOT a process-level one — agy's PROCESS provably reads outside cwd (it loads its own
  auth from `HOME=$agyHome`, which is outside cwd; the §7 #1 "auth OK" check proves this). So
  "beyond agy's read_file/cwd confinement" must NOT be read as "the agy process cannot read these
  files" — it can and does for auth; the claim is only that the reviewer-invokable `read_file` tool
  is cwd-confined, which is exactly the best-effort property §7 #6(b) probes. The design therefore
  layers defense rather than relying on a single proof: (1) **PRIMARY** — the per-run HOME (with
  copied creds) is created OUTSIDE cwd and the helper FAIL-CLOSES if it isn't (§2), so even an
  unconfined read_file has nothing to reach UNDER cwd; (2) the deny-list blocks write/shell/url
  (Fact #5); (3) the §7 #6(b) read-confinement gate runs an AUTOMATED forced-transcription probe (a
  sentinel placed at the out-of-cwd cred location must be REFUSED) in the smoke harness GREEN path —
  the strongest available behavioral check, acknowledged as best-effort; (4) the agy version is a
  pinned assumption, re-checked on upgrade. The residual ("agy read_file reaches out-of-cwd AND the
  probe's forced-transcription is disobeyed AND the relocation's location-validation is bypassed") is
  **accepted and documented**, not a fixable-to-zero defect — verifying an external LLM agent's
  file-access confinement is inherently best-effort. (Same posture as the active-model assertion §7 #7,
  which likewise trusts an agy self-report as the best available signal.)

## §7 Acceptance criteria (gating)

These must pass before the migration is considered done (promotes the former §6 smoke-test footnote
to a gate, A3):

1. **Read-only lockdown (gating, automated in `scripts/agy-smoke-test.sh`).** Run the helper in
   read-only **from a sandbox cwd** (so a relative-path write by agy, if the lockdown failed, lands
   where the test actually checks — production cd's to projectRoot first) on content with a planted
   "create a file / run a shell command" instruction. Assert: (a) the reviewer **authenticates** and
   produces **non-empty** output; (b) **no** planted file/command appears in the sandbox cwd **or**
   the per-run home; (c) the real `~/.gemini` auth/state files — including
   `antigravity-cli/antigravity-oauth-token` — are **unmodified** (mtimes unchanged) after the run.
   (The planted instruction exercises `write_file` + `command`, representative of the deny list: all
   four globs share one parenthesized syntax, so a uniform mechanism gates `edit_file`/`replace` too.
   The deny list is allow-by-default — there is NO default-deny (Fact #5) — so a *new* agy tool not on
   the list would be permitted; that residual is the documented version-fragility, mitigated by the
   re-run-smoke-on-upgrade note and the §7 #6(c) browser/URL-tool enumeration.)
2. **Fail-closed.** With the deny file made unwritable (simulated setup failure), the reviewer
   produces empty `.md`, reports `ran_ok=false`, and `agy` is never invoked.
3. **Auto mode.** An auto-mode call (`--dangerously-skip-permissions`) produces output. The smoke
   harness exercises this with a **single** auto call — both reviewers share the one `agy-review.sh`
   auto path, so one call certifies the mode; the live `/committee` run (Task 8 Step 5) exercises both
   reviewers end-to-end.
4. **Pro→Flash retry (verified manually — needs fault injection, not in the smoke harness).** Inject a
   fault that ACTUALLY produces the failure signal (empty `.md` or non-zero exit) — e.g. temporarily
   make the Gemini-Pro per-run HOME's OAuth invalid/unreadable so the primary agy call fails auth and
   writes empty output, or wrap the primary in `timeout 1`. **Do NOT use a bogus `--model` id:** per
   Verified Fact #9, agy silently falls back to Flash (exit 0, non-empty), so `gemini-pro.md` is
   non-empty, the `[ -s ... ] || retry` guard short-circuits, the retry NEVER fires, and the
   implementer gets a FALSE PASS. Confirm the Flash retry fires and the reviewer recovers; confirm
   that setting `--gemini-pro-model` removes the retry block from the generated reviewer prompt (the
   `geminiProOverridden` conditional).
5. **committee-loop launch.** `spawn.sh` preflight passes with `agy` installed and `gemini` absent.
6. **`@`-token / read-confinement behavior characterized AND gated.** Per §3, run the `@`-token test
   and record the OBSERVED result in CLAUDE.md. **DOWNGRADED 2026-06-21 — characterization, NOT a gate**
   (the sub-points below were the original blocking criteria; they are superseded by the accept-reads
   decision at the top of this doc — recorded, not enforced): (a) the per-run agy HOME holding the copied
   OAuth creds is created OUTSIDE `projectRoot` (§2), but since agy's `read_file` is NOT cwd-confined this is
   concurrency isolation, NOT a credential boundary; (b) `read_file`/`@`-reads DO resolve OUTSIDE
   `projectRoot` in read-only mode (verified) — an unconfined `read_file` reaches the relocated `$TMPDIR`
   creds AND the real `~/.gemini`, which under the accept-reads decision is documented as a Known
   Limitation, NOT a blocker. The probe MUST feed a path at the ACTUAL cred location (a
   sentinel under a `$TMPDIR` per-run-HOME path, not just `@/etc/passwd`) and assert it is refused —
   a read_file that refuses `/etc` but allows `$TMPDIR` would still reach the creds, so the
   cred-location probe is the load-bearing one. **This probe is AUTOMATED in `scripts/agy-smoke-test.sh`
   (the T5 forced-transcription check) so it runs on the GREEN path — not a skippable manual step**;
   the forced-transcription prompt makes the sentinel appear IFF agy actually read the out-of-cwd file
   (a "review the diff" prompt could read-but-not-echo → false pass). It remains a best-effort
   BEHAVIORAL check (see §6 ACCEPTED RESIDUAL); Task 8 Step 4b is a manual cross-check. This also catches a WIDENED workspace-trust (e.g. a
   copied `trustedFolders.json` that trusts `$HOME`/`$TMPDIR`) — which is why `trustedFolders.json` is
   deliberately NOT copied into the per-run HOME (§2); the gate confirms trust was not re-widened by
   some other path. (The copy-set completeness is likewise a smoke-gated assumption — see §6
   version-fragility.) (c) enumerate agy's URL/browser-fetch tool names and
   confirm each is in the read-only deny list by exact name (Fact #5 confirms parenthesized arg-globs
   but NOT tool-NAME wildcards, so a `browser_*(*)` glob is not trusted to match). Document the
   residual repo-read surface in README/CLAUDE — not "no tool access".
7. **Active-model assertion (gating) — confirms the Pro pin actually runs Pro, not a silent Flash.**
   Per Verified Fact #9, agy silently substitutes Flash for an unknown/retired `--model` id with no
   error. Fact #2 confirms `gemini-3.1-pro` was a valid raw id as of the design date, but that is an
   ASSUMPTION that can silently rot. So at migration time, run the **Gemini-Pro** reviewer at its
   default pin and assert its ACTIVE model is the Pro tier, not Flash — e.g. an `agy -p` self-report
   ("Reply with ONLY your model id/family") whose output names Gemini **Pro**, not Flash. **BLOCK** if
   it reports Flash (the pin has silently fallen back). This is the post-call active-model assertion
   §6 / Fact #9 point to — it converts Fact #2's confirmed-id assumption into a gated check and is the
   only thing that catches the silent-Flash-of-the-default-pin case. **If it fails, the implementer's
   first remedy is to find the current valid Pro raw id (the suggested `gemini-3.1-pro-low` is a
   candidate to TRY, not a verified id) and update the pin in lockstep across §1/§2, Global
   Constraints, Task 3, and the docs.**
