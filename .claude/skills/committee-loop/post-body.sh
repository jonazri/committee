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
trap 'cleanup_tmp; exit 130' INT TERM HUP QUIT

# --git-common-dir (not ".git") because origin may itself be a linked worktree
# where .git is a file pointing to the real gitdir. --path-format=absolute
# (git 2.31+) forces an absolute path — without it, `rev-parse --git-common-dir`
# returns the relative string ".git", which breaks `mkdir -p "$ART_DIR"` below
# because our cwd is $WORKTREE_PATH where .git is a file, not a directory.
#
# Computed early (before worktree-exists check) so the worktree-missing path
# can still write a BLOCKED sentinel to ART_DIR — ART_DIR lives under origin's
# .git/ and survives worktree removal, so the watcher's ART_DIR fallback can
# surface the actual block reason instead of reporting TMUX_DIED.
ORIGIN_GIT_DIR=$(git -C "$ORIGIN_PATH" rev-parse --path-format=absolute --git-common-dir)
ART_DIR="$ORIGIN_GIT_DIR/committee-loop/$SESSION"
mkdir -p "$ART_DIR"

# Idempotency guard: if a previous post.sh run already wrote BLOCKED (and
# inner-agent.md:134 allows re-entry via the BLOCKED-path FINAL-PASS-DONE
# flag), do NOT re-run the validate/write loop. The first run's mv -f wrote
# reviewed bytes to origin, so SEED_HASHES no longer match — a second pass
# would overwrite the original block reason with a misleading "target
# changed during review" message. Honor the first run's decision.
if [ -f "$WORKTREE_PATH/.committee-loop-BLOCKED.txt" ] || [ -f "$ART_DIR/BLOCKED.txt" ]; then
  echo "BLOCKED: prior post.sh run already wrote BLOCKED.txt; not re-running validate/write" >&2
  exit 0
fi

# Fail loudly if the worktree was removed out from under us (e.g. user ran
# `git worktree remove` manually during the detached run). Without this
# guard, `cd` fails under set -e with no explanation and the watcher only
# sees TMUX_DIED — the actual cause (worktree missing) is lost.
if [ ! -d "$WORKTREE_PATH" ]; then
  printf 'worktree %s no longer exists; cannot copy back\n' "$WORKTREE_PATH" > "$ART_DIR/BLOCKED.txt"
  echo "BLOCKED: worktree $WORKTREE_PATH no longer exists; cannot copy back (see $ART_DIR/BLOCKED.txt)" >&2
  exit 0
fi
cd "$WORKTREE_PATH"

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
  # `|| true` so a transient EIO on $dest doesn't abort post.sh before the
  # empty-check + BLOCKED.txt write below. Matches the SRC_HASH pattern at
  # the silent-erasure guard.
  current=$(sha256sum "$dest" | awk '{print $1}' || true)
  if [ -z "$current" ]; then
    BLOCK_MSG=$(printf 'sha256sum failed for %s; refusing to overwrite\n' "$dest"); break
  fi
  if [ "$expected" != "$current" ]; then
    BLOCK_MSG=$(printf 'origin target %s changed during the review; refusing to overwrite\n' "$rel"); break
  fi
  # Refuse to clobber a staged-but-uncommitted version of the target. The
  # sha256 check above covers the working tree only; `git add` during copy-back
  # would silently replace the user's index state with the reviewed bytes.
  if ! git -C "$ORIGIN_PATH" diff --cached --quiet -- "$rel" 2>/dev/null; then
    BLOCK_MSG=$(printf 'origin target %s has staged index changes; refusing to overwrite (run `git restore --staged -- %s` or commit first)\n' "$rel" "$rel"); break
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
  # Silent-erasure guard: if the reviewed bytes (worktree source) equal HEAD
  # for this path AND the origin had dirty uncommitted edits at spawn time
  # (SEED_HASHES[i] != HEAD hash), then overwriting origin with HEAD-equal
  # bytes would silently destroy the user's dirty work — and the downstream
  # `git diff --cached --quiet` check would find no staged diff (index ==
  # HEAD), so no commit records the change and no BLOCKED surfaces. Refuse.
  #
  # Note: `git show HEAD:$rel` for a path that didn't exist at HEAD pipes the
  # empty string into sha256sum, producing the well-known empty-string hash
  # (e3b0c44...). That's the correct behavior: if the reviewer produced a
  # zero-byte file and the user had dirty content at spawn, that's still a
  # silent-erasure case we want to block.
  #
  # `|| true` on both sha256sum invocations: under `set -euo pipefail`,
  # a transient EIO or disappeared file would otherwise abort post.sh without
  # writing BLOCKED.txt, leaving the watcher with TMUX_DIED instead.
  HEAD_HASH=$(git -C "$ORIGIN_PATH" show "HEAD:$rel" 2>/dev/null | sha256sum | awk '{print $1}' || true)
  SRC_HASH=$(sha256sum "$rel" | awk '{print $1}' || true)
  if [ -z "$SRC_HASH" ]; then
    BLOCK_MSG=$(printf 'sha256sum failed on worktree source %s; refusing to overwrite origin\n' "$rel"); break
  fi
  if [ "$SRC_HASH" = "$HEAD_HASH" ] && [ "$expected" != "$HEAD_HASH" ]; then
    BLOCK_MSG=$(printf 'reviewed bytes of %s match HEAD while origin had uncommitted dirty edits at spawn; refusing to overwrite (would silently erase user work with no commit record)\n' "$rel"); break
  fi
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
  printf '%s\n' "$BLOCK_MSG" > .committee-loop-BLOCKED.txt
  [ "${#WRITTEN[@]}" -gt 0 ] && printf 'partially written (committed separately): %s\n' "${WRITTEN[*]}" >> .committee-loop-BLOCKED.txt
  # Echo to stderr so the block reason is visible via `tmux capture-pane`
  # without requiring the user to ls into the preserved worktree.
  echo "BLOCKED: $BLOCK_MSG" >&2
fi

# Re-check origin branch right before commit. The initial branch check runs
# before the validation+copy loop, which takes time — a user `git switch`'ing
# origin during that window would see our commit land on the current
# (changed) branch. `mv -f` in the loop may have ALREADY written reviewed bytes
# to origin's working tree, so we CANNOT bail out without leaving origin
# dirty. Instead: commit anyway (if anything was written) with a loud
# `(BRANCH MOVED)` note so the commit is visible and revertable.
#
# Hoisted outside the ${#WRITTEN[@]} -gt 0 guard: an all-target-blocks-before-
# any-write run must still record branch drift in BLOCKED.txt — otherwise the
# user inspecting a preserved worktree has no indication origin moved.
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

# Commit whatever WAS written — even on partial block. Leaving origin dirty
# with uncommitted changes is worse than a commit the user can see and revert.
#
# Unrelated-staged-work guard: the pathspec-free `git commit` below commits
# the entire index. If the user had staged unrelated files BEFORE the
# detached run, those would be swept into our commit. The per-target
# staged-index check in the validate loop only covers our own target paths.
# If we detect unrelated staged work here, skip the commit and record the
# reason in BLOCKED.txt — origin's working tree already holds our reviewed
# bytes (mv -f happened) so the user can still inspect/commit manually.
SKIP_COMMIT=""
# Helper: is $1 in the WRITTEN array?
is_in_written() {
  local needle="$1"
  local w
  for w in "${WRITTEN[@]}"; do
    [ "$w" = "$needle" ] && return 0
  done
  return 1
}

# Staged paths via NUL-delimited output — handles filenames with newlines /
# tabs / non-ASCII (git default quotes such paths with C-escapes otherwise,
# which splits on newlines and confuses parsing).
#
# Inlined at both call sites instead of a helper using `local -n`, which
# requires bash 4.3+ and breaks on macOS stock bash 3.2.57. Portable across
# bash 3.2+.
if [ "${#WRITTEN[@]}" -gt 0 ]; then
  declare -a PRE_STAGED_ARR=()
  while IFS= read -r -d '' staged_path; do
    [ -n "$staged_path" ] && PRE_STAGED_ARR+=( "$staged_path" )
  done < <(git -C "$ORIGIN_PATH" diff --cached --name-only -z 2>/dev/null || true)
  if [ "${#PRE_STAGED_ARR[@]}" -gt 0 ]; then
    declare -a UNRELATED=()
    for staged_path in "${PRE_STAGED_ARR[@]}"; do
      is_in_written "$staged_path" || UNRELATED+=( "$staged_path" )
    done
    if [ "${#UNRELATED[@]}" -gt 0 ]; then
      UNRELATED_JOINED=$(printf '%s, ' "${UNRELATED[@]}"); UNRELATED_JOINED="${UNRELATED_JOINED%, }"
      EXTRA="origin has unrelated staged changes ($UNRELATED_JOINED); refusing to commit (review bytes are in origin's working tree; stage and commit manually if desired)"
      BLOCK_MSG="${BLOCK_MSG:+$BLOCK_MSG; also }$EXTRA"
      printf '%s\n' "$EXTRA" >> .committee-loop-BLOCKED.txt
      echo "BLOCKED: $EXTRA" >&2
      SKIP_COMMIT=1
    fi
  fi
fi

if [ "${#WRITTEN[@]}" -gt 0 ] && [ -z "$SKIP_COMMIT" ]; then
  git -C "$ORIGIN_PATH" add -- "${WRITTEN[@]}"
  # Re-snapshot staged paths immediately after our git add. A concurrent
  # `git add` of an unrelated file in the window between PRE_STAGED_ARR and
  # this point would be swept into the pathspec-free `git commit` below.
  # Expected set after our add = WRITTEN + whatever was pre-staged (which we
  # already verified was a subset of WRITTEN, or we hit SKIP_COMMIT above).
  declare -a POST_STAGED_ARR=()
  while IFS= read -r -d '' staged_path; do
    [ -n "$staged_path" ] && POST_STAGED_ARR+=( "$staged_path" )
  done < <(git -C "$ORIGIN_PATH" diff --cached --name-only -z 2>/dev/null || true)
  declare -a UNEXPECTED=()
  for staged_path in "${POST_STAGED_ARR[@]}"; do
    is_in_written "$staged_path" || UNEXPECTED+=( "$staged_path" )
  done
  if [ "${#UNEXPECTED[@]}" -gt 0 ]; then
    UNEXPECTED_JOINED=$(printf '%s, ' "${UNEXPECTED[@]}"); UNEXPECTED_JOINED="${UNEXPECTED_JOINED%, }"
    EXTRA="unexpected paths appeared in index during validate→commit window ($UNEXPECTED_JOINED); refusing to commit"
    BLOCK_MSG="${BLOCK_MSG:+$BLOCK_MSG; also }$EXTRA"
    printf '%s\n' "$EXTRA" >> .committee-loop-BLOCKED.txt
    echo "BLOCKED: $EXTRA" >&2
    # Unstage the paths we added so the user's original staged state is
    # preserved as much as possible — `git reset HEAD -- WRITTEN` restores
    # HEAD state for those paths in the index.
    git -C "$ORIGIN_PATH" reset --quiet HEAD -- "${WRITTEN[@]}" 2>/dev/null || true
    SKIP_COMMIT=1
  fi
fi

if [ "${#WRITTEN[@]}" -gt 0 ] && [ -z "$SKIP_COMMIT" ]; then
  if ! git -C "$ORIGIN_PATH" diff --cached --quiet -- "${WRITTEN[@]}"; then
    # Build a tag list instead of if/elif so multiple conditions (e.g. PARTIAL +
    # BRANCH MOVED for a partial-write run where origin also drifted) all
    # surface in the commit note. Prior if/elif dropped PARTIAL when BRANCH
    # MOVED also fired, silently losing the audit marker.
    declare -a TAGS=()
    [ -n "$BRANCH_MOVED" ] && TAGS+=( "BRANCH MOVED — $BRANCH_MOVED; commit lands on $REFRESH_ORIGIN_REF" )
    # PARTIAL only applies if a per-target block fired (BLOCK_MSG set by the
    # copy loop, not by branch-drift detection above). Check BRANCH_MOVED
    # isn't the only cause of BLOCK_MSG before tagging PARTIAL.
    if [ -n "$BLOCK_MSG" ] && [ "$BLOCK_MSG" != "$BRANCH_MOVED" ]; then
      TAGS+=( "PARTIAL — see .committee-loop-BLOCKED.txt" )
    fi
    [ -f .committee-loop-CONVERGED.txt ] && TAGS+=( "CONVERGED" )
    COMMIT_NOTE="review: apply committee-loop review to ${WRITTEN[*]}"
    if [ "${#TAGS[@]}" -gt 0 ]; then
      TAG_JOINED=$(printf ' (%s)' "${TAGS[@]}")
      COMMIT_NOTE="${COMMIT_NOTE}${TAG_JOINED}"
    fi
    # No pathspec on `git commit` — `git commit -- <paths>` uses pathspec/
    # --only semantics that RE-READ working tree bytes at commit time, which
    # would reopen the TOCTOU that sha256sum + mv -f close. Commit the index
    # we just staged above.
    git -C "$ORIGIN_PATH" commit -m "$COMMIT_NOTE"
  fi
fi

# On block, preserve the worktree+branch+session so the user can inspect
# BLOCKED.txt and decide how to resolve. DONE sentinel + artifact dir + teardown
# are only written on clean (or converged) completion.
if [ -n "$BLOCK_MSG" ]; then
  exit 0
fi

# ART_DIR was computed at the top of this script (before the worktree-exists
# check) so the worktree-missing branch could also write BLOCKED there.
# No re-mkdir needed; the top-of-script `mkdir -p "$ART_DIR"` already succeeded.
#
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
