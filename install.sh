#!/usr/bin/env bash
set -euo pipefail

# Install committee + committee-loop into ~/.claude/skills/ via symlinks so
# /committee and /committee-loop are available in every Claude Code session.
#
# Run from the repo root after cloning:
#   git clone https://github.com/jonazri/committee.git && cd committee && ./install.sh
#
# Re-running is safe — symlinks are overwritten in place (ln -sfn).
# Uninstall: rm -rf ~/.claude/skills/committee ~/.claude/skills/committee-loop ~/.claude/workflows/committee-review.js

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"

for f in \
  "$REPO_ROOT/.claude/skills/committee/SKILL.md" \
  "$REPO_ROOT/.claude/skills/committee-loop/SKILL.md" \
  "$REPO_ROOT/prompts/committee-review.js"; do
  [ -f "$f" ] || { echo "install.sh must run from the committee repo root (missing $f)" >&2; exit 1; }
done

mkdir -p "$SKILLS_DIR/committee" "$SKILLS_DIR/committee-loop"

# ln -sfn creates a symlink INSIDE a target that is a pre-existing real directory
# (migration case from the old `cp -r prompts` install). Replace such a target first.
safe_symlink() {
  local src="$1" target="$2"
  if [ -d "$target" ] && [ ! -L "$target" ]; then
    rm -rf -- "$target"
  fi
  ln -sfn "$src" "$target"
}

# /committee — skill discovery needs a real dir; SKILL.md can be a symlink
# (SKILL.md's lookup uses readlink -f to find the real skill dir containing
# prepare.sh). The reviewer/verifier templates + committee-review workflow load from
# prompts/ at ~/.claude/skills/committee/prompts/ for user-global installs.
safe_symlink "$REPO_ROOT/.claude/skills/committee/SKILL.md" "$SKILLS_DIR/committee/SKILL.md"
safe_symlink "$REPO_ROOT/prompts" "$SKILLS_DIR/committee/prompts"

# Named user-scope workflow so the skill can invoke Workflow({name:"committee-review"}).
# Rides the same source-of-truth as prompts/ — edits to the workflow are live.
mkdir -p "$HOME/.claude/workflows"
safe_symlink "$REPO_ROOT/prompts/committee-review.js" "$HOME/.claude/workflows/committee-review.js"

# /committee-loop — same pattern; spawn.sh is resolved via readlink -f on SKILL.md
safe_symlink "$REPO_ROOT/.claude/skills/committee-loop/SKILL.md" "$SKILLS_DIR/committee-loop/SKILL.md"

echo "Installed committee + committee-loop to $SKILLS_DIR"
echo "  source: $REPO_ROOT"
echo "Start a new Claude Code session and /committee + /committee-loop will be available."
