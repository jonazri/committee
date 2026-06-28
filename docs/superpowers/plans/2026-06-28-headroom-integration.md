# Headroom Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route committee's and committee-loop's Claude coordinator + Claude reviewer + per-reviewer verifiers through the Headroom compression proxy via per-launch `headroom wrap claude`, when Headroom is installed.

**Architecture:** committee-loop's `spawn.sh` launches its detached inner `claude` through `headroom wrap claude` when the CLI is present; the inner coordinator and every in-harness Claude agent it spawns (Claude reviewer + 5 verifiers) inherit the session's `ANTHROPIC_BASE_URL` automatically. One-shot `/committee` can't re-wrap its live session, so it only detects + reports routing and documents the wrap-your-session path. Headroom compression is non-destructive; verifiers expand compression markers via the `headroom_retrieve` MCP tool for final claim verification. Codex/Kiro/Gemini stay native.

**Tech Stack:** Bash (`spawn.sh`, smoke test), Markdown skill/prompt files, the `headroom` CLI (v0.27.0), Claude Code skills/workflows.

> **Revised 2026-06-28 after committee plan-review (quorum 5/5, zero Critical).** All fixes were to verification scaffolding, not the core design: exact-path glob-free e2e teardown using `spawn.sh`'s stdout manifest (Task 4); hermetic smoke-test PATH guard (Task 1); 4-backtick outer fences (Task 3); case-insensitive opt-out + a Headroom hint on readiness failure (Task 1); tightened routing detection (Task 3).

## Global Constraints

- **Per-launch wrap only.** Use `headroom wrap claude`; NEVER `headroom init claude` (it mutates the operator's global claude config).
- **Claude-side only.** Do not route Codex (`headroom wrap codex` rewires auth + mutates `~/.codex/config.toml`), Kiro (AWS Q — not Anthropic/OpenAI-compatible), or Gemini (`agy`/Cloud Code Assist — not Anthropic/OpenAI-compatible). No changes to `committee-review.js` dispatch, `prepare.sh`, `static-prepass.sh`, `agy-review.sh`, or the Codex/Kiro/Gemini reviewer paths.
- **Graceful no-op.** With `headroom` off PATH OR `COMMITTEE_HEADROOM` set to `off` (any case), behavior is byte-identical to today.
- **`headroom` is optional** — do NOT add it to `spawn.sh`'s required-tool preflight loop.
- **Exact wrap invocation:** `headroom wrap claude --no-serena -- <claude args>`. `--no-serena` (inner agent doesn't use Serena; also sidesteps an error on hosts without Serena). Keep the Headroom MCP default (so `headroom_retrieve` is available). Do NOT pass `--tool-search` (rely on its default `true`; passing it couples us to the flag's existence). Headroom reuses a running proxy by default — do NOT pass `--no-proxy`.
- **Opt-out var:** `COMMITTEE_HEADROOM` — value `off` (case-insensitive) means "do not wrap"; anything else (incl. unset) means "auto" (wrap when installed).

---

### Task 1: `build_inner_launch` helper + self-test hook + wiring + readiness hint in `spawn.sh` (with smoke test)

**Files:**
- Create: `scripts/headroom-launch-smoke.sh`
- Modify: `.claude/skills/committee-loop/spawn.sh` (insert helper+hook after line 27; replace launch at lines 373–374; add a Headroom hint to the readiness-failure block ~lines 393–404 and widen the poll at line 378)

**Interfaces:**
- Produces: `build_inner_launch "<claude-args-string>"` → prints `headroom wrap claude --no-serena -- <claude-args-string>` when `headroom` is on PATH and `COMMITTEE_HEADROOM` is not `off` (case-insensitive), else `claude <claude-args-string>`. Pure (depends only on `$1` + `PATH` + `COMMITTEE_HEADROOM`).
- Produces: `spawn.sh --print-inner-launch "<claude-args-string>"` → prints `build_inner_launch "<args>"` + newline and exits 0, before any preflight/worktree/tmux work (side-effect-free self-test hook).

- [ ] **Step 1: Write the failing smoke test**

Create `scripts/headroom-launch-smoke.sh`:

```bash
#!/usr/bin/env bash
# Smoke test for spawn.sh's build_inner_launch (Headroom integration). Verifies
# the inner-launch command string in all three states with NO tmux/worktree side
# effects, by driving spawn.sh's `--print-inner-launch` self-test hook under a
# hermetic PATH whose only non-coreutil entry is a stub `headroom` we control.
# Mirrors scripts/agy-smoke-test.sh's note()/check()/exit "$fail" convention.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SPAWN="$HERE/../.claude/skills/committee-loop/spawn.sh"
ARGS="--dangerously-skip-permissions --effort high"
fail=0
note()  { printf '%s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then note "PASS: $3"; else note "FAIL: $3"; note "  got:  $1"; note "  want: $2"; fail=1; fi; }

[ -f "$SPAWN" ] || { note "FAIL: $SPAWN not found"; exit 1; }
grep -q 'build_inner_launch' "$SPAWN" \
  || { note "FAIL: build_inner_launch not present in spawn.sh (expected RED before implementation)"; exit 1; }

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT INT TERM
# Hermetic PATH: coreutils for spawn.sh's dirname/pwd, plus our controllable stub dir.
BASEPATH="$STUB:/usr/bin:/bin"

# Case 1: headroom installed -> wrapped
printf '#!/bin/sh\nexit 0\n' > "$STUB/headroom"; chmod +x "$STUB/headroom"
got=$(PATH="$BASEPATH" bash "$SPAWN" --print-inner-launch "$ARGS")
check "$got" "headroom wrap claude --no-serena -- $ARGS" "headroom installed -> wrapped launch"

# Case 2: opt-out via COMMITTEE_HEADROOM=OFF (case-insensitive) -> bare claude
got=$(PATH="$BASEPATH" COMMITTEE_HEADROOM=OFF bash "$SPAWN" --print-inner-launch "$ARGS")
check "$got" "claude $ARGS" "COMMITTEE_HEADROOM=OFF -> bare claude (case-insensitive, headroom present)"

# Case 3: headroom NOT installed -> bare claude.
# Hermeticity guard: if a system headroom is still reachable WITHOUT the stub
# (e.g. installed in /usr/bin), this case can't run hermetically — skip it with a
# NOTE instead of emitting a false FAIL (codex/gemini committee finding).
rm -f "$STUB/headroom"
if PATH="$BASEPATH" command -v headroom >/dev/null 2>&1; then
  note "SKIP: headroom reachable via system PATH without the stub — Case 3 not hermetic here"
else
  got=$(PATH="$BASEPATH" bash "$SPAWN" --print-inner-launch "$ARGS")
  check "$got" "claude $ARGS" "headroom absent -> bare claude"
fi

[ "$fail" = 0 ] && note "ALL SMOKE CHECKS PASSED" || note "SMOKE CHECKS FAILED"
exit "$fail"
```

Then: `chmod +x scripts/headroom-launch-smoke.sh`

- [ ] **Step 2: Run the smoke test to verify it fails**

Run: `bash scripts/headroom-launch-smoke.sh`
Expected: FAIL — `FAIL: build_inner_launch not present in spawn.sh (expected RED before implementation)`, exit 1.

- [ ] **Step 3: Add the helper + self-test hook to `spawn.sh`**

Insert this block immediately AFTER line 27 (the `trap 'cleanup_on_error 130' INT TERM HUP QUIT` line) and BEFORE line 29's `# ---- Preflight` comment:

```bash
# ---- Inner-launch command builder (Headroom integration) ----
# Build the command tmux runs for the detached inner Claude session. When the
# `headroom` CLI is installed (and not opted out via COMMITTEE_HEADROOM=off, any
# case), wrap the launch with `headroom wrap claude` so the inner coordinator AND
# every in-harness Claude agent it spawns (the /committee Claude reviewer + all
# per-reviewer verifiers) route through Headroom's compression proxy. Headroom
# reuses an already-running proxy by default (starts one if absent). Otherwise
# launch bare `claude`, byte-identical to the pre-integration behavior.
#   --no-serena : the inner agent never uses Serena — skip registering it (also
#                 sidesteps an error on hosts without Serena installed). The
#                 Headroom MCP stays registered (default) so `headroom_retrieve`
#                 is available; --tool-search keeps its default `true` (deferred
#                 tool-loading) — do not pass it. `--` delimits wrap's options
#                 from the claude args that follow.
# Pure: output depends only on $1 + PATH + COMMITTEE_HEADROOM, no side effects,
# so the --print-inner-launch self-test hook can exercise it.
build_inner_launch() {
  local claude_args="$1" optout=no
  case "${COMMITTEE_HEADROOM:-auto}" in [Oo][Ff][Ff]) optout=yes ;; esac
  if [ "$optout" = no ] && command -v headroom >/dev/null 2>&1; then
    printf '%s' "headroom wrap claude --no-serena -- $claude_args"
  else
    printf '%s' "claude $claude_args"
  fi
}

# Side-effect-free self-test hook for scripts/headroom-launch-smoke.sh: print the
# computed inner-launch command for the given claude-args string, then exit —
# before any preflight / worktree / tmux work runs.
if [ "${1:-}" = "--print-inner-launch" ]; then
  build_inner_launch "${2-}"; printf '\n'; exit 0
fi
```

- [ ] **Step 4: Wire the tmux launch to use the helper (and record whether it wrapped)**

Replace lines 373–374:

```bash
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKTREE_PATH" \
  "claude --dangerously-skip-permissions $INNER_LAUNCH_EXTRA"
```

with:

```bash
# build_inner_launch (top of file) routes this through Headroom when available.
INNER_LAUNCH=$(build_inner_launch "--dangerously-skip-permissions $INNER_LAUNCH_EXTRA")
case "$INNER_LAUNCH" in "headroom wrap "*) INNER_WRAPPED=1 ;; *) INNER_WRAPPED=0 ;; esac
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKTREE_PATH" \
  "$INNER_LAUNCH"
```

- [ ] **Step 5: Widen the readiness poll and add a Headroom hint on failure**

`headroom wrap` adds a small proxy-handshake latency before claude's TUI renders. Widen the poll and, on timeout, point at the opt-out when the launch was wrapped.

At line 378, change:
```bash
for _ in $(seq 1 30); do
```
to:
```bash
for _ in $(seq 1 45); do   # wider: `headroom wrap` adds proxy-handshake latency before the TUI
```

In the readiness-failure block, change:
```bash
if ! $READY; then
  echo "error: Claude input box did not render within 30s; aborting" >&2
```
to:
```bash
if ! $READY; then
  echo "error: Claude input box did not render within 45s; aborting" >&2
  if [ "${INNER_WRAPPED:-0}" = 1 ]; then
    echo "hint: the inner session was launched via 'headroom wrap claude'. If Headroom is the cause (proxy unreachable, or a headroom version without --no-serena), re-run with COMMITTEE_HEADROOM=off to bypass it." >&2
  fi
```

- [ ] **Step 6: Run the smoke test to verify it passes**

Run: `bash scripts/headroom-launch-smoke.sh`
Expected: PASS — `PASS:` lines (Case 3 may print `SKIP:` if headroom is system-installed) + `ALL SMOKE CHECKS PASSED`, exit 0.

- [ ] **Step 7: Verify the bash still parses cleanly**

Run: `bash -n .claude/skills/committee-loop/spawn.sh && echo OK`
Expected: `OK` (no syntax errors).

- [ ] **Step 8: Commit**

```bash
git add scripts/headroom-launch-smoke.sh .claude/skills/committee-loop/spawn.sh
git commit -m "feat(committee-loop): route detached coordinator through headroom wrap claude"
```

---

### Task 2: Lossless-retrieve verification contract in the prompts

**Files:**
- Modify: `prompts/verifier.md` (add a bullet under "## Your Task" step 3, after the third-party-SDK bullet ~line 35)
- Modify: `prompts/reviewers/claude.md` (add a paragraph after the "REVIEWER, not an implementer" paragraph at line 5)
- Modify: `.claude/skills/committee-loop/inner-agent.md` (add a bullet to step 3's "Each verifier:" list, after the "Returns a decision proposal per finding…" bullet ~line 127)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: prompt text only; no code interface.

- [ ] **Step 1: Add the retrieve bullet to `prompts/verifier.md`**

In "## Your Task" → step 3 list, add this as a new item immediately after the existing "Third-party SDK/API-surface claims" bullet (the one ending "…do not let it stand as Critical."). **The leading 3-space indent is load-bearing** — it nests the bullet under numbered step 3; left-justifying it breaks the list. Copy verbatim including the indent:

```markdown
   - **Headroom compression markers.** If the evidence you need to confirm or refute a claim sits behind a Headroom compression marker (text like `[… compressed … hash=…]`) — in the diff, a file you Read, or a tool result — expand it losslessly via the Headroom retrieve MCP tool (`headroom_retrieve`) and verify against the original bytes. Headroom compression is non-destructive, so a verdict must rest on the expanded content, never on the marker. Do this only when a specific claim needs it for a final verdict, not as a per-turn habit (the compressed view is enough to navigate). When the session is not Headroom-wrapped there are no markers and no such tool — this is then a no-op.
```

- [ ] **Step 2: Add the retrieve paragraph to `prompts/reviewers/claude.md`**

Immediately after line 5 (the "**You are a REVIEWER, not an implementer.**" paragraph) — i.e. into the blank line before the `{REVIEW_LENS}` block at line 9 — insert:

```markdown

**Headroom-compressed context.** If part of the diff or a file you Read appears behind a Headroom compression marker (`[… compressed … hash=…]`), navigate on the compressed view to save tokens, but expand the original losslessly via the Headroom retrieve MCP tool (`headroom_retrieve`) before finalizing any finding that depends on those exact bytes. When the session is not Headroom-wrapped there are no markers and no such tool — ignore this.
```

- [ ] **Step 3: Add the retrieve bullet to `inner-agent.md`**

In "### 3. …" → the "Each verifier:" list, add a new `-` bullet immediately after the "Returns a decision proposal per finding with its verification evidence" bullet:

```markdown
- If a claim's evidence sits behind a Headroom compression marker (`[… compressed … hash=…]`), expands it losslessly via the Headroom retrieve MCP tool (`headroom_retrieve`) before issuing a verdict — Headroom compression is non-destructive, so the verdict rests on the original bytes, not the marker. (No-op when the session is not Headroom-wrapped; committee-loop's detached session is wrapped whenever `headroom` is installed.)
```

- [ ] **Step 4: Verify all three edits landed and existing content is intact**

Run:
```bash
grep -c 'headroom_retrieve' prompts/verifier.md prompts/reviewers/claude.md .claude/skills/committee-loop/inner-agent.md
grep -q 'Third-party SDK/API-surface claims' prompts/verifier.md && echo "verifier intact"
grep -q 'You are a REVIEWER, not an implementer' prompts/reviewers/claude.md && echo "claude intact"
grep -q 'Returns a decision proposal per finding' .claude/skills/committee-loop/inner-agent.md && echo "inner-agent intact"
```
Expected: each file reports `1` for `headroom_retrieve`; three `… intact` lines.

- [ ] **Step 5: Commit**

```bash
git add prompts/verifier.md prompts/reviewers/claude.md .claude/skills/committee-loop/inner-agent.md
git commit -m "feat(committee): verifiers expand headroom compression markers for final verification"
```

---

### Task 3: One-shot detect/report + documentation

**Files:**
- Modify: `.claude/skills/committee/SKILL.md` (add a routing-check note at the end of "## Progress notification", ~line 113–119)
- Modify: `.claude/skills/committee-loop/SKILL.md` (add a bullet in "## Notes", ~line 212)
- Modify: `CLAUDE.md` (add a "## Headroom integration" section after "## Architectural Notes", before "## Known Limitations")

**Interfaces:**
- Consumes: nothing.
- Produces: documentation + an informational SKILL step; no code interface.

- [ ] **Step 1: Add the routing-check note to `committee/SKILL.md`**

At the END of the "## Progress notification" section (after the "A single commit is ~5–8 min…" line), append the following. NOTE: the outer block uses **four** backticks so the inner three-backtick `bash` fence does not close it (committee finding) — when you paste, keep the outer ```` ```` ```` markers as 4 backticks:

````markdown

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

- `routed-confirmed`: add a line to the user — *"Claude reviewer + verifiers are routing through Headroom ✓ (your session is wrapped)."*
- `routed-maybe`: add — *"A custom Anthropic base URL is set; if you launched via `headroom wrap claude`, the Claude reviewer + verifiers route through Headroom."*
- neither (no output): add — *"(tip: launch your session via `headroom wrap claude` to route committee's Claude-side reviewers through Headroom — Codex/Kiro/Gemini stay native.)"*

This changes nothing about the review itself — it's purely a status line.
````

- [ ] **Step 2: Add the Headroom note to `committee-loop/SKILL.md`**

In the "## Notes" section, add this bullet (after the existing bullets):

```markdown
- **Headroom routing.** When the `headroom` CLI is installed, `spawn.sh` launches the detached inner session via `headroom wrap claude` (reusing your running proxy, or starting one), so the loop's coordinator + the `/committee` Claude reviewer + all per-reviewer verifiers route through Headroom's compression proxy. Codex/Kiro/Gemini stay on their native backends — a Headroom Anthropic/OpenAI proxy can't carry Kiro's AWS Q or Gemini's Cloud Code Assist traffic, and routing Codex would rewire its auth. Set `COMMITTEE_HEADROOM=off` to force bare `claude`. No effect when `headroom` isn't installed.
```

- [ ] **Step 3: Add the "Headroom integration" section to `CLAUDE.md`**

Insert this new section immediately after the "## Architectural Notes" section (before "## Known Limitations"):

```markdown
## Headroom integration

When the [Headroom](https://headroom-docs.vercel.app) CLI (`headroom`) is installed, committee routes its **Claude-side** work through Headroom's context-compression proxy to cut token usage:

- **committee-loop:** `spawn.sh`'s `build_inner_launch` launches the detached inner coordinator via `headroom wrap claude --no-serena -- <claude args>` (reuses a running proxy, or starts one). Because in-harness subagents inherit the session's `ANTHROPIC_BASE_URL`, this routes the coordinator **and** the `/committee` Claude reviewer **and** all five per-reviewer verifiers automatically. Set `COMMITTEE_HEADROOM=off` (case-insensitive) to force bare `claude`. `--no-serena` skips Serena registration (unused, and sidesteps an error on hosts without Serena); the Headroom MCP stays registered so `headroom_retrieve` is available; `--tool-search` keeps its default `true` so Claude Code's deferred tool-loading is preserved (a custom `ANTHROPIC_BASE_URL` otherwise makes Claude Code eagerly load every tool schema — Headroom issue #746). If a wrapped inner session won't come up, `spawn.sh` prints a hint pointing at the `COMMITTEE_HEADROOM=off` opt-out.
- **one-shot `/committee`:** the coordinator is your live session, which committee can't re-wrap — launch it yourself via `headroom wrap claude` to route the Claude reviewer + verifiers. The skill detects (`ANTHROPIC_BASE_URL` pointing at the Headroom port + `headroom` on PATH) and reports routing status; behavior is identical either way.
- **What does NOT route, and why:** Codex (`headroom wrap codex` rewires its auth and persistently mutates `~/.codex/config.toml` — risks dropping the reviewer below quorum), Kiro (AWS Q, `q.us-east-1.amazonaws.com`), and Gemini (`agy` / Google Cloud Code Assist) are not Anthropic/OpenAI-compatible, so a Headroom Anthropic/OpenAI proxy physically cannot carry them. They stay on their native backends.
- **Compression is non-destructive.** Reviewers/verifiers navigate cheaply on the compressed view and expand the raw bytes via the `headroom_retrieve` MCP tool for final claim verification (see `prompts/verifier.md`). committee's existing verify-stage + quorum backstop any fidelity loss.
- **Proxy lifecycle is Headroom's:** committee never runs `headroom init claude` (which would mutate your global claude config) and never starts/stops a standalone proxy.
```

- [ ] **Step 4: Verify the doc edits landed**

Run:
```bash
grep -q 'Headroom routing (informational' .claude/skills/committee/SKILL.md && echo "committee SKILL ok"
grep -q 'COMMITTEE_HEADROOM=off' .claude/skills/committee-loop/SKILL.md && echo "loop SKILL ok"
grep -q '## Headroom integration' CLAUDE.md && echo "CLAUDE.md ok"
```
Expected: three `… ok` lines.

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/committee/SKILL.md .claude/skills/committee-loop/SKILL.md CLAUDE.md
git commit -m "docs(committee): document headroom integration + one-shot routing detection"
```

---

### Task 4: Live verification (wrap probe + end-to-end with safe teardown)

**Files:** none modified (verification only).

**Interfaces:**
- Consumes: `build_inner_launch` + the wired launch (Task 1).
- Produces: confirmation that the real path works end-to-end.

- [ ] **Step 1: Confirm the live wrap path works**

Run (proves `headroom wrap claude --no-serena` answers through the proxy; the printed `OK` is the real signal — do not depend on `headroom doctor`'s JSON schema):
```bash
headroom wrap claude --no-serena -- -p "reply with the single word OK"
```
Expected: claude prints `OK`. If it errors specifically on `--no-serena`, STOP and report — a Headroom version without that flag means the integration's flag set must be re-evaluated. (Optional, best-effort: `headroom doctor` afterward should show the proxy healthy; its exact output schema is not asserted.)

- [ ] **Step 2: End-to-end committee-loop spawn on an EXISTING file, with exact-path teardown**

This proves the detached inner session comes up *wrapped* and that `spawn.sh`'s readiness poll catches the TUI under wrap (the poll runs INSIDE `spawn.sh` before it emits the manifest, so a successful return already means the wrapped TUI rendered in-window). Uses an existing committed file (no throwaway commits) and tears down ONLY the exact worktree/branch/session named in `spawn.sh`'s stdout manifest (no repo-wide globs — committee finding):

```bash
# Precondition: clean working tree so nothing unrelated is at risk.
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean — commit/stash first"; exit 1; }

# Spawn a real loop session against an existing small file; capture the manifest
# spawn.sh prints to stdout (%q-escaped KEY=value lines, sourceable).
MANIFEST=$(bash .claude/skills/committee-loop/spawn.sh prompts/verifier.md) || { echo "spawn failed"; printf '%s\n' "$MANIFEST"; exit 1; }
# Pull ONLY the exact names we need (each line is `KEY=<%q-value>`).
eval "$(printf '%s\n' "$MANIFEST" | grep -E '^(SESSION|WORKTREE_PATH|BRANCH|COMMITTEE_SOCKET)=')"

# Assert the detached pane's start command is the wrapped launch.
START_CMD=$(command tmux -L "$COMMITTEE_SOCKET" list-panes -t "$SESSION" -F '#{pane_start_command}' 2>/dev/null)
printf 'pane start command: %s\n' "$START_CMD"
case "$START_CMD" in
  *"headroom wrap claude --no-serena"*) echo "E2E PASS: inner session is Headroom-wrapped" ;;
  *) echo "E2E FAIL: inner session not wrapped (got: $START_CMD)" ;;
esac

# Teardown by EXACT name from the manifest — never a glob.
command tmux -L "$COMMITTEE_SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
git branch -D "$BRANCH" 2>/dev/null || true
git worktree prune
```
Expected: `E2E PASS: inner session is Headroom-wrapped`; teardown removes exactly the one worktree + branch + session it created. If `spawn.sh` aborts with the "input box did not render within 45s" error AND a Headroom hint, the wrapped launch is the suspect — re-run with `COMMITTEE_HEADROOM=off bash .claude/skills/committee-loop/spawn.sh prompts/verifier.md` to confirm bare-claude still works, then investigate the wrap path.

- [ ] **Step 3: Final smoke re-run + confirm parse**

Run: `bash scripts/headroom-launch-smoke.sh && bash -n .claude/skills/committee-loop/spawn.sh && echo OK`
Expected: `ALL SMOKE CHECKS PASSED` + `OK`. No commit (verification only).

---

## Self-Review

**Spec coverage:**
- Goal 1 (loop coordinator wrapped) → Task 1. ✓
- Goal 2 (one-shot detect/report + docs) → Task 3 Steps 1–3. ✓
- Goal 3 (lossless retrieve verification) → Task 2. ✓
- Goal 4 (graceful no-op) → Task 1 smoke Cases 2 & 3 + `bash -n`; opt-out is case-insensitive. ✓
- Non-goals (no Codex/Kiro/Gemini routing, no `init`, no proxy ownership) → Global Constraints + Task 3 Step 3. ✓
- Component A (`spawn.sh`) → Task 1. Component B (one-shot) → Task 3. Component C (prompts) → Task 2. Component D (docs) → Task 3. ✓
- Verification criteria 1–4 → Task 1 (smoke), Task 4 Step 1 (wrap probe), Task 4 Step 2 (e2e w/ safe teardown), Task 1 smoke Cases 2–3 (graceful absence). ✓

**Committee findings addressed:** e2e teardown now uses `spawn.sh`'s stdout manifest + exact names, no globs, existing file (no commits) [Important #1, #4]; smoke-test Case 3 has a hermeticity guard [Important #2]; Task 3 Step 1 uses a 4-backtick outer fence [Important #3]; readiness failure prints a Headroom hint + opt-out [Important #5]; routing detection checks the Headroom port and hedges otherwise [Minor #6]; verifier.md indent flagged load-bearing [Minor #7]; opt-out is case-insensitive [Minor #8]; wrap probe relies on `OK` output not the doctor schema [Minor #11].

**Placeholder scan:** No TBD/TODO; all code blocks complete; the only `<…>` are literal argument placeholders inside shown commands. ✓

**Type/name consistency:** `build_inner_launch`, `--print-inner-launch`, `COMMITTEE_HEADROOM`, `INNER_LAUNCH`, `INNER_WRAPPED`, and the exact wrap string `headroom wrap claude --no-serena -- …` are used identically across Tasks 1, 3, 4 and the smoke test. ✓
