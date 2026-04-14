#!/usr/bin/env bash
# Committee skill: resolve scope + create session dir + precompute diff files.
# Invoked once by the SKILL.md outer agent before the trust dialog and dispatch.
# Emits a manifest (KEY=value, %q-escaped) to stdout AND to $SESSION_DIR/manifest.txt.
#
# Usage:
#   prepare.sh --scope=branch_diff  --base=<branch>
#   prepare.sh --scope=commit       --commit=<sha>
#   prepare.sh --scope=sha_range    --range=<sha>..<sha>        # or <sha>...<sha>
#   prepare.sh --scope=pr           --pr=<n>  [--pr-url=<URL>]
#   prepare.sh --scope=files        --paths-file=<path>
#   prepare.sh --scope=plan         --plan=<path>  [--spec=<path>]
#   prepare.sh --scope=uncommitted
#   prepare.sh --scope=auto
#   prepare.sh --scope=vague        --keywords-file=<path>       # no session dir, just candidate listings
#
# All user-controlled values arrive via `--key=value` flag parsing (no shell
# word-splitting). SHA / PR / branch formats are validated before use.
# Filenames containing a literal newline byte are unsupported by the files
# scope (POSIX-valid but extremely rare).
set -euo pipefail

# ---- Flag parsing ----

SCOPE=""
BASE=""
COMMIT=""
RANGE=""
PR=""
PR_URL=""
PATHS_FILE=""
PLAN=""
SPEC=""
KEYWORDS_FILE=""

for arg in "$@"; do
  case "$arg" in
    --scope=*)         SCOPE="${arg#*=}" ;;
    --base=*)          BASE="${arg#*=}" ;;
    --commit=*)        COMMIT="${arg#*=}" ;;
    --range=*)         RANGE="${arg#*=}" ;;
    --pr=*)            PR="${arg#*=}" ;;
    --pr-url=*)        PR_URL="${arg#*=}" ;;
    --paths-file=*)    PATHS_FILE="${arg#*=}" ;;
    --plan=*)          PLAN="${arg#*=}" ;;
    --spec=*)          SPEC="${arg#*=}" ;;
    --keywords-file=*) KEYWORDS_FILE="${arg#*=}" ;;
    *) echo "prepare.sh: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

[ -n "$SCOPE" ] || { echo "prepare.sh: --scope is required" >&2; exit 1; }

# ---- Preflight ----

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "Error: /committee must be run inside a git repository" >&2
  exit 1
}

# ---- Format validators (belt-and-suspenders; model should validate too) ----

validate_sha() {
  [[ "$1" =~ ^[0-9a-fA-F]{6,40}$ ]] || { echo "Error: invalid SHA format: $1" >&2; exit 1; }
}
validate_pr() {
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "Error: invalid PR number: $1" >&2; exit 1; }
}
validate_branch() {
  # git's own validator — excludes shell-metacharacter classes it considers unsafe.
  git check-ref-format --allow-onelevel "$1" 2>/dev/null \
    || { echo "Error: invalid branch name: $1" >&2; exit 1; }
}

# Parse and validate a range arg (a..b or a...b). Sets RANGE_BASE, RANGE_HEAD,
# and RANGE_WAS_THREE_DOT ("1"/"0") for the normalization warning.
parse_range() {
  local r="$1"
  case "$r" in
    *...*) RANGE_BASE="${r%...*}"; RANGE_HEAD="${r#*...}"; RANGE_WAS_THREE_DOT=1 ;;
    *..*)  RANGE_BASE="${r%..*}";  RANGE_HEAD="${r#*..}";  RANGE_WAS_THREE_DOT=0 ;;
    *) echo "Error: invalid range format (expected a..b or a...b): $r" >&2; exit 1 ;;
  esac
  validate_sha "$RANGE_BASE"
  validate_sha "$RANGE_HEAD"
}

# ---- Vague scope: list candidate commits, no session dir ----

if [ "$SCOPE" = "vague" ]; then
  [ -f "$KEYWORDS_FILE" ] || { echo "Error: --keywords-file not found: $KEYWORDS_FILE" >&2; exit 1; }
  # $(cat -- FILE) captures file bytes as a literal arg; the shell does NOT
  # re-parse them for $() or backticks. -F treats the keyword as a fixed
  # string so regex metacharacters (e.g. ".*") match literally.
  echo "=== Commits matching keyword ==="
  git log --oneline --all -F --grep="$(cat -- "$KEYWORDS_FILE")" | head -10 || true
  echo "=== Recent commits with files ==="
  git log --oneline -10 --name-only || true
  exit 0
fi

# ---- Validate flag combinations per scope ----

case "$SCOPE" in
  branch_diff)
    [ -n "$BASE" ] || { echo "Error: --base required for branch_diff" >&2; exit 1; }
    validate_branch "$BASE"
    ;;
  commit)
    [ -n "$COMMIT" ] || { echo "Error: --commit required for commit scope" >&2; exit 1; }
    validate_sha "$COMMIT"
    ;;
  sha_range)
    [ -n "$RANGE" ] || { echo "Error: --range required for sha_range" >&2; exit 1; }
    parse_range "$RANGE"
    ;;
  pr)
    [ -n "$PR" ] || { echo "Error: --pr required for pr scope" >&2; exit 1; }
    validate_pr "$PR"
    ;;
  files)
    [ -n "$PATHS_FILE" ] && [ -f "$PATHS_FILE" ] \
      || { echo "Error: --paths-file missing or not found: $PATHS_FILE" >&2; exit 1; }
    ;;
  plan)
    [ -n "$PLAN" ] && [ -f "$PLAN" ] \
      || { echo "Error: --plan missing or not a file: $PLAN" >&2; exit 1; }
    [ -z "$SPEC" ] || [ -f "$SPEC" ] \
      || { echo "Error: --spec not found: $SPEC" >&2; exit 1; }
    ;;
  auto|uncommitted) ;;
  *) echo "Error: unknown scope: $SCOPE" >&2; exit 1 ;;
esac

# ---- Create session dir ----

# Cleanup trap: fires on ANY shell termination (normal exit, explicit exit N,
# set -e, SIGINT, SIGTERM, SIGHUP). EXIT coverage is required because the
# script uses `|| { ...; exit 1; }` validation patterns that bypass the ERR
# trap — leaking SESSION_DIR and (PR scope) fetched refs if we only relied on
# ERR. At the end of the happy path we `trap - EXIT` before `cat "$MANIFEST"`
# to suppress cleanup on success.
#
# State signals (all default-empty):
#   UNCOMMITTED_UNTRACKED_NUL — non-empty path => outstanding `git add -N` to
#                               roll back via `xargs -0 git reset --`.
#                               Cleared on the happy path after reset runs.
#   PR_BASE_FETCHED          — "1" => `refs/pr-committee/$PR-base` was
#                               successfully fetched and must be torn down
#                               on any failure path. Not cleared on the happy
#                               path — the `trap - EXIT` before manifest cat
#                               makes the flag moot.
#
# NOTE on refs/pull/$PR/head: git-fetch always REPLACES the ref's value if it
# exists, so we don't track or delete it here. Users may have pre-existing
# refs/pull/* from unrelated workflows; touching them would violate least-
# surprise. The pr-committee/* namespace is this skill's own.
UNCOMMITTED_UNTRACKED_NUL=""
PR_BASE_FETCHED=""

cleanup_on_exit() {
  local rc=$?
  # Roll back intent-to-add registration before removing SESSION_DIR (the
  # untracked.nul file lives inside it).
  if [ -n "$UNCOMMITTED_UNTRACKED_NUL" ] && [ -f "$UNCOMMITTED_UNTRACKED_NUL" ]; then
    xargs -0 -- git reset -- < "$UNCOMMITTED_UNTRACKED_NUL" >/dev/null 2>&1 || true
  fi
  # Only clean dirs we know we created under .committee/. Never rm -rf a raw
  # $SESSION_DIR whose prefix we haven't verified.
  case "${SESSION_DIR:-}" in
    "$PROJECT_ROOT"/.committee/session-*)
      rm -rf -- "$SESSION_DIR" 2>/dev/null || true
      ;;
  esac
  if [ "$PR_BASE_FETCHED" = 1 ]; then
    git update-ref -d "refs/pr-committee/$PR-base" 2>/dev/null || true
  fi
  exit "$rc"
}

mkdir -p "$PROJECT_ROOT/.committee"
SESSION_DIR=$(mktemp -d "$PROJECT_ROOT/.committee/session-XXXXXX")
# Install trap IMMEDIATELY after mktemp. The case prefix-guard inside
# cleanup_on_exit no-ops on an empty SESSION_DIR, so this is safe even if the
# sanity check below fires.
trap cleanup_on_exit EXIT
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] \
  || { echo "Error: failed to create session directory" >&2; exit 1; }

# Initialize diff.err — all later diff operations APPEND via `2>>`, never
# overwrite, so stderr from every step is preserved together.
: > "$SESSION_DIR/diff.err"

# ---- Scope handlers: write diff.txt/diff_stat.txt, set BASE_SHA/HEAD_SHA/SCOPE_DESC ----

BASE_SHA="none"
HEAD_SHA="none"
COMMIT_SHA=""
BASE_BRANCH=""
HEAD_BRANCH=""
SCOPE_DESC=""
RANGE_NORMALIZED=""

handle_branch_diff() {
  local base="$1"
  BASE_SHA=$(git merge-base "$base" HEAD)
  HEAD_SHA=$(git rev-parse HEAD)
  BASE_BRANCH="$base"
  SCOPE_DESC="branch diff from $base (${BASE_SHA:0:8}..${HEAD_SHA:0:8})"
  git diff        "$BASE_SHA..$HEAD_SHA" > "$SESSION_DIR/diff.txt"      2>>"$SESSION_DIR/diff.err"
  git diff --stat "$BASE_SHA..$HEAD_SHA" > "$SESSION_DIR/diff_stat.txt" 2>>"$SESSION_DIR/diff.err"
}

handle_commit() {
  local sha="$1"
  HEAD_SHA=$(git rev-parse "$sha")
  COMMIT_SHA="$HEAD_SHA"
  # --verify is load-bearing: without it, git rev-parse prints the unresolved
  # ref literal to stdout before exiting non-zero, producing "<sha>^\nnone".
  BASE_SHA=$(git rev-parse --verify "${sha}^" 2>/dev/null || echo "none")
  SCOPE_DESC="commit ${HEAD_SHA:0:8}"
  git show        "$HEAD_SHA" > "$SESSION_DIR/diff.txt"      2>>"$SESSION_DIR/diff.err"
  git show --stat "$HEAD_SHA" > "$SESSION_DIR/diff_stat.txt" 2>>"$SESSION_DIR/diff.err"
}

handle_sha_range() {
  BASE_SHA=$(git rev-parse "$RANGE_BASE")
  HEAD_SHA=$(git rev-parse "$RANGE_HEAD")
  SCOPE_DESC="range ${BASE_SHA:0:8}..${HEAD_SHA:0:8}"
  git diff        "$BASE_SHA..$HEAD_SHA" > "$SESSION_DIR/diff.txt"      2>>"$SESSION_DIR/diff.err"
  git diff --stat "$BASE_SHA..$HEAD_SHA" > "$SESSION_DIR/diff_stat.txt" 2>>"$SESSION_DIR/diff.err"
  if [ "$RANGE_WAS_THREE_DOT" = 1 ]; then
    # Emit both the stderr warning AND a manifest flag. SKILL.md's manifest-
    # parse step is the documented contract; stderr is supplementary.
    RANGE_NORMALIZED="1"
    printf 'Note: Three-dot range was normalized to two-dot. Review covers changes between the two commits, not symmetric-diff against merge-base.\n' >&2
  fi
}

handle_pr() {
  command -v gh >/dev/null 2>&1 || { echo "Error: gh (GitHub CLI) not installed" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Error: gh not authenticated (run 'gh auth login')" >&2; exit 1; }

  local repo_flag=""
  local remote_ref="origin"
  if [ -n "$PR_URL" ]; then
    # Extract OWNER/REPO from a github.com URL. The regex anchors to github.com
    # to avoid accepting arbitrary URLs; strips optional trailing .git.
    if [[ "$PR_URL" =~ github\.com[:/]([^/]+/[^/]+)/pull/[0-9]+ ]]; then
      local owner_repo="${BASH_REMATCH[1]%.git}"
      # GitHub owner/repo rules: no leading dot/hyphen, no consecutive dots.
      # The outer regex forbids leading '.' and '-'; the `!= *..*` check
      # rejects consecutive dots. Shell metacharacters are already excluded.
      [[ "$owner_repo" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] \
        && [[ "$owner_repo" != *..* ]] \
        || { echo "Error: owner/repo has disallowed chars: $owner_repo" >&2; exit 1; }
      repo_flag="-R $owner_repo"
      remote_ref="https://github.com/$owner_repo.git"
    else
      echo "Error: could not parse owner/repo from URL: $PR_URL" >&2; exit 1
    fi
  fi

  # gh $repo_flag is intentionally unquoted — empty repo_flag must disappear,
  # and when populated it's exactly "-R OWNER/REPO" with owner/repo already
  # regex-validated above.
  local pr_json
  pr_json=$(gh $repo_flag pr view "$PR" --json title,baseRefName,headRefName,url) \
    || { echo "Error: gh pr view failed for #$PR" >&2; exit 1; }
  local base_ref
  base_ref=$(printf '%s' "$pr_json" \
    | sed -n 's/.*"baseRefName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$base_ref" ] || { echo "Error: could not extract baseRefName from gh pr view" >&2; exit 1; }
  validate_branch "$base_ref"

  # Fetch under refs/pr-committee/ to avoid clashing with the user's tracking refs.
  git fetch "$remote_ref" "refs/pull/$PR/head:refs/pull/$PR/head" 2>>"$SESSION_DIR/diff.err" \
    || { echo "Error: could not fetch PR head ref from $remote_ref" >&2; exit 1; }
  git fetch "$remote_ref" "refs/heads/$base_ref:refs/pr-committee/$PR-base" 2>>"$SESSION_DIR/diff.err" \
    || { echo "Error: could not fetch base branch '$base_ref' from $remote_ref" >&2; exit 1; }
  # pr-committee/$PR-base ref now exists — signal cleanup_on_exit to tear it
  # down on failure. refs/pull/$PR/head is intentionally not tracked (see
  # note on cleanup_on_exit). If fetch #2 above had failed, this flag would
  # stay empty and cleanup would correctly no-op on pr-committee.
  PR_BASE_FETCHED=1

  BASE_SHA=$(git merge-base "refs/pr-committee/$PR-base" "refs/pull/$PR/head")
  HEAD_SHA=$(git rev-parse "refs/pull/$PR/head")
  BASE_BRANCH="$base_ref"
  HEAD_BRANCH="refs/pull/$PR/head"
  SCOPE_DESC="PR #$PR (${BASE_SHA:0:8}..${HEAD_SHA:0:8})"

  git diff        "$BASE_SHA..$HEAD_SHA" > "$SESSION_DIR/diff.txt"      2>>"$SESSION_DIR/diff.err"
  git diff --stat "$BASE_SHA..$HEAD_SHA" > "$SESSION_DIR/diff_stat.txt" 2>>"$SESSION_DIR/diff.err"
}

handle_files() {
  cp -- "$PATHS_FILE" "$SESSION_DIR/paths.txt"
  : > "$SESSION_DIR/diff.txt"
  : > "$SESSION_DIR/diff_stat.txt"
  local count=0 resolved
  # POSIX-compatible read loop — no mapfile dependency.
  # realpath + prefix check contains paths to $PROJECT_ROOT so absolute paths
  # like /etc/passwd or symlinks escaping the repo can't be shipped to external
  # reviewer LLMs. Relative paths resolve against CWD and are then checked.
  while IFS= read -r f || [ -n "$f" ]; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || { echo "Error: file not found: $f" >&2; exit 1; }
    resolved=$(realpath -- "$f") \
      || { echo "Error: could not resolve path: $f" >&2; exit 1; }
    case "$resolved" in
      "$PROJECT_ROOT"/*) ;;
      *) echo "Error: path escapes project root: $f -> $resolved" >&2; exit 1 ;;
    esac
    printf '=== FILE: %s ===\n' "$f" >> "$SESSION_DIR/diff.txt"      2>>"$SESSION_DIR/diff.err"
    cat -- "$resolved"               >> "$SESSION_DIR/diff.txt"      2>>"$SESSION_DIR/diff.err"
    printf '\n'                      >> "$SESSION_DIR/diff.txt"      2>>"$SESSION_DIR/diff.err"
    wc -l -- "$resolved"             >> "$SESSION_DIR/diff_stat.txt" 2>>"$SESSION_DIR/diff.err"
    count=$((count + 1))
  done < "$SESSION_DIR/paths.txt"
  SCOPE_DESC="$count file(s)"
}

handle_plan() {
  cp -- "$PLAN" "$SESSION_DIR/diff.txt"                            2>>"$SESSION_DIR/diff.err"
  wc -l -- "$PLAN"          > "$SESSION_DIR/diff_stat.txt"         2>>"$SESSION_DIR/diff.err"
  if [ -n "$SPEC" ]; then
    # Copy spec into the session dir so the review is self-contained even if
    # the user later moves/deletes the source. Redirect SPEC so the manifest
    # points at the session-local copy.
    cp -- "$SPEC" "$SESSION_DIR/spec.txt"                          2>>"$SESSION_DIR/diff.err"
    SPEC="$SESSION_DIR/spec.txt"
  fi
  SCOPE_DESC="plan $PLAN"
}

handle_uncommitted() {
  # add -N registers untracked files so their additions appear in `git diff HEAD`
  # without staging content. Capture the list to a NUL-separated file — running
  # ls-files again after add -N would return EMPTY (those files are no longer
  # "others"), and xargs -0 with empty input runs `git reset --` with no paths,
  # which unstages the user's ENTIRE index.
  git ls-files --others --exclude-standard -z > "$SESSION_DIR/untracked.nul" 2>>"$SESSION_DIR/diff.err"
  if [ -s "$SESSION_DIR/untracked.nul" ]; then
    # Signal cleanup_on_exit that there's outstanding intent-to-add state to
    # roll back. Set BEFORE `git add -N` so partial adds are also rolled back.
    UNCOMMITTED_UNTRACKED_NUL="$SESSION_DIR/untracked.nul"
    xargs -0 -- git add -N -- < "$SESSION_DIR/untracked.nul" 2>>"$SESSION_DIR/diff.err"
  fi
  git diff        HEAD > "$SESSION_DIR/diff.txt"      2>>"$SESSION_DIR/diff.err"
  git diff --stat HEAD > "$SESSION_DIR/diff_stat.txt" 2>>"$SESSION_DIR/diff.err"
  if [ -n "$UNCOMMITTED_UNTRACKED_NUL" ]; then
    xargs -0 -- git reset -- < "$UNCOMMITTED_UNTRACKED_NUL" >/dev/null 2>>"$SESSION_DIR/diff.err"
    # Happy path: clear the signal so cleanup_on_exit no-ops.
    UNCOMMITTED_UNTRACKED_NUL=""
  fi
  SCOPE_DESC="uncommitted changes"
}

handle_auto() {
  local has_changes=0
  if ! git diff --quiet HEAD 2>/dev/null; then has_changes=1; fi
  if [ -n "$(git ls-files --others --exclude-standard)" ]; then has_changes=1; fi

  if [ "$has_changes" = 1 ]; then
    SCOPE="uncommitted"
    handle_uncommitted
    return
  fi

  local current_branch default_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  [ -z "$default_branch" ] \
    && default_branch=$(git remote show origin 2>/dev/null | awk '/HEAD branch/{print $NF}')
  if [ -z "$default_branch" ]; then
    if   git rev-parse --verify main   >/dev/null 2>&1; then default_branch=main
    elif git rev-parse --verify master >/dev/null 2>&1; then default_branch=master
    fi
  fi

  if [ "$current_branch" = "HEAD" ] || [ -z "$default_branch" ] || [ "$current_branch" = "$default_branch" ]; then
    # Detached HEAD, no detectable default, or currently on the default — fall
    # back to reviewing the last commit. (Branch-diff against self would be empty.)
    SCOPE="commit"
    local head
    head=$(git rev-parse HEAD)
    handle_commit "$head"
  else
    SCOPE="branch_diff"
    handle_branch_diff "$default_branch"
  fi
}

# ---- Dispatch to the scope handler ----

case "$SCOPE" in
  branch_diff)  handle_branch_diff "$BASE" ;;
  commit)       handle_commit "$COMMIT" ;;
  sha_range)    handle_sha_range ;;
  pr)           handle_pr ;;
  files)        handle_files ;;
  plan)         handle_plan ;;
  uncommitted)  handle_uncommitted ;;
  auto)         handle_auto ;;
esac

# ---- Emit manifest ----

MANIFEST="$SESSION_DIR/manifest.txt"
# Invariant: EVERY value in this block must be emitted via `printf '...%q...\n'`
# so the manifest round-trips through bash without re-parsing user content.
# Adding a new field without %q will break SKILL.md's manifest-parse step.
{
  printf 'SESSION_DIR=%q\n'        "$SESSION_DIR"
  printf 'PROJECT_ROOT=%q\n'       "$PROJECT_ROOT"
  printf 'SCOPE_TYPE=%q\n'          "$SCOPE"
  printf 'SCOPE_DESCRIPTION=%q\n'   "$SCOPE_DESC"
  printf 'BASE_SHA=%q\n'            "${BASE_SHA:-none}"
  printf 'HEAD_SHA=%q\n'            "${HEAD_SHA:-none}"
  [ -n "$COMMIT_SHA" ]  && printf 'COMMIT_SHA=%q\n'    "$COMMIT_SHA"
  [ -n "$BASE_BRANCH" ] && printf 'BASE_BRANCH=%q\n'   "$BASE_BRANCH"
  [ -n "$HEAD_BRANCH" ] && printf 'HEAD_BRANCH=%q\n'   "$HEAD_BRANCH"
  [ -n "$PR" ]          && printf 'PR_NUMBER=%q\n'     "$PR"
  [ -n "$PR" ]          && printf 'PR_BASE_REF=%q\n'   "refs/pr-committee/$PR-base"
  [ -n "$SPEC" ]        && printf 'SPEC_PATH=%q\n'     "$SPEC"
  [ -n "$RANGE_NORMALIZED" ] && printf 'RANGE_NORMALIZED=%q\n' "$RANGE_NORMALIZED"
} > "$MANIFEST"

# Manifest was written successfully; disarm cleanup_on_exit so the session
# survives for the coordinator + reviewers. Order is load-bearing — disarm
# BEFORE `cat` so a SIGPIPE from a caller reading only the first line
# doesn't trigger cleanup of the now-durable session.
trap - EXIT
cat "$MANIFEST"
