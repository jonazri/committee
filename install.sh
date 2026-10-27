#!/usr/bin/env bash
set -euo pipefail

# Install committee + committee-loop into a Claude Code config dir via symlinks so
# /committee and /committee-loop are available in every Claude Code session.
#
# Run from the repo root after cloning:
#   git clone https://github.com/jonazri/committee.git && cd committee && ./install.sh [CONFIG_DIR ...]
#
# Claude Code reads user skills and named workflows from the active config dir
# (${CLAUDE_CONFIG_DIR:-~/.claude}), so install into every config dir you run sessions under.
# Targets: each existing CONFIG_DIR argument, else ${CLAUDE_CONFIG_DIR:-~/.claude}.
# Re-running is safe — symlinks are overwritten in place (ln -sfn).
# Uninstall (per config dir): rm -rf <dir>/skills/committee <dir>/skills/committee-loop <dir>/workflows/committee-review.js
#   (and remove the committee-loop spawn.sh rule from permissions.allow in <dir>/settings.json)
#
# Options:
#   --no-permission-rule   don't add the committee-loop spawn allow rule to <config dir>/settings.json

ADD_PERMISSION_RULE=1
CONFIG_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-permission-rule) ADD_PERMISSION_RULE=0 ;;
    -*) echo "install.sh: unknown option: $arg" >&2; exit 1 ;;
    *) CONFIG_ARGS+=( "$arg" ) ;;
  esac
done
set -- ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -gt 0 ]; then
  for d in "$@"; do
    [ -d "$d" ] || { echo "install.sh: config dir not found: $d" >&2; exit 1; }
  done
  CONFIG_DIRS=( "$@" )
else
  CONFIG_DIRS=( "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" )
fi

# Refuse to run from a LINKED git worktree. install.sh repoints the global ~/.claude symlinks
# at $REPO_ROOT; if a committee/committee-loop reviewer ever runs it from an ephemeral worktree
# (e.g. while reviewing a plan that says "Run: ./install.sh"), those symlinks would point into a
# directory that later gets torn down — silently breaking the global /committee + /committee-loop
# install. In the primary checkout the git-dir equals the common-dir; in a linked worktree they
# differ. Non-git installs skip this guard (both vars come back empty).
_gd=$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)
_gcd=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$_gd" ] && [ -n "$_gcd" ]; then
  # Normalize BOTH through cd+pwd -P. On Git-for-Windows, --absolute-git-dir returns a
  # Windows-style path (C:/Users/...) while the common-dir resolves to an MSYS path
  # (/c/Users/...); comparing the raw strings would false-positive on the primary checkout.
  # Symmetric fail-open: if either path can't be resolved, skip the guard rather than
  # comparing a raw path against a normalized one (which could false-positive).
  _gd=$(cd -- "$_gd" 2>/dev/null && pwd -P || true)
  _gcd=$(cd -- "$REPO_ROOT" 2>/dev/null && cd -- "$_gcd" 2>/dev/null && pwd -P || true)
  if [ -n "$_gd" ] && [ -n "$_gcd" ] && [ "$_gd" != "$_gcd" ]; then
    echo "install.sh: refusing to run from a linked git worktree:" >&2
    echo "  $REPO_ROOT" >&2
    echo "  Installing from a worktree repoints your global ~/.claude symlinks at a directory" >&2
    echo "  that may later be removed. Run install.sh from your primary committee clone instead." >&2
    exit 1
  fi
fi

for f in \
  "$REPO_ROOT/.claude/skills/committee/SKILL.md" \
  "$REPO_ROOT/.claude/skills/committee-loop/SKILL.md" \
  "$REPO_ROOT/prompts/committee-review.js"; do
  [ -f "$f" ] || { echo "install.sh must run from the committee repo root (missing $f)" >&2; exit 1; }
done

# ln -sfn creates a symlink INSIDE a target that is a pre-existing real directory
# (migration case from the old `cp -r prompts` install). Replace such a target first.
safe_symlink() {
  local src="$1" target="$2"
  if [ -d "$target" ] && [ ! -L "$target" ]; then
    rm -rf -- "$target"
  fi
  ln -sfn "$src" "$target"
}

for CONFIG_DIR in "${CONFIG_DIRS[@]}"; do
  SKILLS_DIR="$CONFIG_DIR/skills"
  mkdir -p "$SKILLS_DIR/committee" "$SKILLS_DIR/committee-loop" "$CONFIG_DIR/workflows"

  # /committee — skill discovery needs a real dir; SKILL.md can be a symlink
  # (SKILL.md's lookup uses readlink -f to find the real skill dir containing
  # prepare.sh). The reviewer/verifier templates + committee-review workflow load from
  # prompts/ at <config dir>/skills/committee/prompts/ for user-global installs.
  safe_symlink "$REPO_ROOT/.claude/skills/committee/SKILL.md" "$SKILLS_DIR/committee/SKILL.md"
  safe_symlink "$REPO_ROOT/prompts" "$SKILLS_DIR/committee/prompts"

  # Named user-scope workflow so the skill can invoke Workflow({name:"committee-review"}).
  # Rides the same source-of-truth as prompts/ — edits to the workflow are live.
  safe_symlink "$REPO_ROOT/prompts/committee-review.js" "$CONFIG_DIR/workflows/committee-review.js"

  # /committee-loop — same pattern; spawn.sh is resolved via readlink -f on SKILL.md
  safe_symlink "$REPO_ROOT/.claude/skills/committee-loop/SKILL.md" "$SKILLS_DIR/committee-loop/SKILL.md"

  # Allow rule for the committee-loop spawn. spawn.sh launches a detached
  # `claude --dangerously-skip-permissions` session, which Claude Code's auto-mode
  # classifier blocks unless the exact command is allow-listed. SKILL.md invokes
  # `bash <real skill dir>/spawn.sh ...` with the literal readlink -f path, so the rule
  # uses the physical (pwd -P) path. A rule for another clone is replaced once that
  # clone's spawn.sh no longer exists.
  if [ "$ADD_PERMISSION_RULE" = 1 ]; then
    SETTINGS="$CONFIG_DIR/settings.json"
    RULE_ROOT=$(cd -- "$REPO_ROOT" && pwd -P)
    SPAWN_RULE="Bash(bash $RULE_ROOT/.claude/skills/committee-loop/spawn.sh:*)"
    case "$RULE_ROOT" in
      *[!A-Za-z0-9._/+@:-]*) echo "WARNING: $RULE_ROOT contains characters bash cannot take unquoted; the spawn invocation will not match the allow rule. Use a clone path of letters, digits and . _ - + @ : / only." >&2 ;;
    esac
    if ! command -v node >/dev/null 2>&1; then
      echo "WARNING: node not found — add this to permissions.allow in $SETTINGS yourself:" >&2
      echo "  \"$SPAWN_RULE\"" >&2
    elif ! SETTINGS="$SETTINGS" SPAWN_RULE="$SPAWN_RULE" node -e '
        const fs = require("fs");
        const p = process.env.SETTINGS, rule = process.env.SPAWN_RULE;
        const text = (fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "").replace(/^\uFEFF/, "");
        const s = text.trim() ? JSON.parse(text) : {};
        const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
        if (!isObj(s)) throw new Error(p + " is not a JSON object");
        if (s.permissions == null) s.permissions = {};
        if (!isObj(s.permissions)) throw new Error("permissions in " + p + " is not a JSON object");
        const allow = Array.isArray(s.permissions.allow) ? s.permissions.allow : [];
        const local = (f) => process.platform === "win32" ? f.replace(/^\/([A-Za-z])\//, "$1:/") : f;
        const stale = (r) => {
          const m = /^Bash\(bash (.*\/\.claude\/skills\/committee-loop\/spawn\.sh):\*\)$/.exec(r);
          return m !== null && r !== rule && !fs.existsSync(local(m[1]));
        };
        const next = allow.filter(r => !stale(r));
        if (!next.includes(rule)) next.push(rule);
        if (JSON.stringify(next) === JSON.stringify(allow)) process.exit(0);
        s.permissions.allow = next;
        fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
        console.log("Added permission rule to " + p + ": " + rule);
      '; then
      echo "WARNING: could not update $SETTINGS — add this to permissions.allow yourself:" >&2
      echo "  \"$SPAWN_RULE\"" >&2
    fi
  fi

  echo "Installed committee + committee-loop to $CONFIG_DIR (skills/, workflows/)"
done
echo "  source: $REPO_ROOT"
echo "Start a new Claude Code session and /committee + /committee-loop will be available."
