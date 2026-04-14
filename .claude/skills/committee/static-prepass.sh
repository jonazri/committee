#!/usr/bin/env bash
# Static-analyzer pre-pass for the committee skill.
# Invoked by prepare.sh after the scope handler populates SESSION_DIR/diff.txt.
# Runs one analyzer per applicable file extension and writes findings to
# SESSION_DIR/static.txt. If no analyzers have findings (or none are installed),
# writes an empty file. Never fails the pipeline — static analysis is
# advisory context for LLM reviewers, not a gate.
#
# Usage:
#   static-prepass.sh <session-dir> <file> [<file>...]
#
# The caller passes the list of files in the review's scope. For diff-based
# scopes, prepare.sh derives this from `git diff --name-only`; for files scope
# it's the paths.txt contents.
set -u

SESSION_DIR="${1:-}"
shift || true
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] \
  || { echo "static-prepass.sh: session dir missing or not a directory: $SESSION_DIR" >&2; exit 0; }

STATIC="$SESSION_DIR/static.txt"
: > "$STATIC"

# No files? Leave static.txt empty and exit cleanly.
[ "$#" -gt 0 ] || exit 0

# Group files by extension so we can run each analyzer once over its batch.
declare -a SH_FILES=()
declare -a PY_FILES=()
declare -a JSON_FILES=()
declare -a YAML_FILES=()
for f in "$@"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.sh|*.bash) SH_FILES+=( "$f" ) ;;
    *.py)        PY_FILES+=( "$f" ) ;;
    *.json)      JSON_FILES+=( "$f" ) ;;
    *.yaml|*.yml) YAML_FILES+=( "$f" ) ;;
  esac
done

append_section() {
  local name="$1"
  local content="$2"
  [ -z "$content" ] && return 0
  {
    printf '=== %s ===\n' "$name"
    printf '%s\n' "$content"
    printf '\n'
  } >> "$STATIC"
}

# --- shellcheck on .sh / .bash ---
if [ "${#SH_FILES[@]}" -gt 0 ] && command -v shellcheck >/dev/null 2>&1; then
  # -x so sourced files are followed; -S style so style-level warnings surface
  # too (committee reviewers benefit from extra signal even on style).
  # --format=gcc gives one-finding-per-line, file:line:col:severity:message —
  # easy for LLMs to parse. Capture stdout only; stderr is analyzer warnings
  # that aren't findings.
  out=$(shellcheck -x -S style --format=gcc -- "${SH_FILES[@]}" 2>/dev/null || true)
  append_section "shellcheck" "$out"
fi

# --- ruff on .py (if installed) ---
if [ "${#PY_FILES[@]}" -gt 0 ] && command -v ruff >/dev/null 2>&1; then
  out=$(ruff check --output-format=concise -- "${PY_FILES[@]}" 2>/dev/null || true)
  append_section "ruff" "$out"
fi

# --- python -m json.tool on .json (syntax-only; ruff/jq don't lint JSON) ---
if [ "${#JSON_FILES[@]}" -gt 0 ] && command -v python3 >/dev/null 2>&1; then
  out=""
  for f in "${JSON_FILES[@]}"; do
    err=$(python3 -m json.tool --no-ensure-ascii < "$f" >/dev/null 2>&1 \
          || python3 -c "import json,sys; json.load(open('$f'))" 2>&1 | tail -1)
    [ -n "$err" ] && out="$out$f: $err"$'\n'
  done
  append_section "json syntax" "$out"
fi

# --- yamllint on .yaml / .yml (if installed) ---
if [ "${#YAML_FILES[@]}" -gt 0 ] && command -v yamllint >/dev/null 2>&1; then
  out=$(yamllint -f parsable -- "${YAML_FILES[@]}" 2>/dev/null || true)
  append_section "yamllint" "$out"
fi

# If static.txt ended up with content, prepend a one-line header so LLMs know
# what they're looking at. Done as a post-write step (not inline) so the empty-
# findings case stays a truly empty file.
if [ -s "$STATIC" ]; then
  header="Static-analysis findings (advisory — use as context, not as the sole basis for issues)"
  tmp=$(mktemp "$SESSION_DIR/static.XXXXXX.tmp")
  {
    printf '%s\n\n' "$header"
    cat "$STATIC"
  } > "$tmp"
  mv -f -- "$tmp" "$STATIC"
fi

exit 0
