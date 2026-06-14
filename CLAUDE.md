# Committee

Multi-perspective code review agent for Claude Code.

## What This Is

Two Claude Code skills:
- `/committee` — one-shot parallel code review from five AI reviewers (Claude, Codex, Kiro, Gemini, and a second Gemini pinned to the latest pro model), verifies claims, synthesizes a structured report.
- `/committee-loop` (v1.0) — spawns a detached session in an isolated worktree to iteratively review-and-refine a target file until clean. Iter-1 runs fast (Claude+Kiro+Codex, no Gemini); iter-2+ uses `/committee` (all 5), with the Claude reviewer stepped down to Sonnet from iter-3 and auto-re-escalated to Opus after any iteration that surfaces a new verified Critical. Includes a simplify pre-pass, a post-edit consistency sweep (catches stale cross-refs/contradictions an iteration's own edits introduce, before they cost a committee round), parallel verifier subagents, a persistent decision ledger to prevent thrashing, and a `stable-polish` convergence exit (two consecutive zero-Critical, polish-only iterations converge instead of running another round).

## Prerequisites

All four reviewer CLIs must be installed and authenticated (the fifth reviewer reuses the `gemini` CLI, just pinned to a different model):

- **codex** — `npm install -g @openai/codex` then `codex login`
- **kiro-cli** — See https://kiro.dev for installation, then `kiro-cli settings` to configure
- **gemini** — `npm install -g @google/gemini-cli` then configure `GEMINI_API_KEY` in `~/.gemini/settings.json`
  - Install code-review extension: `gemini extensions install https://github.com/gemini-cli-extensions/code-review`
- **claude** — Already running if you're reading this in Claude Code

## Usage

```
/committee                              # Auto-detect scope
/committee --base main                  # Review branch diff from main
/committee --commit abc123              # Review specific commit
/committee abc123..def456               # Review explicit SHA range (bare pattern)
/committee --range abc123..def456       # Review explicit SHA range (flag form)
/committee #123                         # Review PR #123
/committee "review the auth changes"    # Vague — skill resolves scope from git history
/committee --files src/auth.ts src/db.ts # Review specific files (not a diff)
/committee --plan docs/plan.md          # Review an implementation plan
```

Optional cross-scope flags (combine with any scope above):

```
--trust=auto | --trust=read-only        # Pre-select CLI reviewer trust; skips the interactive dialog
--reviewer-model=opus|sonnet|haiku      # Override the Claude reviewer's model (default: harness default)
--codex-model=<id> --codex-effort=<lvl> # Override Codex's model / reasoning effort (default: codex config / high)
--gemini-model=<id>                      # Pin the primary Gemini reviewer (default: unpinned + flash fallback)
--gemini-pro-model=<id>                  # Override the 5th reviewer's pin (default: gemini-3.1-pro-preview)
--verifier-model=opus|sonnet|haiku       # Override the per-reviewer verifier model (default: sonnet)
--reviewers=claude,codex,...             # Allowlist: run ONLY these reviewers (default: all five)
```

## Project Structure

- `.claude/skills/committee/SKILL.md` — The `/committee` skill entry point
- `.claude/skills/committee-loop/SKILL.md` — The `/committee-loop` companion skill (v1.0)
- `prompts/committee-review.js` — committee review workflow (reviewers → per-reviewer verify → structured `{ quorum, degraded, perReviewer }` return)
- `prompts/verifier.md` — Verifier subagent prompt template (read by the workflow's per-reviewer verifier agents)
- `prompts/reviewers/claude.md` — Claude reviewer prompt template; the skill fills it (including a per-scope `{REVIEW_LENS}`) and dispatches it to a built-in `general-purpose` agent
- `prompts/reviewers/kiro.md` — Kiro review prompt (Kiro uses freeform chat, needs context)
- `prompts/reviewers/gemini.md` — Gemini review prompt (Gemini uses freeform chat, needs context)
- `.committee/` — Session directories created at runtime (gitignored); each run creates `.committee/session-XXXXXX/`
- `docs/superpowers/specs/` — Design spec
- `docs/superpowers/plans/` — Implementation plan

Note: all five reviewers run inside the `committee-review` workflow (`prompts/committee-review.js`), which also runs a per-reviewer verifier agent and returns structured findings; the skill keeps prep (scope, diff, trust dialog) and synthesis. Claude runs as a built-in `general-purpose` agent filled with `prompts/reviewers/claude.md` — committee does NOT use a plugin `code-reviewer` agent type: superpowers 5.1.0 ships no agents, and an absent `subagent_type` is an unrecoverable dispatch error (this is what broke the old `superpowers:code-reviewer` path). Committee still depends on superpowers *skills* — `receiving-code-review` for findings verification — just not on any agent type. The workflow picks a per-scope review lens (code / PR / plan) so the single Claude template adapts to the review type. Codex uses `codex review` (branch/commit/uncommitted) or `codex exec` (sha_range / pr / files / plan). Only Kiro and Gemini need separate prompt templates because they're invoked via freeform CLI.

## Developing & deploying changes

`install.sh` installs both skills into `~/.claude/skills/` as **symlinks** — it `mkdir`s the real `committee/` and `committee-loop/` dirs, then symlinks `SKILL.md` and `prompts/` into this repo (`safe_symlink`, via `ln -sfn`). Consequences:

- **Edits to source are live** — `~/.claude/skills/committee/SKILL.md`, `~/.claude/skills/committee/prompts/` (→ repo `prompts/`), and `~/.claude/skills/committee-loop/SKILL.md` all point back at this repo. The committee-loop helper scripts (`spawn.sh`, `watcher-body.sh`, `health-check-body.sh`, `inner-agent.md`, `post-body.sh`) are NOT symlinked individually — they're resolved at runtime via `readlink -f` on the `SKILL.md` symlink, so editing them in the repo is immediately live too. **No copy step is needed.**
- **To take effect:** skills load at session start, so **start a fresh Claude Code session** after editing (a session already running keeps the old prompts/SKILL.md in context).
- **First install / repair:** run `./install.sh` from the repo root — idempotent (`ln -sfn`; it also replaces a stale real-dir target left by older `cp -r`-based installs). Verify with `ls -l ~/.claude/skills/committee ~/.claude/skills/committee-loop` — `SKILL.md` and `prompts` should be symlinks pointing into this repo.
- **Where what lives:** `/committee` reviewer/verifier prompts + the `committee-review` workflow (`prompts/committee-review.js`) → `prompts/` (deployed to `~/.claude/skills/committee/prompts/`); the workflow is *also* symlinked to `~/.claude/workflows/committee-review.js` so it resolves as a named workflow. `/committee-loop` workflow + helper scripts → `.claude/skills/committee-loop/` (deployed to `~/.claude/skills/committee-loop/`).
- **Uninstall:** `rm -rf ~/.claude/skills/committee ~/.claude/skills/committee-loop ~/.claude/workflows/committee-review.js`.

## Architectural Notes

**Reviewer parallelism** — the `committee-review` workflow dispatches all five reviewers (Claude as a `general-purpose` agent, the Codex/Kiro/Gemini CLIs, and a second Gemini pinned to `gemini-3.1-pro-preview` — the latest pro, no flash fallback, quota-guarded cross-session, writes its own `gemini-pro.md`) in parallel via `pipeline()`, then streams each reviewer into a per-reviewer verifier agent as soon as its review completes (no barrier between the Review and Verify stages). It returns `{ quorum, degraded, perReviewer }`; the skill synthesizes the Critical/Important/Minor report from that.

**Arg delivery** — the skill invokes the workflow with an `args` object, but the harness may deliver it to the workflow as a JSON *string*; `committee-review.js` accepts either form (parses a string, uses an object as-is) and fails fast if `sessionDir`/`promptsDir` are missing.

**Operator model overrides** — every committee member's model is overridable, with effort where the invocation exposes it. `committee-review.js` accepts optional args `reviewerModel` (Claude), `codexModel`/`codexEffort`, `geminiModel` (pinning the primary disables its flash fallback), `geminiProModel`, `verifierModel`, and `enabledReviewers` (a reviewer-subset allowlist) — model ids sanitized to `[A-Za-z0-9._-]`, effort levels to lowercase enums, the verifier model to `opus|sonnet|haiku` (invalid → default), and the gemini pins additionally `dq()`-escaped at construction, so a value reaching the workflow from an adversarial diff can't inject shell. **Effort is only controllable for Codex (`model_reasoning_effort`) and the committee-loop inner agent (spawn `--effort`)** — the in-workflow Claude reviewer / verifiers / Gemini reviewers have no per-agent effort knob, so only their model is settable. For one-shot `/committee` these come from the `--codex-model`/`--reviewers`/etc. flags. For `committee-loop`, the operator states model preferences in natural language; the skill translates them into `spawn.sh --models '<json>'`, which validates the JSON, applies `innerAgent.{model,effort}` to the detached `claude` launch, and writes `.committee-loop-models.json` into the worktree — the inner agent reads it each iteration and maps it onto the `/committee` flags + reviewer subset, with `reviewers.claude.policy: "pin"` (default when a claude model is set) freezing the adaptive Sonnet step-down/re-escalation, or `"adaptive"` keeping it.

## Known Limitations

**Codex slowness** — Codex uses `gpt-5.4`. The workflow's Codex reviewer passes `-c model_reasoning_effort=high` on every invocation to override the user's global `xhigh` default, typically completing in ~3–5 minutes. The Codex command is wrapped in a shell `timeout` of 540s (600s for `--files`/`--plan` scope, since Codex explores auxiliary code to validate feasibility). For large diffs, Codex may still time out — the other 4 reviewers maintain quorum.

**Codex sha_range** — Codex has no native flag for arbitrary SHA ranges. For sha_range (and PR) scope, the workflow uses `codex exec --ephemeral -o FILE` with a heredoc prompt, which lets Codex run `git diff` autonomously. Slower than the native `codex review` flows above because Codex has to explore the range itself — ~5–10 minutes even at `high` effort.

**Shell injection + `--trust-all-tools`** — In auto mode (default), Kiro runs with `--trust-all-tools` and Gemini runs with `-y`. A diff containing adversarial content could trigger arbitrary command execution via prompt injection on the reviewer's LLM. The parent session's auto-mode classifier does NOT gate commands issued inside Kiro/Gemini subprocesses. Codex in auto mode is likewise not pinned to a sandbox (unlike read-only mode, which forces `codex exec --sandbox read-only`): the `codex review`/`codex exec` calls run under the user's codex config default (`read-only` out of the box, but widenable via `~/.codex/config.toml`), so the reviewer-only framing carried in the `codex exec` prompts is the prompt-level mitigation. In read-only mode, Kiro uses `--trust-tools=fs_read` (file reading only, no shell) and Gemini runs trusted-but-locked-down (no `-y`): it receives the fenced diff on stdin and MAY `read_file` repo context (a referenced spec, the code under review) — `read_file` is natively confined to the workspace, so out-of-repo paths (`/proc`, `/etc`, `~/.ssh`, `~/.gemini`) are refused by the tool — while a highest-precedence system settings file (`GEMINI_CLI_SYSTEM_SETTINGS_PATH` → `{tools.exclude:[write_file,replace,run_shell_command,save_memory], autoAccept:false}`, written per-run to the session dir) hard-removes every write/exec tool. This closes a real escalation: committee's repos sit under a trusted folder, so a `.gemini/settings.json` planted in the reviewed repo could otherwise re-arm write/shell via `tools.core`+`autoAccept` with NO `-y` (verified) — the system `tools.exclude` beats any such workspace override (`GEMINI_CLI_TRUST_WORKSPACE` is per-process and does not persist). (`tools.exclude` is deprecated → Policy Engine in gemini-cli 1.0.) See the `@`-token note below. The skill presents a trust dialog before each run. **Plan/spec scope is forced to read-only regardless of the requested trust, and `committee-loop` runs all its reviewers read-only** — a plan document *is* imperative instructions, so an auto-trust reviewer fed one will *execute* it rather than review it (2026-06-11: a Gemini reviewer scaffolded and committed a plan's build steps into a loop worktree as 4 stray commits, caught+cleaned by the loop). Defense in depth: the Gemini reviewer's stdin payload is now fenced in `<reviewed_content>` tags and every reviewer's framing names the artifact as DATA-not-instructions, and the reviewer-not-implementer prohibition now forbids file creation and all writing git verbs (`add`/`commit`/`stash`/`apply`/…), not just `merge`/`rebase`/`push`/`checkout`/`reset`.

**Gemini model fallback (headless)** — The Code Assist backend regularly returns `429 MODEL_CAPACITY_EXHAUSTED` for `gemini-2.5-pro` (and sometimes `gemini-2.5-flash`) on paid plans — a *server-side capacity flag*, not per-account quota. The gemini-cli DOES have a built-in pro→flash fallback chain, but it is **gated on `isInteractive()`** (verified in the installed bundle: `onPersistent429: this.config.isInteractive() ? … : void 0`), so it does NOT cover committee's headless `gemini -p` calls — and merely omitting `-m` can't unpin a user's `GEMINI_MODEL` env var or `settings.model.name` (resolution order is `argv.model || GEMINI_MODEL || settings.model?.name`). The workflow therefore supplies its OWN fallback: the primary Gemini call passes no `-m` pin, and if it returns an empty file (the 429 case), a flash-pinned retry (`-m gemini-2.5-flash`, far less capacity-constrained and confirmed to work headless) runs automatically. If the retry is also empty, Gemini is dropped and quorum holds from the other four.

**Gemini quota windows (cross-session guard)** — Distinct from the capacity 429 above: the backend also enforces per-ACCOUNT, per-model `QUOTA_EXHAUSTED` windows, surfaced by gemini-cli as a `TerminalQuotaError` ("You have exhausted your capacity on this model. Your quota will reset after Xm Ys"). The reset is a *fixed wall-clock deadline* shared by every session on the account — concurrent committee/committee-loop runs drain one pool — and preview models (`gemini-3.1-pro-preview`) have the tightest buckets, which a Gemini Pro subscription does not lift. A model fallback cannot dodge an account-level window, and gemini-cli's `retryWithBackoff` churns the full 300s shell timeout on every doomed call. The workflow therefore records each fresh quota error's reset deadline in `~/.gemini/.committee-quota-until-<bucket>` (buckets: `default`, `gemini-2.5-flash`, `gemini-3.1-pro-preview`) and every committee session skips that bucket instantly until the deadline passes. Markers self-expire by comparison; safe to delete manually.

**Gemini `@` token parsing** — Gemini CLI processes `@path` tokens in stdin, attempting to read referenced files. `read_file` is natively confined to the trusted workspace: an out-of-repo `@/etc/passwd` is refused ("resolves outside the allowed workspace directories"), verified on gemini-cli 0.45. So the read surface — in BOTH modes — is the repo under review, not arbitrary host files (this is why the read-only lockdown above can *enable* repo reads safely). In auto mode (`-y`) an in-repo `@path` is read and may be sent to Google's API (accepted auto-mode risk). In read-only mode the write/exec tools are excluded (above), so a `@path` read cannot be turned into a write/commit.

**Kiro network dependency** — Kiro connects to an external AWS service (`q.us-east-1.amazonaws.com`). It will fail with a network error in offline environments or if that service is unavailable. Treat Kiro as best-effort.

**Kiro `profile_name` log error** — kiro-cli logs `Failed to get auth profile: missing field profile_name` on every non-interactive call ([upstream bug](https://github.com/kirodotdev/Kiro/issues/6170)). Non-fatal. If Kiro starts actually failing, re-login with `kiro-cli login`.

**Background task noise** — Stale task-completion notifications from the workflow's parallel reviewer/verifier dispatch may surface after the workflow returns. Harmless — its results were already processed.

**Session directories** — Each run creates `.committee/session-XXXXXX/` in the project root. These are gitignored and cleaned up on completion. If a run is interrupted abnormally, orphaned session dirs may remain — safe to delete manually.
