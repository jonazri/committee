# Appended to .committee-loop-watcher.sh after a header written by spawn.sh
# that sets: SESSION, WORKTREE_PATH, ART_DIR, plus `set -u` and shebang.
#
# Priority order on each sweep: DONE (clean/converged) > BLOCKED > EXHAUSTED > TMUX_DIED.
# On tmux death without any sentinel, a 2s grace re-sweep covers the race between
# post.sh's final writes and tmux teardown.
classify() {
  if [ -f "$ART_DIR/DONE" ]; then
    if [ -f "$ART_DIR/CONVERGED.txt" ]; then
      echo "CONVERGED:$(cat "$ART_DIR/DONE")"
    else
      echo "DONE:$(cat "$ART_DIR/DONE")"
    fi
    return 0
  fi
  # Prefer the worktree sentinel; fall back to ART_DIR/BLOCKED.txt which
  # survives worktree removal (written by post.sh's worktree-missing branch).
  local blocked=""
  if [ -f "$WORKTREE_PATH/.committee-loop-BLOCKED.txt" ]; then
    blocked="$WORKTREE_PATH/.committee-loop-BLOCKED.txt"
  elif [ -f "$ART_DIR/BLOCKED.txt" ]; then
    blocked="$ART_DIR/BLOCKED.txt"
  fi
  if [ -n "$blocked" ]; then
    # Fold newlines to "; " so multi-line block reasons (partial-write +
    # branch-moved) survive on a single `BLOCKED:<reason>` output line.
    # awk is used instead of sed because `sed 's/\037.../'` interprets `\037`
    # as a 4-char literal escape (not byte 0x1F) in POSIX BRE, so the prior
    # tr|sed pipeline emitted literal 0x1F bytes instead of `; ` separators.
    echo "BLOCKED:$(awk 'NR>1{printf "; "} {printf "%s", $0}' "$blocked")"
    return 0
  fi
  if [ -f "$WORKTREE_PATH/.committee-loop-EXHAUSTED.txt" ]; then
    echo "EXHAUSTED"
    return 0
  fi
  return 1
}
end=$(( $(date +%s) + 86400 ))
while [ "$(date +%s)" -lt "$end" ]; do
  classify && exit 0
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    sleep 2
    classify && exit 0
    echo "TMUX_DIED"; exit 0
  fi
  sleep 15
done
echo "TIMEOUT"
