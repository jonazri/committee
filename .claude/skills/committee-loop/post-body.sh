# Appended to .committee-loop-post.sh after a header written by spawn.sh
# that sets: ORIGIN_PATH, WORKTREE_PATH, BRANCH, SESSION, ORIGIN_REF,
# TARGET_FILES[], SEED_HASHES[], plus `set -euo pipefail` and the shebang.
#
# Do NOT run this file directly — it will exit nonzero because those vars
# are unset. It exists only as the body spawn.sh concatenates.

# Signal-safe TMP cleanup for the atomic cp-to-tmp + mv -f replace below.
# Without this trap, SIGTERM between `cp -P "$rel" "$TMP"` and `mv -f "$TMP" "$dest"`
# leaks a `.committee-loop.$$.tmp` file in origin's target directory.
# Two traps: EXIT for cleanup-only on natural exit; INT/TERM/HUP also TERMINATE
# via `exit 130` so a trapped signal stops post.sh rather than letting it
# continue through copy-back + commit after the handler returns (bash's default
# is to continue after a custom signal handler returns).
TMP=""
cleanup_tmp() {
  [ -n "${TMP:-}" ] && rm -f -- "$TMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT
trap 'cleanup_tmp; exit 130' INT TERM HUP

cd "$WORKTREE_PATH"

# --git-common-dir (not ".git") because origin may itself be a linked worktree
# where .git is a file pointing to the real gitdir. --path-format=absolute
# (git 2.31+) forces an absolute path — without it, `rev-parse --git-common-dir`
# returns the relative string ".git", which breaks `mkdir -p "$ART_DIR"` below
# because our cwd is $WORKTREE_PATH where .git is a file, not a directory.
ORIGIN_GIT_DIR=$(git -C "$ORIGIN_PATH" rev-parse --path-format=absolute --git-common-dir)

# Refuse copy-back if origin's branch has moved since spawn. Without this,
# a user who `git switch`'d origin during the detached run would get the
# review commit on the new branch (bytes may hash-match because the same file
# exists on the new branch). "HEAD" means origin is in detached state now —
# also refuse. `|| true` on rev-parse so a transient git failure goes to the
# explicit BLOCKED path below rather than tripping set -e silently.
CURRENT_ORIGIN_REF=$(git -C "$ORIGIN_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ "$CURRENT_ORIGIN_REF" != "$ORIGIN_REF" ]; then
  printf 'origin branch changed during the review: was %s, now %s; refusing to copy back\n' "$ORIGIN_REF" "$CURRENT_ORIGIN_REF" > .committee-loop-BLOCKED.txt
  echo "BLOCKED: origin branch changed ($ORIGIN_REF -> $CURRENT_ORIGIN_REF)" >&2
  exit 0
fi

# Merged validate-then-write loop: separate validate/write loops leave a TOCTOU
# window where a concurrent mutation (e.g. parent-dir symlink swap) can race
# through. Doing the write immediately after per-file validation shrinks the
# window to microseconds. A fully atomic solution isn't possible in pure bash.
#
# Partial-write safety (multi-target): track which targets were successfully
# written. On block, `break` instead of `exit 0`, then commit whatever made it
# with a (PARTIAL) note so origin is never left with uncommitted changes.
declare -a WRITTEN=()
BLOCK_MSG=""
for i in "${!TARGET_FILES[@]}"; do
  expected="${SEED_HASHES[$i]}"
  rel="${TARGET_FILES[$i]}"
  dest="$ORIGIN_PATH/$rel"
  if [ ! -f "$dest" ]; then
    BLOCK_MSG=$(printf 'origin target %s no longer exists; refusing to overwrite\n' "$rel"); break
  fi
  # Re-validate symlink + containment at copy-back time. Without this, a swap
  # of the origin target into a symlink during the detached run would let
  # sha256sum (which follows symlinks) + cp (which writes through dest symlinks)
  # overwrite a file outside the repo under --dangerously-skip-permissions.
  if [ -L "$dest" ]; then
    BLOCK_MSG=$(printf 'origin target %s became a symlink during the review; refusing to overwrite\n' "$rel"); break
  fi
  ABS=$(realpath -e -- "$dest" 2>/dev/null || true)
  if [ -z "$ABS" ]; then
    BLOCK_MSG=$(printf 'origin target %s could not be resolved by realpath; refusing to overwrite\n' "$rel"); break
  fi
  case "$ABS" in
    "$ORIGIN_PATH"/*) ;;
    *)
      BLOCK_MSG=$(printf 'origin target %s resolves outside origin (%s); refusing to overwrite\n' "$rel" "$ABS"); break ;;
  esac
  current=$(sha256sum "$dest" | awk '{print $1}')
  [ -n "$current" ] || { echo "sha256sum failed for $dest"; exit 1; }
  if [ "$expected" != "$current" ]; then
    BLOCK_MSG=$(printf 'origin target %s changed during the review; refusing to overwrite\n' "$rel"); break
  fi
  # Validate the worktree source BEFORE removing origin. Without this check,
  # a missing/unreadable/became-a-symlink source makes rm -f remove origin,
  # then cp -P fails under set -e — destructive partial state.
  if [ ! -f "$rel" ] || [ -L "$rel" ]; then
    BLOCK_MSG=$(printf 'worktree source %s missing or is a symlink; refusing to overwrite origin\n' "$rel"); break
  fi
  # Worktree-source containment check. `[ -L "$rel" ]` above only catches a
  # symlink at the LEAF; a parent-dir swap (e.g. `sub/` replaced with a symlink
  # to `/tmp/evil` during the run) passes the leaf check but `cp -P -- "$rel"`
  # would then read through the symlinked parent. Resolving with realpath and
  # requiring the result stay under $WORKTREE_PATH closes the directory-
  # component TOCTOU under --dangerously-skip-permissions.
  SRC_ABS=$(realpath -e -- "$rel" 2>/dev/null || true)
  if [ -z "$SRC_ABS" ]; then
    BLOCK_MSG=$(printf 'worktree source %s could not be resolved by realpath; refusing to overwrite\n' "$rel"); break
  fi
  case "$SRC_ABS" in
    "$WORKTREE_PATH"/*) ;;
    *)
      BLOCK_MSG=$(printf 'worktree source %s resolves outside worktree (%s); refusing to overwrite\n' "$rel" "$SRC_ABS"); break ;;
  esac
  # Atomic replace: cp to sibling tmp, then mv into place. Avoids the destructive
  # window of `rm then cp` — if cp fails (EIO, EDQUOT, disk-full, perms race) the
  # dest stays intact and BLOCK_MSG fires. `.$$` suffix is unique per post.sh
  # process; explicit rm -f on the failure branches + the EXIT/INT/TERM trap above
  # clean up the tmp file under command failure AND under signal.
  TMP="$dest.committee-loop.$$.tmp"
  rm -f -- "$TMP"
  if ! cp -P -- "$rel" "$TMP"; then
    rm -f -- "$TMP"
    BLOCK_MSG=$(printf 'cp of worktree source %s to tmp failed; origin unchanged\n' "$rel"); break
  fi
  # mv -f overwrites dest atomically (rename(2) on same filesystem). If dest
  # is itself a symlink, rename replaces the symlink — which is what we want,
  # since the earlier `[ -L "$dest" ]` check already rejected symlinks.
  if ! mv -f -- "$TMP" "$dest"; then
    rm -f -- "$TMP"
    BLOCK_MSG=$(printf 'atomic mv of %s into origin failed; origin unchanged\n' "$rel"); break
  fi
  WRITTEN+=( "$rel" )
done

if [ -n "$BLOCK_MSG" ]; then
  printf '%s' "$BLOCK_MSG" > .committee-loop-BLOCKED.txt
  [ "${#WRITTEN[@]}" -gt 0 ] && printf 'partially written (committed separately): %s\n' "${WRITTEN[*]}" >> .committee-loop-BLOCKED.txt
  # Echo to stderr so the block reason is visible via `tmux capture-pane`
  # without requiring the user to ls into the preserved worktree.
  echo "BLOCKED: $BLOCK_MSG" >&2
fi

# Commit whatever WAS written — even on partial block. Leaving origin dirty
# with uncommitted changes is worse than a "(PARTIAL)" commit the user can
# see and decide to revert.
if [ "${#WRITTEN[@]}" -gt 0 ]; then
  # Re-check origin branch right before commit. The initial branch check runs
  # before the validation+copy loop, which takes time — a user `git switch`'ing
  # origin during that window would see our commit land on the current
  # (changed) branch. `mv -f` in the loop has ALREADY written reviewed bytes
  # to origin's working tree, so we CANNOT bail out without leaving origin
  # dirty. Instead: commit anyway with a loud `(BRANCH MOVED)` note so the
  # commit is visible and revertable, and set BLOCK_MSG so the existing
  # exit-0-on-block path skips DONE+teardown.
  REFRESH_ORIGIN_REF=$(git -C "$ORIGIN_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  BRANCH_MOVED=""
  if [ "$REFRESH_ORIGIN_REF" != "$ORIGIN_REF" ]; then
    BRANCH_MOVED="branch moved mid-post.sh from $ORIGIN_REF to $REFRESH_ORIGIN_REF"
    if [ -z "$BLOCK_MSG" ]; then
      BLOCK_MSG="$BRANCH_MOVED"
      printf '%s\n' "$BRANCH_MOVED" > .committee-loop-BLOCKED.txt
    else
      BLOCK_MSG="$BLOCK_MSG; also $BRANCH_MOVED"
      printf '%s\n' "$BRANCH_MOVED" >> .committee-loop-BLOCKED.txt
    fi
    echo "BLOCKED: $BRANCH_MOVED" >&2
  fi
  git -C "$ORIGIN_PATH" add -- "${WRITTEN[@]}"
  if ! git -C "$ORIGIN_PATH" diff --cached --quiet -- "${WRITTEN[@]}"; then
    COMMIT_NOTE="review: apply committee-loop review to ${WRITTEN[*]}"
    if [ -n "$BRANCH_MOVED" ]; then
      COMMIT_NOTE="${COMMIT_NOTE} (BRANCH MOVED — ${BRANCH_MOVED}; commit lands on $REFRESH_ORIGIN_REF)"
    elif [ -n "$BLOCK_MSG" ]; then
      COMMIT_NOTE="${COMMIT_NOTE} (PARTIAL — see .committee-loop-BLOCKED.txt)"
    elif [ -f .committee-loop-CONVERGED.txt ]; then
      # Surface the convergence-by-give-up case in git log so a reader can tell
      # a truly clean review apart from one that stopped to avoid oscillation.
      COMMIT_NOTE="${COMMIT_NOTE} (CONVERGED)"
    fi
    git -C "$ORIGIN_PATH" commit -m "$COMMIT_NOTE" -- "${WRITTEN[@]}"
  fi
fi

# On block, preserve the worktree+branch+session so the user can inspect
# BLOCKED.txt and decide how to resolve. DONE sentinel + artifact dir + teardown
# are only written on clean (or converged) completion.
if [ -n "$BLOCK_MSG" ]; then
  exit 0
fi

# Nest artifacts under a per-session subdirectory so concurrent or sequential
# runs in the same repo don't overwrite each other's audit trail.
ART_DIR="$ORIGIN_GIT_DIR/committee-loop/$SESSION"
mkdir -p "$ART_DIR"

# Copy sidecars FIRST, write DONE LAST (atomic rename). The watcher's classify
# checks DONE before CONVERGED.txt — if DONE were written before CONVERGED.txt
# is copied, a sweep landing in that window would misreport a converged run as
# plain DONE. Atomic rename ensures DONE appears only when all sidecars are in
# place.
[ -f .committee-loop-decisions.md ] && cp .committee-loop-decisions.md "$ART_DIR/decisions.md"
[ -f .committee-loop-DEFERRED.md ]  && cp .committee-loop-DEFERRED.md  "$ART_DIR/deferred.md"
[ -f .committee-loop-CONVERGED.txt ] && cp .committee-loop-CONVERGED.txt "$ART_DIR/CONVERGED.txt"
git -C "$ORIGIN_PATH" rev-parse HEAD > "$ART_DIR/DONE.tmp"
mv -f -- "$ART_DIR/DONE.tmp" "$ART_DIR/DONE"

cd "$ORIGIN_PATH"
git worktree remove --force "$WORKTREE_PATH" || true
git branch -D "$BRANCH" || true
tmux kill-session -t "$SESSION" 2>/dev/null || true
