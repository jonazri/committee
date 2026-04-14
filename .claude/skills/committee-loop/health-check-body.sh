# Appended to .committee-loop-health-check.sh after a header written by spawn.sh
# that sets: SESSION, WORKTREE_PATH, ART_DIR, plus `set -u` and shebang.
#
# One-shot health ping: sleeps 270s (4.5m), then classifies the session's state
# at that moment and exits. Exit stdout is surfaced to the outer agent as a
# notification so it can report "still running healthy" vs "dead" vs "already
# finished" to the user. Terminal outcomes are still delivered by the watcher;
# this script only fires the mid-run progress signal.
sleep 270

# Session may have finished before the 4.5m mark — defer to sentinel state
# before interpreting a missing tmux session as a crash.
if [ -f "$ART_DIR/DONE" ]; then
  echo "FINISHED_EARLY:DONE"
  exit 0
fi
if [ -f "$WORKTREE_PATH/.committee-loop-BLOCKED.txt" ] || [ -f "$ART_DIR/BLOCKED.txt" ]; then
  echo "FINISHED_EARLY:BLOCKED"
  exit 0
fi
if [ -f "$WORKTREE_PATH/.committee-loop-EXHAUSTED.txt" ]; then
  echo "FINISHED_EARLY:EXHAUSTED"
  exit 0
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "TMUX_DIED_EARLY"
  exit 0
fi

# Session alive at T+4.5m. Emit pane tail so the outer agent can tell the user
# what the loop is currently doing (e.g. "iter-2 simplify pass", "verifying
# finding X"). Keep the prefix on its own line so the outer agent can pattern-
# match the first line without parsing the pane dump.
echo "HEALTHY"
echo "--- tmux pane (last 40 lines) ---"
tmux capture-pane -t "$SESSION" -p 2>/dev/null | tail -40
