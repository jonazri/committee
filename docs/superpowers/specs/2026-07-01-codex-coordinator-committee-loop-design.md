# Codex coordinator for committee-loop - design

**Status:** Draft design, 2026-07-01. Adds a repo-managed execution option for
`/committee-loop` where Codex, running GPT-5 with xhigh reasoning, is the inner
decision maker. Existing Claude coordinator behavior remains the default.

## Problem

`/committee-loop` currently launches a detached Claude Code session in an isolated
worktree. That inner Claude session owns the important decisions: how to prompt
reviewers, whether findings pass verification, which fixes to apply, whether
quorum/severity gates are satisfied, and when the loop may end cleanly. Codex is
one reviewer inside that system, not the authority.

The operator wants the opposite for Codex-launched committee loops: GPT-5 xhigh
should make the judgment calls. Using Codex only to run watchers, health checks,
or tmux plumbing is not the goal. The source of truth must stay in the
repo-managed committee skill at `/home/yaz/code/misc/committee`, so Claude and
Codex installs point at the same implementation instead of diverging.

## Goal / non-goals

**Goals**

1. Add a first-class `/committee-loop` execution option that launches Codex as
   the detached inner coordinator.
2. Make Codex, not Claude Workflow, responsible for prompting reviewers,
   verifying findings, accepting/rejecting issues, applying fixes, and deciding
   completion.
3. Preserve the existing Claude coordinator path byte-for-byte where practical,
   with `--coordinator=claude` as the default.
4. Keep the existing worktree, seed, watcher, health-check, and copy-back
   mechanics in `spawn.sh`.
5. Update the Codex plugin wrapper only after the repo-managed skill supports the
   flag, so Codex invocations use the shared source.

**Non-goals**

- Rewriting one-shot `/committee` in this change.
- Making Codex merely supervise the Claude loop.
- Calling `/committee` as the authoritative verifier in Codex coordinator mode.
  `/committee` is a Claude Workflow today, so using it as the gate would leave
  verification authority with Claude.
- Changing Headroom behavior.
- Changing reviewer model defaults except where needed to pass coordinator
  options through.

## Interface

Extend `.claude/skills/committee-loop/spawn.sh`:

```bash
/committee-loop [--coordinator=claude|codex] \
  [--coordinator-model=<codex-model-id>] \
  [--coordinator-effort=<minimal|low|medium|high|xhigh>] \
  [--models '<json>'] \
  <target-file> [<target-file> ...]
```

Defaults:

- `--coordinator=claude`
- Claude mode keeps the current `innerAgent` model/effort behavior.
- Codex mode inherits the Codex CLI's configured model unless
  `--coordinator-model` is passed.
- Codex mode defaults `--coordinator-effort=xhigh`.

Also accept the same values through `--models`:

```json
{
  "coordinator": {
    "provider": "codex",
    "model": "gpt-5.5",
    "effort": "xhigh"
  }
}
```

`--coordinator-*` flags win over `--models.coordinator.*` when both are present.
This keeps command-line use easy while preserving reproducible scripted configs.

## Architecture

### Existing Claude mode

Claude mode stays structurally unchanged:

1. `spawn.sh` validates args and target files.
2. It creates an isolated git worktree and seeds target files.
3. It writes `.committee-loop-instructions.md` from `inner-agent.md`.
4. It launches Claude in tmux.
5. The prompt tells Claude to run `/ralph-loop:ralph-loop`.
6. The current watcher, health-check, postback, and copy-back paths run as they
   do today.

Headroom wrapping remains on this path through the existing `build_inner_launch`
behavior.

### New Codex mode

Codex mode reuses the same outer mechanics but replaces the inner launch and
inner instructions:

1. `spawn.sh` validates `--coordinator=codex` and Codex model/effort tokens.
2. It creates and seeds the isolated worktree exactly as Claude mode does.
3. It writes `.committee-loop-instructions.md` from a new
   `codex-inner-agent.md`.
4. It writes a Codex runner script, for example
   `.committee-loop-codex-runner.sh`, so the tmux command does not need fragile
   shell quoting or prompt interpolation.
5. The runner invokes `codex exec` with stdin from `.committee-loop-prompt.txt`,
   `-C "$WORKTREE_PATH"`, the selected model, and
   `-c model_reasoning_effort=<effort>`.
6. Codex runs the loop directly. It does not invoke `/ralph-loop`, and it does
   not invoke `/committee` as the source of verified findings.
7. Codex writes the same terminal sidecars the watcher already understands:
   `.committee-loop-DONE.txt`, `.committee-loop-BLOCKED.txt`, or
   `.committee-loop-EXHAUSTED.txt`.
8. Codex runs `.committee-loop-post.sh` only after it has reached its own
   verified clean decision.

The runner script is preferred over a long tmux command because `codex exec`
can read the prompt from stdin. This avoids `ARG_MAX` and quote-escaping issues
with large instructions.

## Codex coordinator contract

`codex-inner-agent.md` defines the authority boundary:

- Codex is the coordinator and final judge.
- Reviewer outputs are evidence, not decisions.
- Codex must verify each actionable finding itself before applying it.
- Codex may run external reviewers, but it may not treat any external verifier
  or summary as authoritative.
- Codex must keep a decision ledger equivalent to the current Claude loop:
  issue, source reviewer, severity, verification evidence, decision, change
  made or reason rejected.
- Codex may apply only Critical or Important findings that it verifies as real
  and relevant to the target files.
- Minor findings are recorded but do not block completion unless they reveal a
  higher-severity issue.
- Completion requires a final Codex verification pass over the changed target
  files and a clean decision ledger.

The prompt should be written for Codex CLI capabilities: shell commands, file
reads/writes, local verification, and subprocess reviewer invocations. It should
not mention Claude-only slash commands, the Claude Agent tool, Workflow, or
`ralph-loop`.

## Reviewer evidence in Codex mode

Codex mode should use a small deterministic helper to collect reviewer evidence,
for example `codex-reviewers.sh`. The helper should:

- Accept the target file list, iteration number, trust level, and model override
  JSON.
- Run selected external reviewers in read-only posture.
- Write one output file per reviewer under `.committee-loop-reviewers/`.
- Return non-zero only for harness-level failures, not for an individual
  reviewer timing out.

Initial reviewer set:

- Claude reviewer via Claude CLI prompt, treated only as evidence.
- Kiro reviewer via `kiro-cli`, treated only as evidence.
- Gemini and Gemini-Pro reviewers via `agy`, treated only as evidence.
- Optional Codex self-review subprocess only if explicitly enabled. The default
  should avoid double-counting Codex as both judge and reviewer.

Codex then reads the raw reviewer outputs and performs its own verification.
This deliberately does not reuse `committee-review.js`, because that file is a
Claude Workflow with Claude verifier agents.

## Model override behavior

Extend `--models` validation to recognize:

```json
{
  "coordinator": {
    "provider": "codex",
    "model": "gpt-5.5",
    "effort": "xhigh"
  },
  "reviewers": {
    "claude": { "model": "sonnet" },
    "gemini-pro": { "enabled": true }
  }
}
```

Validation rules:

- `coordinator.provider` must be `claude` or `codex` if present.
- `coordinator.model` uses the existing token allowlist:
  `[A-Za-z0-9._-]+`.
- `coordinator.effort` must be lowercase and one of the Codex-supported effort
  values.
- `innerAgent` remains accepted as a backwards-compatible alias for the Claude
  coordinator.
- If `coordinator.provider=codex`, `innerAgent.*` is ignored unless no explicit
  Codex coordinator model/effort was supplied.

This maps the operator's "GPT-5 xhigh" intent onto the Codex CLI's actual
control surface: model id plus `model_reasoning_effort=xhigh`.

## Sandbox and unattended execution

Codex mode should prefer the narrowest unattended launch that works:

```bash
codex exec \
  -C "$WORKTREE_PATH" \
  --sandbox workspace-write \
  --add-dir "$ORIGIN_PATH" \
  --add-dir "$ORIGIN_GIT_DIR" \
  -m "$COORDINATOR_MODEL" \
  -c model_reasoning_effort="$COORDINATOR_EFFORT" \
  -o "$WORKTREE_PATH/.committee-loop-codex-last-message.md" \
  - < "$PROMPT_FILE"
```

The added directories are needed because the worktree's git metadata points
back to the origin repo, and copy-back writes to the origin checkout. If this
proves insufficient for unattended git operations, the implementation should
add an explicit opt-in escape hatch such as `COMMITTEE_CODEX_DANGER=1` before
using `--dangerously-bypass-approvals-and-sandbox`.

The acceptance bar is unattended execution in the existing isolated worktree
model without requiring the operator to answer prompts.

## Codex plugin wrapper

After the repo skill supports Codex coordination, update the installed Codex
plugin command for `/committee-workflows:committee-loop`:

- Keep delegating to the repo-managed workflow source.
- Add `--coordinator=codex` by default when the user invokes the loop from
  Codex.
- Do not add `--coordinator=codex` when the user explicitly asks for the Claude
  coordinator.
- Keep `/committee` and `/review-pr` unchanged.

This makes Codex-launched loops use GPT-5 xhigh as the decision maker while
leaving Claude-launched loops compatible with existing behavior.

## Change surface

| File | Change |
|---|---|
| `.claude/skills/committee-loop/spawn.sh` | Parse coordinator flags, validate coordinator config, split Claude/Codex launch paths, generate Codex runner script |
| `.claude/skills/committee-loop/codex-inner-agent.md` | New Codex-native coordinator instructions |
| `.claude/skills/committee-loop/codex-reviewers.sh` | New helper for evidence collection from external reviewers |
| `.claude/skills/committee-loop/SKILL.md` | Document `--coordinator=codex` and model/effort controls |
| `CLAUDE.md` | Document coordinator modes and the authority boundary |
| `scripts/codex-coordinator-launch-smoke.sh` | Smoke tests for launch-string/config behavior |
| `/home/yaz/plugins/committee-workflows/...` | After repo support lands, update Codex wrapper to pass the new flag |

## Verification / acceptance criteria

1. `spawn.sh --print-inner-launch` or an equivalent smoke hook proves the
   default Claude launch remains unchanged.
2. A Codex launch smoke test with stubbed `codex` asserts:
   - `--coordinator=codex` selects `codex exec`.
   - `model_reasoning_effort=xhigh` is passed by default.
   - `--coordinator-model` and `--coordinator-effort` override defaults.
   - `--models.coordinator` maps correctly.
   - invalid coordinator provider/model/effort fails before worktree creation.
3. A prompt-generation smoke test confirms Codex mode uses
   `codex-inner-agent.md` and contains no `/ralph-loop`, `/committee`, Workflow,
   or Claude Agent-tool dependency.
4. A fake-reviewer loop test confirms Codex mode can collect reviewer evidence,
   write a decision ledger, write a terminal sidecar, and invoke postback without
   real model calls.
5. A short live run on a trivial target confirms:
   - tmux session starts.
   - watcher and health-check still report useful state.
   - Codex writes a terminal sidecar.
   - copy-back behavior matches Claude mode.
6. Existing Claude coordinator smoke tests still pass.
7. The Codex plugin wrapper launches `/committee-loop --coordinator=codex` from
   Codex after repo support is installed.

## Risks and mitigations

- **Accidentally leaving Claude as verifier.** Mitigation: Codex mode must not
  call `/committee` as the authority. Tests scan the Codex prompt for Claude-only
  dependencies.
- **`codex exec` blocks on permissions.** Mitigation: start with
  `workspace-write` plus explicit `--add-dir` paths; add an explicit danger-mode
  opt-in only if the narrow launch cannot run unattended.
- **Reviewer output parsing is lossy.** Mitigation: reviewer helper writes raw
  outputs; Codex reads evidence directly and records verification evidence in
  the ledger instead of depending on structured reviewer JSON.
- **Double-counting Codex.** Mitigation: do not enable a separate Codex reviewer
  by default when Codex is coordinator.
- **Behavior drift between Claude and Codex modes.** Mitigation: share outer
  mechanics in `spawn.sh`; split only the inner instructions, reviewer evidence
  helper, and launch command.

## Open implementation notes

- Prefer adding a sourceable launch helper rather than widening the existing
  `build_inner_launch` in place if that keeps the Headroom Claude path simple.
- Keep the Codex runner script generated in the worktree so it can quote paths
  with `%q` and read the prompt from stdin.
- Preserve the existing target-path allowlist and copy-back guardrails. Codex
  mode should not expand the writable path surface beyond origin/worktree/git
  metadata.
- The first implementation plan should start with tests around argument parsing
  and launch generation before adding the Codex prompt.
