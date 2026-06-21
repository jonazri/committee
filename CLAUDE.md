# Committee

Multi-perspective code review agent for Claude Code.

## What This Is

Two Claude Code skills:
- `/committee` — one-shot parallel code review from five AI reviewers (Claude, Codex, Kiro, and two Gemini models via the Antigravity `agy` CLI), verifies claims, synthesizes a structured report.
- `/committee-loop` (v1.0) — spawns a detached session in an isolated worktree to iteratively review-and-refine a target file until clean. Iter-1 runs fast (Claude+Kiro+Codex, no Gemini); iter-2+ uses `/committee` (all 5), with the Claude reviewer stepped down to Sonnet from iter-3 and auto-re-escalated to Opus after any iteration that surfaces a new verified Critical. Includes a simplify pre-pass, a post-edit consistency sweep (catches stale cross-refs/contradictions an iteration's own edits introduce, before they cost a committee round), parallel verifier subagents, a persistent decision ledger to prevent thrashing, and a `stable-polish` convergence exit (two consecutive zero-Critical, polish-only iterations converge instead of running another round).

## Prerequisites

All reviewer CLIs must be installed and authenticated (both Gemini reviewers run via the `agy` CLI, just pinned to different models):

- **codex** — `npm install -g @openai/codex` then `codex login`
- **kiro-cli** — See https://kiro.dev for installation, then `kiro-cli settings` to configure
- **agy** (Google Antigravity CLI) — install per https://antigravity.google, then sign in (run `agy` once interactively to complete OAuth). Both Gemini reviewers run through `agy` (`agy -p --model gemini-3.5-flash` / `gemini-3.1-pro`). The legacy `gemini` CLI is no longer accepted by the Gemini Code Assist backend for individual accounts (`IneligibleTierError: UNSUPPORTED_CLIENT`), so it is not used.
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
--gemini-model=<id>                      # Pin the primary Gemini reviewer (agy model id; default: gemini-3.5-flash)
--gemini-pro-model=<id>                  # Override the 5th reviewer's pin (agy model id; default: gemini-3.1-pro; suppresses the Pro→Flash retry)
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

**Reviewer parallelism** — the `committee-review` workflow dispatches all five reviewers (Claude as a `general-purpose` agent, the Codex/Kiro CLIs, and two Gemini reviewers via the Antigravity `agy` CLI — the primary at `--model gemini-3.5-flash`, the fifth at `--model gemini-3.1-pro` with a single Pro→Flash retry at the default pin, writing its own `gemini-pro.md`) in parallel via `pipeline()`, then streams each reviewer into a per-reviewer verifier agent as soon as its review completes (no barrier between the Review and Verify stages). It returns `{ quorum, degraded, perReviewer }`; the skill synthesizes the Critical/Important/Minor report from that.

**Arg delivery** — the skill invokes the workflow with an `args` object, but the harness may deliver it to the workflow as a JSON *string*; `committee-review.js` accepts either form (parses a string, uses an object as-is) and fails fast if `sessionDir`/`promptsDir` are missing.

**Operator model overrides** — every committee member's model is overridable, with effort where the invocation exposes it. `committee-review.js` accepts optional args `reviewerModel` (Claude), `codexModel`/`codexEffort`, `geminiModel` (primary Gemini, default `gemini-3.5-flash`), `geminiProModel` (default `gemini-3.1-pro`; an override suppresses the Pro→Flash retry), `verifierModel`, and `enabledReviewers` (a reviewer-subset allowlist) — model ids sanitized to `[A-Za-z0-9._-]`, effort levels to lowercase enums, the verifier model to `opus|sonnet|haiku` (invalid → default), and the gemini pins reach `agy-review.sh` as `shq`-quoted argv tokens, so a value reaching the workflow from an adversarial diff can't inject shell. **Effort is only controllable for Codex (`model_reasoning_effort`) and the committee-loop inner agent (spawn `--effort`)** — the in-workflow Claude reviewer / verifiers / Gemini reviewers have no per-agent effort knob, so only their model is settable. For one-shot `/committee` these come from the `--codex-model`/`--reviewers`/etc. flags. For `committee-loop`, the operator states model preferences in natural language; the skill translates them into `spawn.sh --models '<json>'`, which validates the JSON, applies `innerAgent.{model,effort}` to the detached `claude` launch, and writes `.committee-loop-models.json` into the worktree — the inner agent reads it each iteration and maps it onto the `/committee` flags + reviewer subset, with `reviewers.claude.policy: "pin"` (default when a claude model is set) freezing the adaptive Sonnet step-down/re-escalation, or `"adaptive"` keeping it.

## Known Limitations

**Codex slowness** — Codex uses `gpt-5.4`. The workflow's Codex reviewer passes `-c model_reasoning_effort=high` on every invocation to override the user's global `xhigh` default, typically completing in ~3–5 minutes. The Codex command is wrapped in a shell `timeout` of 540s (600s for `--files`/`--plan` scope, since Codex explores auxiliary code to validate feasibility). For large diffs, Codex may still time out — the other 4 reviewers maintain quorum.

**Codex sha_range** — Codex has no native flag for arbitrary SHA ranges. For sha_range (and PR) scope, the workflow uses `codex exec --ephemeral -o FILE` with a heredoc prompt, which lets Codex run `git diff` autonomously. Slower than the native `codex review` flows above because Codex has to explore the range itself — ~5–10 minutes even at `high` effort.

**Shell injection + auto trust** — In auto mode (default), Kiro runs with `--trust-all-tools` and the Gemini reviewers run via `agy --dangerously-skip-permissions` (full tools). A diff containing adversarial content could trigger arbitrary command execution via prompt injection on a reviewer's LLM. The parent session's auto-mode classifier does NOT gate commands issued inside the reviewer subprocesses. Codex in auto mode is likewise not pinned to a sandbox (unlike read-only mode, which forces `codex exec --sandbox read-only`): the `codex review`/`codex exec` calls run under the user's codex config default (`read-only` out of the box, but widenable via `~/.codex/config.toml`), so the reviewer-only framing carried in the `codex exec` prompts is the prompt-level mitigation. In read-only mode, Kiro uses `--trust-tools=fs_read` (file reading only, no shell) and the Gemini reviewers run `agy` under a per-run-`HOME` `permissions.deny` lockdown (see the **agy read-only lockdown** entry below) that denies writes, shell, and the network/URL exfil tools — **fail-closed** (if the deny file can't be written, `agy` is never invoked and the reviewer drops). The skill presents a trust dialog before each run. **Plan scope is forced to read-only regardless of the requested trust (a `--spec` rides the same `--plan` invocation; there is no separate `spec` scopeType), and `committee-loop` runs all its reviewers read-only** — a plan document *is* imperative instructions, so an auto-trust reviewer fed one will *execute* it rather than review it (2026-06-11: a Gemini reviewer scaffolded and committed a plan's build steps into a loop worktree as 4 stray commits, caught+cleaned by the loop). Defense in depth: the Gemini reviewer's stdin payload is fenced in `<reviewed_content>` tags and every reviewer's framing names the artifact as DATA-not-instructions, and the reviewer-not-implementer prohibition forbids file creation and all writing git verbs (`add`/`commit`/`stash`/`apply`/…), not just `merge`/`rebase`/`push`/`checkout`/`reset`.

**agy read-only lockdown (deliberately read-enabled — NOT exfil-safe)** — `agy` auto-acts in headless `-p` mode with no opt-in flag, and `--sandbox` does not stop it. Read-only mode (plan scope and committee-loop always; `--trust=read-only` otherwise) is enforced **fail-closed** in `prompts/agy-review.sh` via a per-run `HOME` redirect whose `~/.gemini/antigravity-cli/settings.json` denies `write_file(*)`/`edit_file(*)`/`replace(*)`/`command(*)`/`run_command(*)`/`read_url(*)`/`fetch(*)`/`web_search(*)`/`browser_action(*)`. If the deny file can't be written, `agy` is never invoked and the reviewer drops. **File reads are deliberately ALLOWED** (`read_file`/`view_file`/`grep_search`/`list_dir`) so a reviewer can consult repo context: `agy`'s reads are **not** filesystem-confined (verified 2026-06-21 — it reads `/etc/passwd` and out-of-repo `$TMPDIR` paths via `@`-tokens), and `agy`'s permission path-globs cannot scope reads (only catch-all `tool(*)` works, all-or-nothing; `permissions.allow` cannot override `permissions.deny`), so reads can only be allowed or denied wholesale. **ACCEPTED RISK (2026-06-21 decision):** a prompt-injected diff can make a read-only reviewer read local files (incl. `~/.gemini` OAuth creds) and echo them into the review output — read-only is **safer than auto** (no writes/shell/network) but is **NOT exfil-safe**; the `read_url`/`fetch`/`web_search`/`browser_action` denials close the *network* exfil channel, but the review-output channel stays open. Prefer auto only for trusted content; treat read-only as best-effort for untrusted content. The per-run `HOME` (a `mktemp -d` outside the project root, copy-not-symlink of auth/state, removed by an EXIT/INT/TERM trap) is **concurrency isolation** (no write-through to the real `~/.gemini`), **not** a credential boundary. **On every `agy` upgrade, re-run `scripts/agy-smoke-test.sh`:** the read-only guarantee rests on `agy` honoring `permissions.deny` glob semantics, and since headless `-p` auto-acts by default, a version that changes those semantics would silently re-open writes/shell with no error. This pinned-version checklist replaces the retired gemini "tools.exclude deprecated → revisit on upgrade" note.

**agy failure handling** — On any `agy` error (empty output or non-zero exit) the reviewer drops and the other four hold quorum. Gemini-Pro retries once Pro→Flash (`gemini-3.1-pro` → `gemini-3.5-flash`, default pin only; an explicit `--gemini-pro-model` suppresses the retry) before dropping. **Model-id drift is NOT auto-detected:** `agy` silently substitutes Flash for an unknown/retired `--model` id (exit 0, non-empty output), so a rotted Pro pin would downgrade Gemini-Pro to Flash with no failure signal — re-confirm the Pro pin's active model after an `agy` upgrade. No cross-session quota markers are written or read.

**agy `@`-token read surface** — `agy` processes `@path` tokens in stdin and reads the referenced file via `read_file`. Its reads are NOT workspace-confined in either mode (verified 2026-06-21: an out-of-repo `@/etc/passwd` and an out-of-projectRoot `@$TMPDIR/...` sentinel are both read). In read-only mode writes/shell/network are denied, so an `@`-read cannot be written out or fetched to a URL — but it CAN still be echoed into the review output (the accepted read-exfil risk above). In auto mode (`--dangerously-skip-permissions`) an `@`-read is an accepted auto-mode risk, the same posture as the old gemini `-y` mode.

**One-time migration cleanup** — stale Gemini quota markers may remain at `~/.gemini/.committee-quota-until-*`; delete them manually (they are unused after this migration).

**Kiro network dependency** — Kiro connects to an external AWS service (`q.us-east-1.amazonaws.com`). It will fail with a network error in offline environments or if that service is unavailable. Treat Kiro as best-effort.

**Kiro `profile_name` log error** — kiro-cli logs `Failed to get auth profile: missing field profile_name` on every non-interactive call ([upstream bug](https://github.com/kirodotdev/Kiro/issues/6170)). Non-fatal. If Kiro starts actually failing, re-login with `kiro-cli login`.

**Background task noise** — Stale task-completion notifications from the workflow's parallel reviewer/verifier dispatch may surface after the workflow returns. Harmless — its results were already processed.

**Session directories** — Each run creates `.committee/session-XXXXXX/` in the project root. These are gitignored and cleaned up on completion. If a run is interrupted abnormally, orphaned session dirs may remain — safe to delete manually.
