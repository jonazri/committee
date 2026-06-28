# Route committee's Claude coordinator + reviewers through Headroom — design

**Status:** Approved design, 2026-06-28. Integrates the [Headroom](https://headroom-docs.vercel.app)
context-compression proxy into `/committee` and `/committee-loop` so the Claude-side work (coordinator
+ Claude reviewer + the per-reviewer verifiers) routes through Headroom when it is installed, cutting
token usage on the dominant cost center. Scope decision (operator, 2026-06-28): **Claude-side only** —
Codex/Kiro/Gemini stay on their native backends.

**REVISION (2026-06-28, during implementation — SUPERSEDES every `--no-serena` mention below).** Live
testing showed `headroom wrap claude --no-serena` *removes* Serena from the user's **global**
`~/.claude.json` (a persistent change, with a "restart Claude Code" notice) rather than scoping to the
launch. `--no-serena` was therefore **dropped**: the implemented wrap is plain
`headroom wrap claude -- <claude args>`, which keeps the Headroom MCP registered (so `headroom_retrieve`
works) and is idempotent for a user who already has Serena — it never removes it. Wherever this spec
says "pass `--no-serena`" or explains it, read it as "do **not** pass `--no-serena`"; the rest of each
such statement (keep the Headroom MCP, rely on `--tool-search`'s default) still holds.

## Problem

Committee spends the bulk of its tokens on **Claude-side** work:

- The **coordinator** — for `/committee-loop`, a detached `claude` session that runs the whole
  iterate-and-refine loop; for one-shot `/committee`, the operator's live session.
- The **Claude reviewer** — a `general-purpose` agent dispatched by `committee-review.js`.
- The **five per-reviewer verifiers** — one Claude agent per reviewer, re-checking every finding.

None of this is routed through any optimization layer today. Headroom (`headroom` CLI, v0.27.0, already
installed and running a persistent proxy on `:8787`) is an Anthropic/OpenAI-compatible proxy that
compresses tool outputs / context losslessly (60–95% token reduction, with an MCP `headroom_retrieve`
tool for on-demand expansion). The operator wants committee and committee-loop to run their coordinator
and reviewers through Headroom when it is present, using `headroom wrap claude`.

## Goal / non-goals

**Goals**

1. When `headroom` is installed, `/committee-loop` launches its detached coordinator via
   `headroom wrap claude`, so the coordinator **and every in-harness Claude agent it spawns**
   (Claude reviewer + all verifiers) route through Headroom automatically.
2. `/committee` (one-shot) detects whether the operator's session is already Headroom-routed and
   reports it; it documents how to get routing (`headroom wrap claude`). No behavioral change — the
   live session cannot re-wrap itself.
3. Verifiers (and the Claude reviewer / coordinator) treat Headroom compression as **lossless**: when a
   finding's evidence sits behind a compression marker, they expand it via the `headroom_retrieve` MCP
   tool for final claim verification — without burning tokens re-expanding everything every turn.
4. Graceful no-op when Headroom is absent or opted out: identical behavior to today.

**Non-goals**

- **Routing Codex/Kiro/Gemini.** Codex *could* route via `headroom wrap codex`, but that rewires its
  auth and persistently mutates `~/.codex/config.toml` — real risk of dropping the reviewer below
  quorum. Kiro (AWS Q / `q.us-east-1.amazonaws.com`) and Gemini (`agy` / Google Cloud Code Assist) are
  **not** Anthropic/OpenAI-compatible, so a Headroom Anthropic/OpenAI proxy physically cannot carry
  their traffic. All three stay native (documented).
- **Mutating the operator's global claude config.** We use per-launch `headroom wrap claude`, never
  `headroom init claude` (which installs durable global hooks/provider routing — the operator's call,
  not committee's).
- **Owning a proxy lifecycle.** `headroom wrap claude` reuses a running proxy by default and starts one
  only if none exists (torn down with the session). Committee does not start/stop a standalone proxy.

## Key facts established during research

1. `headroom wrap claude [CLAUDE_ARGS…]` sets `ANTHROPIC_BASE_URL` for the launched process and passes
   unknown flags through to `claude`. It **reuses an already-running proxy by default** (confirmed by
   operator); `--no-proxy` is therefore unnecessary.
2. **In-harness subagents inherit the session's `ANTHROPIC_BASE_URL`.** Workflow `agent()` calls and
   Task subagents run in the same process as the session, so wrapping one coordinator process routes
   the Claude reviewer + all verifiers with no per-agent change. This is the load-bearing mechanism.
3. `--tool-search` defaults to `true`, preserving Claude Code's deferred tool-loading. Committee's
   inner agent leans on Workflow/agents/MCP; without deferral a custom `ANTHROPIC_BASE_URL` makes
   Claude Code eagerly load every tool schema and bloat context (Headroom issue #746). We rely on the
   default and do **not** pass the flag (passing it would couple us to its continued existence).
4. `headroom wrap claude` registers the Headroom MCP server (and Serena) by default. We keep the
   Headroom MCP (so `headroom_retrieve` is available for lossless expansion) and do **not** pass
   `--no-serena` — that flag removes Serena from the user's global `~/.claude.json` (a persistent
   side effect, found during implementation); plain wrap never removes it.
5. Headroom compression is **non-destructive**; `headroom_retrieve` returns the original bytes for any
   compression marker (`[N items compressed… hash=…]`). Reviewers can navigate cheaply on the
   compressed view and pull raw bytes only for final verification.

## Design

### Component A — committee-loop coordinator (`spawn.sh`) — the real code change

`spawn.sh` currently launches the detached inner session as (≈ line 373):

```sh
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKTREE_PATH" \
  "claude --dangerously-skip-permissions $INNER_LAUNCH_EXTRA"
```

Introduce a small **pure, sourceable** helper that builds the inner-launch command string, and use it
for the tmux command:

```sh
# Build the command tmux runs for the detached inner Claude session.
# Wraps with Headroom when it's installed and not opted out; otherwise bare claude.
# Pure: depends only on $1 (the claude argv tail) + environment (PATH, COMMITTEE_HEADROOM).
build_inner_launch() {
  local claude_args="$1"   # e.g. "--dangerously-skip-permissions --effort high"
  if [ "${COMMITTEE_HEADROOM:-auto}" != "off" ] && command -v headroom >/dev/null 2>&1; then
    # `headroom wrap claude` reuses a running proxy (starts one if absent).
    # Do NOT pass --no-serena (it removes the user's global Serena). Keep the
    # Headroom MCP default so headroom_retrieve is available. Rely on --tool-search's default (true).
    # `--` delimits wrap options from claude args.
    printf '%s' "headroom wrap claude -- $claude_args"
  else
    printf '%s' "claude $claude_args"
  fi
}
```

Resulting launch matrix:

| Condition | Launch (inside tmux) |
|---|---|
| `headroom` on PATH **and** `COMMITTEE_HEADROOM != off` | `headroom wrap claude -- --dangerously-skip-permissions <INNER_LAUNCH_EXTRA>` |
| otherwise | `claude --dangerously-skip-permissions <INNER_LAUNCH_EXTRA>` (unchanged) |

Notes:
- **Opt-out:** `COMMITTEE_HEADROOM=off` forces bare `claude` even when Headroom is installed.
- **Port:** inherited via the environment (`HEADROOM_PORT` if the operator runs a non-default port);
  not hard-coded.
- **Preflight:** `headroom` is **not** added to `spawn.sh`'s required-tool preflight — it's optional.
- **Quoting:** `$INNER_LAUNCH_EXTRA` is already a controlled, token-validated string (built by the
  existing `--models` path); the helper must preserve current quoting/expansion exactly so the tmux
  command behaves identically to today apart from the prefix.

### Component B — one-shot `/committee` (detect + report + docs, no behavior change)

The coordinator is the operator's live session, which committee cannot re-wrap. So:

- **Detect & report:** in the SKILL's progress-notification step, detect routing — `ANTHROPIC_BASE_URL`
  is non-empty (the session was wrapped). Report one line: either
  *"Claude reviewer + verifiers are routing through Headroom ✓"* or a tip
  *"(launch via `headroom wrap claude` to route committee's Claude-side work through Headroom)"*.
  Informational only.
- **No changes** to `committee-review.js` dispatch, `prepare.sh`, or reviewer prompts — the Claude
  reviewer + verifiers auto-inherit when the operator wrapped the session.

### Component C — lossless retrieval as the verification contract (prompt touches)

- **`prompts/verifier.md` (primary):** add a short, graceful block: *"If a finding's evidence appears
  behind a Headroom compression marker (`[… compressed … hash=…]`), expand it losslessly via the
  Headroom retrieve MCP tool before issuing your verdict. Do this when confirming/refuting a specific
  claim — not as a per-turn habit."* Naturally a no-op when unwrapped (no markers, no tool).
- **Light one-liners** in `prompts/reviewers/claude.md` and `.claude/skills/committee-loop/inner-agent.md`:
  navigate on the compressed view to save tokens; pull raw bytes via the Headroom MCP tool only for
  final claim verification.

### Component D — documentation

- **CLAUDE.md:** a "Headroom integration" note covering what routes (Claude coordinator + Claude
  reviewer + 5 verifiers), what doesn't and *why* (Codex risk; Kiro=AWS Q, Gemini=agy not
  Anthropic/OpenAI-compatible), the `COMMITTEE_HEADROOM=off` opt-out, the proxy-reuse behavior, and the
  `--tool-search` rationale and why `--no-serena` is deliberately not used.
- **committee SKILL.md / committee-loop SKILL.md:** the one-shot "wrap your session" tip and the
  loop's auto-wrap behavior + opt-out.

## Change surface

| File | Change |
|---|---|
| `.claude/skills/committee-loop/spawn.sh` | `build_inner_launch` helper + opt-out; use it for the tmux launch |
| `prompts/verifier.md` | graceful "expand compression markers via MCP for final verification" block |
| `prompts/reviewers/claude.md` | one-liner: compressed-view navigation, raw via MCP for final verify |
| `.claude/skills/committee-loop/inner-agent.md` | one-liner: same guidance for the coordinator |
| `.claude/skills/committee/SKILL.md` | detect/report routing + "wrap your session" doc |
| `.claude/skills/committee-loop/SKILL.md` | auto-wrap behavior + opt-out doc |
| `CLAUDE.md` | "Headroom integration" section |
| `scripts/headroom-launch-smoke.sh` (new) | unit smoke test for `build_inner_launch` |

**No** changes to `committee-review.js` dispatch logic, `prepare.sh`, `static-prepass.sh`,
`agy-review.sh`, or the Codex/Kiro/Gemini reviewer paths.

## Verification / acceptance criteria

1. **Launch-string smoke test** (`scripts/headroom-launch-smoke.sh`, mirroring
   `scripts/agy-smoke-test.sh`): source `build_inner_launch`, stub `headroom` present/absent and
   `COMMITTEE_HEADROOM=off`, assert the launch string in all three cases (wrapped / opted-out / not
   installed). Pure function, no tmux/worktree side effects.
2. **Live wrap probe:** `headroom wrap claude -- -p "reply OK"` answers through the proxy
   and `headroom doctor`/stats show fresh traffic. Confirms the wrap+reuse path.
3. **End-to-end loop:** one short `/committee-loop` run on a trivial target — the inner session comes
   up wrapped (readiness poll still catches the TUI footer under wrap), the loop progresses, and
   findings parity vs. an unwrapped run is sane (lossless-retrieve backstop holds).
4. **Graceful absence:** with `COMMITTEE_HEADROOM=off` (or `headroom` off PATH), the launch string and
   loop behavior are byte-identical to today.

## Risks & mitigations

- **Readiness polling under wrap.** `spawn.sh` polls the tmux pane for the trust/bypass footer (≈30s).
  Proxy-reuse is fast and wrap execs claude, so the TUI should render in-window; verify empirically
  (criterion 3) and widen the window only if needed.
- **Compression fidelity on a precision task.** Mitigated structurally by lossless `headroom_retrieve`
  (Component C) + committee's existing verify-stage + quorum. The wrapped-vs-unwrapped parity check
  (criterion 3) is the sanity gate.
- **MCP registration side effects.** `wrap claude` may register the Headroom MCP into config; for the
  ephemeral worktree this is discarded with it, and Headroom MCP registration is idempotent for an
  operator already running Headroom. We do not pass `--no-serena` (it would remove the operator's global Serena).
