#!/usr/bin/env bash
# Committee-loop spawner. Invoked by the SKILL.md outer agent with target
# file paths as positional args; does preflight + worktree + seed + generates
# post.sh/watcher/instructions from adjacent body files + spawns detached tmux.
# Emits a manifest on stdout so the outer agent can launch the watcher in a
# separate Bash call.
set -euo pipefail

# Self-location so post-body.sh, watcher-body.sh, inner-agent.md resolve
# regardless of the invoker's cwd.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Cleanup guard: if anything between here and the tmux spawn fails, unwind the
# worktree+branch so we don't leak them. Cleared on successful spawn near the
# end of this script. INT/TERM/HUP/QUIT included so Ctrl-C, terminal hangup,
# or kill between worktree creation and tmux spawn also unwinds.
cleanup_on_error() {
  local rc="${1:-$?}"
  [ -n "${SESSION:-}" ] && tmux kill-session -t "$SESSION" 2>/dev/null || true
  [ -n "${WORKTREE_PATH:-}" ] && git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  [ -n "${BRANCH:-}" ] && git branch -D "$BRANCH" 2>/dev/null || true
  exit "$rc"
}
trap 'cleanup_on_error $?' ERR
# Signal traps pass 130 explicitly — without it, a SIGINT before any command
# has failed leaves $? at 0 and we'd exit 0, indistinguishable from success.
trap 'cleanup_on_error 130' INT TERM HUP QUIT

# ---- Inner-launch command builder (Headroom integration) ----
# Build the command tmux runs for the detached inner Claude session. When the
# `cclaude` is installed (and not opted out via COMMITTEE_HEADROOM=off, any
# case), use it so the inner coordinator is both Headroom-routed and cus-managed.
# Without cclaude, keep the prior `headroom wrap claude` / bare-claude fallback.
# For the direct Headroom fallback, do not pass `--no-serena`: that flag mutates
# the user's global Claude config. `--` delimits wrap options from Claude args.
# Pure: output depends only on $1 + PATH + COMMITTEE_HEADROOM, no side effects,
# so the --print-inner-launch self-test hook can exercise it.
build_inner_launch() {
  local claude_args="$1" optout=no
  case "${COMMITTEE_HEADROOM:-auto}" in [Oo][Ff][Ff]) optout=yes ;; esac
  if [ "$optout" = no ] && command -v cclaude >/dev/null 2>&1; then
    printf '%s' "cclaude $claude_args"
  elif [ "$optout" = no ] && command -v headroom >/dev/null 2>&1; then
    printf '%s' "headroom wrap claude -- $claude_args"
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

# ---- Preflight: args, targets, tools, skills, git identity ----

[ "$#" -gt 0 ] || {
  echo "usage: $(basename -- "$0") [--models '<json>'] <target-file> [<target-file> ...]" >&2
  echo "       paths must be repo-relative (resolved against origin's repo root)" >&2
  exit 1
}

ORIGIN_PATH=$(git rev-parse --show-toplevel)
# Positive allowlist for the origin repo path: only [a-zA-Z0-9._/-]. Anything
# else (parens, brackets, braces, commas, `*`, `?`, `#`, `!`, whitespace,
# shell metacharacters) would survive a naive deny-list but its %q escape
# breaks SKILL.md's documented `bash "<WATCHER_SCRIPT>"` wrapper — e.g.
# `printf '%q' '/foo(bar)'` → `/foo\(bar\)`, and backslash-paren inside
# double quotes is literal. Allowlist keeps the generated manifest values
# safe inside double quotes.
case "$ORIGIN_PATH" in
  *[!a-zA-Z0-9._/-]*)
    echo "origin repo path contains disallowed character: $ORIGIN_PATH" >&2
    echo "committee-loop requires the repo path to match [a-zA-Z0-9._/-] only — rename or move the repo." >&2
    exit 1 ;;
esac
# Optional operator model-override config: `--models '<json>'` (or `--models=<json>`) anywhere
# among the positional target paths. Everything else stays a target path. Validated NOW (before
# any worktree cost) and the inner-agent launch flags (`innerAgent.model`/`effort`) are derived
# here; the JSON itself is written into the worktree as `.committee-loop-models.json` after the
# worktree exists, for the inner agent to read each iteration.
MODELS_JSON=""
INNER_LAUNCH_EXTRA="--effort high"   # default; --effort high is the loop-agent sweet spot
declare -a POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --models) MODELS_JSON="${2-}"; shift 2 || { echo "--models requires a JSON argument" >&2; exit 1; } ;;
    --models=*) MODELS_JSON="${1#--models=}"; shift ;;
    --) shift; while [ "$#" -gt 0 ]; do POSITIONAL+=( "$1" ); shift; done ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) POSITIONAL+=( "$1" ); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"
[ "$#" -gt 0 ] || {
  echo "usage: $(basename -- "$0") [--models '<json>'] <target-file> [<target-file> ...]" >&2
  echo "       no target file paths given (after option parsing)" >&2
  exit 1
}

if [ -n "$MODELS_JSON" ]; then
  # node is a hard transitive dep (the codex CLI is a node package; agy and kiro-cli are
  # standalone binaries, and the gemini/gemini-pro model keys map onto the agy-backed
  # reviewers — no gemini binary is invoked), but only required when
  # --models is used; validate the JSON + derive the inner-agent launch flags here so a bad
  # config fails before the worktree is created. Model/effort tokens that reach the tmux `claude`
  # command MUST be charset-safe (committee-review.js separately sanitizes the reviewer tokens).
  command -v node >/dev/null 2>&1 || { echo "--models requires 'node' on PATH to validate the JSON" >&2; exit 1; }
  INNER_LAUNCH_EXTRA=$(MODELS_JSON="$MODELS_JSON" node -e '
    const TOK=/^[A-Za-z0-9._-]+$/;
    let cfg; try { cfg = JSON.parse(process.env.MODELS_JSON) } catch (e) { console.error("--models is not valid JSON: " + e.message); process.exit(1) }
    if (typeof cfg !== "object" || cfg === null || Array.isArray(cfg)) { console.error("--models must be a JSON object"); process.exit(1) }
    const chk = (v, n) => { if (v != null && !(typeof v === "string" && TOK.test(v))) { console.error("invalid " + n + ": " + JSON.stringify(v) + " (allowed chars: A-Z a-z 0-9 . _ -)"); process.exit(1) } };
    // Effort levels are lowercase enums (minimal/low/medium/high/xhigh). The committee-review
    // workflow sanitizes efforts with the SAME lowercase charset, so enforcing it here makes a
    // bad value fail fast at spawn instead of silently degrading to the default mid-run.
    const EFF = /^[a-z]+$/;
    const chkEff = (v, n) => { if (v != null && !(typeof v === "string" && EFF.test(v))) { console.error("invalid " + n + ": " + JSON.stringify(v) + " (effort levels are lowercase, e.g. high, xhigh)"); process.exit(1) } };
    const ia = cfg.innerAgent || {}; chk(ia.model, "innerAgent.model"); chkEff(ia.effort, "innerAgent.effort");
    const rv = cfg.reviewers || {};
    if (typeof rv !== "object" || Array.isArray(rv)) { console.error("reviewers must be a JSON object"); process.exit(1) }
    const known = ["claude","codex","kiro","gemini","gemini-pro"];
    for (const [k, s0] of Object.entries(rv)) {
      if (!known.includes(k.toLowerCase())) { console.error("unknown reviewer key: " + k + " (expected one of " + known.join(", ") + ")"); process.exit(1) }
      // NOTE: reviewers.claude.model is validated here but reaches the workflow INDIRECTLY —
      // the inner agent translates it into /committee --reviewer-model=<v> (-> reviewerModel),
      // unlike the codex/gemini/gemini-pro model keys (the gemini keys drive the agy-backed
      // reviewers, not a gemini binary), which map 1:1 onto workflow args. See inner-agent.md
      // <operator_model_overrides>.
      const s = s0 || {}; chk(s.model, "reviewers." + k + ".model"); chkEff(s.effort, "reviewers." + k + ".effort");
      if (s.enabled != null && typeof s.enabled !== "boolean") { console.error("reviewers." + k + ".enabled must be true/false"); process.exit(1) }
      if (s.policy != null && !["pin","adaptive"].includes(s.policy)) { console.error("reviewers." + k + ".policy must be \"pin\" or \"adaptive\""); process.exit(1) }
    }
    const ver = cfg.verifier || {}; chk(ver.model, "verifier.model");
    const eff = ia.effort || "high", mdl = ia.model || "";
    process.stdout.write("--effort " + eff + (mdl ? " --model " + mdl : ""));
  ') || exit 1
fi

TARGET_FILES=( "$@" )

for i in "${!TARGET_FILES[@]}"; do
  f="${TARGET_FILES[$i]}"
  case "$f" in
    /*)
      # Downstream builds "$ORIGIN_PATH/$f"; an absolute $f produces a
      # broken path like "/origin//abs/file". Reject repo-absolute paths here.
      echo "target must be repo-relative, not absolute: $f" >&2; exit 1 ;;
  esac
  case "$f" in
    *[!a-zA-Z0-9._/-]*)
      # Positive allowlist: only [a-zA-Z0-9._/-]. Other characters (parens,
      # brackets, braces, commas, *, ?, #, !, whitespace, shell metachars)
      # would survive a deny-list but their %q escaping breaks the
      # `bash "<WATCHER_SCRIPT>"` pattern documented in SKILL.md and the
      # unquoted $ARGUMENTS substitution in ralph-loop's slash-command
      # template. Matches the ORIGIN_PATH allowlist above.
      echo "target contains disallowed character (allowed: [a-zA-Z0-9._/-]): $f" >&2; exit 1 ;;
  esac
  # Under --dangerously-skip-permissions an un-validated path is an arbitrary-
  # file-write primitive.
  [ -L "$ORIGIN_PATH/$f" ] && { echo "target is a symlink (not supported): $f" >&2; exit 1; }
  ABS=$(cd "$ORIGIN_PATH" && realpath -e -- "$f" 2>/dev/null) \
    || { echo "target does not exist: $f" >&2; exit 1; }
  case "$ABS" in
    "$ORIGIN_PATH"/*) ;;
    *) echo "target resolves outside origin: $f -> $ABS" >&2; exit 1 ;;
  esac
  # Canonicalize to the repo-relative form git will see in its index.
  # Non-canonical user input like `./foo.sh` or `sub/../foo.sh` would otherwise
  # survive through post-body.sh's WRITTEN array and mismatch the index names
  # returned by `git diff --cached --name-only` (git normalizes paths) —
  # producing a spurious "unexpected paths" BLOCKED.
  TARGET_FILES[$i]="${ABS#$ORIGIN_PATH/}"
done

for t in tmux claude git realpath sha256sum kiro-cli codex agy timeout; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

# GNU realpath -e; BSD realpath (default macOS) does not support it. Behavior
# probe (not help-text parse) so wording changes can't break it.
realpath -e -- . >/dev/null 2>&1 \
  || { echo "realpath does not support -e (BSD realpath?); install GNU coreutils (macOS: brew install coreutils)" >&2; exit 1; }

# --effort is referenced in the tmux spawn below; fail fast before worktree cost.
claude --help 2>/dev/null | grep -q -- --effort \
  || { echo "claude CLI missing --effort flag; upgrade claude or remove --effort from spawn.sh" >&2; exit 1; }

# --path-format=absolute (git 2.31+) is used by post-body.sh. Probe by invoking
# the flag itself — avoids help-text parse and `git --help` pager behavior.
git rev-parse --path-format=absolute --git-dir >/dev/null 2>&1 \
  || { echo "git too old (need 2.31+ for rev-parse --path-format); upgrade git" >&2; exit 1; }

# Depends on installed skills/plugins. Only check ones that reliably show up
# as directories under ~/.claude or $ORIGIN_PATH/.claude: ralph-loop, committee,
# superpowers:receiving-code-review. `simplify` is NOT checked — it is
# harness-registered. The Claude reviewer is dispatched as the built-in
# `general-purpose` agent (not a plugin `code-reviewer` agent type, which
# superpowers no longer ships), so there is no extra agent to preflight here.
# Any remaining missing-at-runtime dependency surfaces as an Agent/Skill error
# from the inner agent.
check_skill_or_plugin() {
  local label="$1"; shift
  local -a patterns=( "$@" )
  local roots=( "$HOME/.claude" "$ORIGIN_PATH/.claude" )
  local root pat
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    for pat in "${patterns[@]}"; do
      find "$root" -type d \( -name "$pat" -o -path "*/$pat" -o -path "*/$pat/*" \) 2>/dev/null | grep -q . && return 0
    done
  done
  echo "$label not found under ~/.claude or $ORIGIN_PATH/.claude; install it before running committee-loop" >&2
  exit 1
}
check_skill_or_plugin "ralph-loop plugin"                       "ralph-loop"
check_skill_or_plugin "committee skill"                         "committee"
check_skill_or_plugin "superpowers:receiving-code-review skill" "receiving-code-review"

# Seed commit + copy-back commit both require a git identity.
git config user.name >/dev/null && git config user.email >/dev/null \
  || { echo "git user.name/user.email not configured; committee-loop needs both for worktree + copy-back commits" >&2; exit 1; }

# Body files must exist before we try to cat them into the generated scripts.
for required in inner-agent.md post-body.sh watcher-body.sh health-check-body.sh; do
  [ -f "$SCRIPT_DIR/$required" ] \
    || { echo "committee-loop skill corrupt: $SCRIPT_DIR/$required missing" >&2; exit 1; }
done

# ---- Dedicated tmux socket (isolation + crash avoidance) ----
# All committee-loop tmux traffic runs on its OWN tmux server (-L), never the
# user's default server. Two reasons:
#   1. Sizing: on the shared default server, a detached session's window is
#      recalculated to match other attached clients and renders too narrow for
#      Claude's TUI. On a private socket with no other clients, the -x/-y passed
#      to new-session is honored as-is.
#   2. Safety: tmux 3.4 segfaults in clients_calculate_size if window-size is
#      ever set to `manual` (the tempting "fix" for #1) — killing EVERY session
#      on that server. Isolation removes any need to touch window-size, and means
#      a committee crash can never take down the user's interactive sessions.
# The wrapper keeps every `tmux ...` call below on this socket without per-call
# edits. The generated watcher/post/health-check scripts get the same wrapper via
# their headers; the detached watchdog (separate process) sets it inline.
COMMITTEE_SOCKET="committee-loop"
tmux() { command tmux -L "$COMMITTEE_SOCKET" "$@"; }

# ---- Create the worktree ----

PROJECT=$(basename -- "$ORIGIN_PATH")
SLUG=$(basename -- "${TARGET_FILES[0]}" | sed 's/\.[^.]*$//' | tr -c 'a-zA-Z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
SLUG="${SLUG:-review}"
SLUG="${SLUG:0:40}"
TS="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
# `dirname` (not "$ORIGIN_PATH/..") keeps WORKTREE_PATH canonical — post-body.sh's
# containment check compares it against `realpath -e` output which is canonical.
WORKTREE_PATH="$(dirname -- "$ORIGIN_PATH")/${PROJECT}-committee-loop-${SLUG}-${TS}"
BRANCH="committee-loop/${SLUG}-${TS}"
SESSION="committee-loop-${SLUG}-${TS}"

git worktree add "$WORKTREE_PATH" -b "$BRANCH"

# ---- Seed the worktree ----

# Copy into the worktree first, then hash the worktree bytes. Those are the
# exact bytes handed to the review, so at copy-back time the baseline represents
# what was reviewed. `git status` cannot substitute because we intentionally
# copy uncommitted origin edits in; origin stays "dirty" for the whole review.
declare -a SEED_HASHES=()
for f in "${TARGET_FILES[@]}"; do
  mkdir -p "$WORKTREE_PATH/$(dirname -- "$f")"
  cp -P "$ORIGIN_PATH/$f" "$WORKTREE_PATH/$f"
  HASH=$(sha256sum "$WORKTREE_PATH/$f" | awk '{print $1}')
  [ -n "$HASH" ] || { echo "sha256sum produced empty hash for $f" >&2; cleanup_on_error 1; }
  SEED_HASHES+=( "$HASH" )
done
(
  cd "$WORKTREE_PATH" || exit 1
  git add -A
  git diff --cached --quiet || git commit -m "seed: pull latest uncommitted target from origin"
)

# ---- Build the inner-agent instructions file ----

TARGET_JOINED=$(printf '%s, ' "${TARGET_FILES[@]}")
TARGET_JOINED="${TARGET_JOINED%, }"

INSTRUCTIONS="$WORKTREE_PATH/.committee-loop-instructions.md"
{
  printf '# Committee-Loop — Target file(s)\n\n'
  printf 'Target file(s): %s\n\n' "$TARGET_JOINED"
  printf -- '---\n\n'
  cat "$SCRIPT_DIR/inner-agent.md"
} > "$INSTRUCTIONS"

# Operator model-override config (validated during arg-parse). The inner agent reads this each
# iteration and maps it onto the /committee flags + reviewer subset + policy-pin. The inner-agent
# launch model/effort were already derived from it into INNER_LAUNCH_EXTRA.
if [ -n "$MODELS_JSON" ]; then
  printf '%s\n' "$MODELS_JSON" > "$WORKTREE_PATH/.committee-loop-models.json"
fi

RALPH_PROMPT="Read .committee-loop-instructions.md and follow it exactly. Review the target files named in that file using the phase-based workflow described, then iterate per the instructions until you emit the REVIEW CLEAN promise."
# ralph-loop's slash-command template substitutes $ARGUMENTS UNQUOTED. No
# backticks, no parens, no $, no quotes in RALPH_PROMPT.
RALPH_INVOCATION="/ralph-loop:ralph-loop \"$RALPH_PROMPT\" --completion-promise \"REVIEW CLEAN\" --max-iterations 10"

# ---- Build post.sh (header + post-body.sh) ----

POST_SCRIPT="$WORKTREE_PATH/.committee-loop-post.sh"

ORIGIN_REF=$(git -C "$ORIGIN_PATH" rev-parse --abbrev-ref HEAD)
# HEAD detached at spawn ("HEAD") is rejected rather than silently accepted:
# without a branch name, copy-back would commit to detached HEAD and the commit
# would be invisible from any branch.
[ "$ORIGIN_REF" != "HEAD" ] \
  || { echo "origin is on detached HEAD; committee-loop requires a named branch so copy-back lands where the user expects" >&2; cleanup_on_error 1; }

{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'ORIGIN_PATH=%q\n' "$ORIGIN_PATH"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'BRANCH=%q\n' "$BRANCH"
  printf 'SESSION=%q\n' "$SESSION"
  printf 'COMMITTEE_SOCKET=%q\n' "$COMMITTEE_SOCKET"
  printf 'tmux() { command tmux -L "$COMMITTEE_SOCKET" "$@"; }\n'
  printf 'ORIGIN_REF=%q\n' "$ORIGIN_REF"
  printf 'TARGET_FILES=('
  printf ' %q' "${TARGET_FILES[@]}"
  printf ' )\n'
  printf 'SEED_HASHES=('
  printf ' %q' "${SEED_HASHES[@]}"
  printf ' )\n'
} > "$POST_SCRIPT"
cat "$SCRIPT_DIR/post-body.sh" >> "$POST_SCRIPT"
chmod +x "$POST_SCRIPT"

# ---- Build watcher.sh (header + watcher-body.sh) ----

WATCHER_SCRIPT="$WORKTREE_PATH/.committee-loop-watcher.sh"
ORIGIN_GIT_DIR=$(git -C "$ORIGIN_PATH" rev-parse --path-format=absolute --git-common-dir)
ART_DIR="$ORIGIN_GIT_DIR/committee-loop/$SESSION"

{
  printf '#!/usr/bin/env bash\nset -u\n'
  printf 'SESSION=%q\n' "$SESSION"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'ART_DIR=%q\n' "$ART_DIR"
  printf 'COMMITTEE_SOCKET=%q\n' "$COMMITTEE_SOCKET"
  printf 'tmux() { command tmux -L "$COMMITTEE_SOCKET" "$@"; }\n'
} > "$WATCHER_SCRIPT"
cat "$SCRIPT_DIR/watcher-body.sh" >> "$WATCHER_SCRIPT"
chmod +x "$WATCHER_SCRIPT"

# ---- Build health-check.sh (header + health-check-body.sh) ----

# One-shot 4.5m mid-run health ping. Lets the invoking session report "still
# running healthy" (or early-death/early-finish) instead of fire-and-forget.
# Terminal outcomes are still the watcher's job.
HEALTH_CHECK_SCRIPT="$WORKTREE_PATH/.committee-loop-health-check.sh"

{
  printf '#!/usr/bin/env bash\nset -u\n'
  printf 'SESSION=%q\n' "$SESSION"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'ART_DIR=%q\n' "$ART_DIR"
  printf 'COMMITTEE_SOCKET=%q\n' "$COMMITTEE_SOCKET"
  printf 'tmux() { command tmux -L "$COMMITTEE_SOCKET" "$@"; }\n'
} > "$HEALTH_CHECK_SCRIPT"
cat "$SCRIPT_DIR/health-check-body.sh" >> "$HEALTH_CHECK_SCRIPT"
chmod +x "$HEALTH_CHECK_SCRIPT"

# ---- Build the wrapper prompt the tmux session receives ----

PROMPT_FILE="$WORKTREE_PATH/.committee-loop-prompt.txt"
cat > "$PROMPT_FILE" <<EOF
You are in an isolated worktree at $WORKTREE_PATH. The origin checkout is at $ORIGIN_PATH.

Run the ralph-loop below. The inner loop instructions (in \`.committee-loop-instructions.md\`) handle copy-back and teardown via \`bash .committee-loop-post.sh\` — do not run post.sh yourself.

If ralph-loop exhausts its iteration limit without emitting a promise, write \`.committee-loop-EXHAUSTED.txt\` in this worktree summarizing the last iteration's outstanding findings so the user has a signal other than a stale tmux session.

The ralph-loop instructions embed review-feedback discipline (receiving-code-review, verify claims, decision ledger, quorum + severity gates, convergence exit). Follow them literally — skipping the verification or ledger steps is the failure mode this skill exists to prevent.

Now run the review loop:
EOF
printf '\n%s\n' "$RALPH_INVOCATION" >> "$PROMPT_FILE"

# ---- Spawn the detached tmux session ----

# -x/-y set the detached session's window size. Because all committee tmux
# traffic runs on a private socket (COMMITTEE_SOCKET above) with no other clients
# attached, these dimensions are honored as-is — no `window-size manual` needed
# (that option crashes tmux 3.4 in clients_calculate_size and kills the server).
# --effort high balances loop-agent discipline (ledger + verification steps)
# against total wall-time. `max` rarely pays off for single-file reviews.
# INNER_LAUNCH_EXTRA defaults to "--effort high" and is overridden by --models
# innerAgent.{effort,model} (validated charset-safe during arg-parse).
# build_inner_launch (top of file) routes this through cclaude/Headroom when available.
INNER_LAUNCH=$(build_inner_launch "--dangerously-skip-permissions $INNER_LAUNCH_EXTRA")
case "$INNER_LAUNCH" in "cclaude "*|"headroom wrap "*) INNER_WRAPPED=1 ;; *) INNER_WRAPPED=0 ;; esac
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKTREE_PATH" \
  "$INNER_LAUNCH"

READY=false
TRUST_DISMISSED=false
for _ in $(seq 1 45); do   # wider: `headroom wrap` adds proxy-handshake latency before the TUI
  PANE=$(tmux capture-pane -t "$SESSION" -p)
  if echo "$PANE" | grep -qF 'bypass permissions on'; then
    READY=true; break
  fi
  # Claude Code shows a folder-trust prompt for unknown directories BEFORE
  # entering the main TUI — even under --dangerously-skip-permissions. The
  # cursor (❯) is pre-positioned on "Yes, I trust this folder" so a bare Enter
  # confirms. Auto-answer once, then keep polling for the main TUI footer.
  if ! $TRUST_DISMISSED && echo "$PANE" | grep -qF 'Yes, I trust this folder'; then
    tmux send-keys -t "$SESSION" Enter
    TRUST_DISMISSED=true
  fi
  sleep 1
done
if ! $READY; then
  echo "error: Claude input box did not render within 45s; aborting" >&2
  if [ "${INNER_WRAPPED:-0}" = 1 ]; then
    echo "hint: the inner session was launched through Headroom. If Headroom is the cause (proxy unreachable, or wrapper failing to start), re-run with COMMITTEE_HEADROOM=off to bypass it." >&2
  fi
  # Dump captured pane so a TUI footer-wording change (or unexpected prompt)
  # is diagnosable without attaching to a killed tmux session.
  echo "--- captured pane contents (for diagnosis) ---" >&2
  tmux capture-pane -t "$SESSION" -p >&2 || true
  echo "--- end pane contents ---" >&2
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  git worktree remove --force "$WORKTREE_PATH" || true
  git branch -D "$BRANCH" || true
  exit 1
fi

# Clear ONLY the ERR trap before the paste window — any ERR from tmux
# capture-pane/grep/send-keys would otherwise trip the trap and tear down the
# session we just confirmed alive. Paste failures are recoverable by attaching.
# Keep INT/TERM/HUP/QUIT live so a signal during paste/manifest emission still
# tears down the session+worktree+branch (otherwise Ctrl-C mid-paste leaks them).
trap - ERR

# Bracketed paste (-p) so multi-line content is delivered atomically. Without
# it tmux converts LF to CR, which in a TUI submits line-by-line and fragments
# the prompt.
tmux load-buffer -b "$SESSION" "$PROMPT_FILE"
tmux paste-buffer -p -t "$SESSION" -b "$SESSION"
tmux delete-buffer -b "$SESSION"

# Claude Code's TUI stages a bracketed paste as `[Pasted text #N +M lines]` and
# does not submit on the same keystroke that ends the paste. Poll until the
# staged indicator appears, then send Enter, and re-send if still visible.
for _ in $(seq 1 10); do
  tmux capture-pane -t "$SESSION" -p | grep -qE '\[Pasted text' && break
  sleep 1
done
for _ in $(seq 1 5); do
  tmux send-keys -t "$SESSION" Enter
  sleep 2
  tmux capture-pane -t "$SESSION" -p | grep -qE '\[Pasted text' || break
done

# Protected-paths watchdog. Claude Code prompts on `.claude/` edits even under
# --dangerously-skip-permissions (claude-code#35718). Detached agent can't
# answer interactively — poll from outside and pick option 2 (session-scoped).
# Observed prompt wording (claude-code 1.x): sentinel "Yes, and allow Claude to
# edit its own settings" identifies this specific prompt; option 2 is the
# "session-only allow" variant. If Claude Code reorders the menu in a future
# release, "2" will select whatever is at that slot — check the sentinel + this
# assumption together when upgrading claude-code.
# 12h cap guards against a leaked watchdog; exits when tmux session dies.
nohup bash -c '
  SOCK="$2"; tmux() { command tmux -L "$SOCK" "$@"; }
  end=$(( $(date +%s) + 43200 ))
  while [ "$(date +%s)" -lt "$end" ] && tmux has-session -t "$1" 2>/dev/null; do
    if tmux capture-pane -t "$1" -p 2>/dev/null | grep -qF "Yes, and allow Claude to edit its own settings"; then
      tmux send-keys -t "$1" "2"; sleep 0.3; tmux send-keys -t "$1" Enter
      # Do NOT break here: the permission prompt may re-fire across ralph-loop
      # iterations (each iteration runs its own inner-agent turn, and session-
      # scope persistence is a runtime assumption). Debounce 5s so we do not
      # answer the same prompt twice before the TUI redraws.
      sleep 5
    fi
    sleep 3
  done
' _ "$SESSION" "$COMMITTEE_SOCKET" >/dev/null 2>&1 &
disown

# ---- Emit manifest on stdout + copy to worktree for later recovery ----

# %q-escape each value so the manifest is safely sourceable when paths contain
# spaces or shell metacharacters (matches the post.sh header pattern).
MANIFEST="$WORKTREE_PATH/.committee-loop-manifest.txt"
{
  printf 'SESSION=%q\n' "$SESSION"
  printf 'WORKTREE_PATH=%q\n' "$WORKTREE_PATH"
  printf 'BRANCH=%q\n' "$BRANCH"
  printf 'ORIGIN_PATH=%q\n' "$ORIGIN_PATH"
  printf 'ORIGIN_REF=%q\n' "$ORIGIN_REF"
  printf 'ORIGIN_GIT_DIR=%q\n' "$ORIGIN_GIT_DIR"
  printf 'WATCHER_SCRIPT=%q\n' "$WATCHER_SCRIPT"
  printf 'HEALTH_CHECK_SCRIPT=%q\n' "$HEALTH_CHECK_SCRIPT"
  printf 'TARGET_FILES_JOINED=%q\n' "$TARGET_JOINED"
} > "$MANIFEST"
# Print to stdout separately (non-pipeline) so a `tee` failure under pipefail
# can't orphan the live tmux session + watchdog launched above.
cat "$MANIFEST"
