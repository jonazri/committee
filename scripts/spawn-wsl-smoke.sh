#!/usr/bin/env bash
# Hermetic smoke for spawn.sh's startup handling and its Windows -> WSL hop, driving the
# real spawn.sh with a stub `claude` TUI, a throwaway origin repo/HOME and a private tmux
# socket (COMMITTEE_JOB_BOUNDS=off: no systemd scopes). The hop is simulated with stub
# `uname` (MINGW), `cygpath` and `wsl.exe`. Asserts: folder-trust prompt confirmed only on
# "Yes" (including when early keys are dropped); the Bypass Permissions disclaimer is never
# answered; reviewer-CLI preflight follows --models; the hop carries --models verbatim,
# COMMITTEE_* settings and the host core.autocrlf (no CRLF seed commit), and stamps RUNNER.
# Requires Linux, tmux, git, node.
# Mirrors scripts/headroom-launch-smoke.sh's note()/check()/exit "$fail" convention.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SPAWN="$HERE/../.claude/skills/committee-loop/spawn.sh"
fail=0
note()  { printf '%s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then note "PASS: $3"; else note "FAIL: $3 (got: $1 | want: $2)"; fail=1; fi; }
for t in tmux git node; do command -v "$t" >/dev/null 2>&1 || { note "SKIP: $t not available"; exit 0; }; done

TMP=$(mktemp -d)
SOCK="committee-wsl-smoke-$$"
REAL_PATH="/usr/bin:/bin"; NODE=$(command -v node)
cleanup() {
  command tmux -L "$SOCK" kill-server 2>/dev/null
  for wt in "$TMP"/origin-committee-loop-*; do
    [ -d "$wt" ] && git -C "$TMP/origin" worktree remove --force "$wt" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/plugins/ralph-loop" "$HOME/.claude/skills/committee" \
  "$HOME/.claude/plugins/superpowers/skills/receiving-code-review" "$TMP/bin" "$TMP/winbin"
for t in codex agy; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"; chmod +x "$TMP/bin/$t"; done
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = --help ] && { echo "  --effort <level>"; exit 0; }
mode=$(cat "$HOME/stub-mode" 2>/dev/null || echo ready)
echo "${GIT_CONFIG_COUNT-unset} $(git config --get core.autocrlf || echo none)" > .stub-git-env
log="$HOME/stub-keys.log"
ready() {
  stty sane 2>/dev/null
  printf '\033[2J\033[Hbypass permissions on\n'
  while IFS= read -r line || sleep 1; do
    printf '\033[2J\033[H'; [ -n "$line" ] && printf '[Pasted text #1]\n'; printf 'bypass permissions on\n'
  done
}
menu() {  # menu <first label> <second label> <cursor 0|1> <index of accept option> [refuse secs]
  local a=$1 b=$2 cur=$3 ok=$4 refuse=${5:-0} k rest start=$SECONDS
  draw() { printf '\033[2J\033[H Do you trust the files in this folder?\n'
    if [ "$cur" = 0 ]; then printf ' ❯ %s\n   %s\n' "$a" "$b"; else printf '   %s\n ❯ %s\n' "$a" "$b"; fi; }
  stty -echo -icanon min 1 2>/dev/null; draw
  while IFS= read -rsn1 k; do
    if [ $((SECONDS - start)) -lt "$refuse" ]; then [ "$k" = $'\e' ] && read -rsn2 rest; echo "DROPPED" >> "$log"; continue; fi
    if [ "$k" = $'\e' ]; then read -rsn2 rest; echo "ESC$rest" >> "$log"
      [ "$rest" = '[B' ] && cur=1; [ "$rest" = '[A' ] && cur=0; draw; continue; fi
    echo "KEY:$(printf %q "$k")" >> "$log"
    if [ -z "$k" ]; then [ "$cur" = "$ok" ] && ready; echo "EXIT on cursor $cur" >> "$log"; exit 3; fi
  done
}
case "$mode" in
  ready) ready ;;
  trust-cancel-first) menu "No, exit" "Yes, I trust this folder" 0 1 ;;
  trust-refuse) menu "No, exit" "Yes, I trust this folder" 0 1 2 ;;
  trust-yes-first) menu "Yes, I trust this folder" "No, exit" 0 0 ;;
  disclaimer)
    stty -echo -icanon min 1 2>/dev/null
    printf '\033[2J\033[HWARNING: Claude Code running in Bypass Permissions mode\n ❯ 1. No, exit\n   2. Yes, I accept\n'
    while IFS= read -rsn1 k; do echo "KEY:$(printf %q "$k")" >> "$log"; done ;;
esac
STUB
chmod +x "$TMP/bin/claude"; ln -s "$NODE" "$TMP/bin/node"
printf '#!/bin/sh\nexit 0\n' > "$TMP/kiro-cli"; chmod +x "$TMP/kiro-cli"

# Windows simulation: uname says MINGW; cygpath -w tags a path; wsl.exe untags it (wslpath)
# or runs the -lc command under the Linux PATH (no uname stub), recording argv.
printf '#!/bin/sh\n[ "$1" = -s ] && { echo MINGW64_NT-10.0-26100; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$TMP/winbin/uname"
printf '#!/bin/sh\n[ "$1" = -w ] && { printf "W:%%s\\n" "$2"; exit 0; }\nexit 9\n' > "$TMP/winbin/cygpath"
cat > "$TMP/winbin/wsl.exe" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$HOME/wsl-argv.\$\$"
[ "\$1" = -e ] || exit 9; shift
case "\$1" in
  wslpath) [ "\$2" = -a ] && printf '%s\r\n' "\${3#W:}" ;;
  bash) [ "\$2" = -lc ] || exit 8; printf '%s' "\$3" > "\$HOME/wsl-cmd"
        exec env -u GIT_CONFIG_GLOBAL PATH="$TMP/bin:$REAL_PATH" MSYS_NO_PATHCONV= bash -lc "\$3" ;;
  *) exit 7 ;;
esac
STUB
chmod +x "$TMP/winbin/uname" "$TMP/winbin/cygpath" "$TMP/winbin/wsl.exe"

export COMMITTEE_HEADROOM=off COMMITTEE_LOOP_SOCKET="$SOCK" COMMITTEE_JOB_BOUNDS=off COMMITTEE_MAX_JOBS=50
ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN"
git -C "$ORIGIN" config user.name e2e; git -C "$ORIGIN" config user.email e2e@example.invalid
mkdir -p "$ORIGIN/docs"
for f in a b c d e f g h; do echo "# $f" > "$ORIGIN/docs/$f.md"; done
git -C "$ORIGIN" add -A; git -C "$ORIGIN" commit -qm base

run() {  # run <mode> <PATH> <out> <spawn args...>
  local mode=$1 path=$2 out=$3; shift 3; command tmux -L "$SOCK" kill-server 2>/dev/null; rm -f "$HOME"/wsl-cmd
  echo "$mode" > "$HOME/stub-mode"; : > "$HOME/stub-keys.log"
  (cd "$ORIGIN" && PATH="$path" bash "$SPAWN" "$@") > "$out" 2> "$out.err"
}
mval() { grep "^$2=" "$1" | head -1 | cut -d= -f2-; }
worktrees() { git -C "$ORIGIN" worktree list | wc -l; }
P_ALL="$TMP/bin:$REAL_PATH"
ln -s "$TMP/kiro-cli" "$TMP/bin/kiro-cli"

# 1. plain native spawn
run ready "$P_ALL" "$TMP/m1" docs/a.md; check "$?" 0 "native spawn (ready TUI) succeeds"
check "$(mval "$TMP/m1" RUNNER)" native "manifest RUNNER=native without the hop"

# 2. trust prompt, legacy order (Yes focused)
run trust-yes-first "$P_ALL" "$TMP/m2" docs/b.md; check "$?" 0 "trust prompt with Yes focused is confirmed"

# 3. trust prompt, Claude Code 2.1.310 order (cancelFirst, focus cancel)
run trust-cancel-first "$P_ALL" "$TMP/m3" docs/c.md; check "$?" 0 "trust prompt with 'No, exit' focused: moves to Yes, confirms"

# 3b. trust prompt that drops keys sent within 2s of rendering
run trust-refuse "$P_ALL" "$TMP/m3b" docs/c.md; check "$?" 0 "trust prompt that drops early keys is still confirmed on Yes"

# 4. bypass-permissions disclaimer is never answered
before=$(worktrees)
run disclaimer "$P_ALL" "$TMP/m4" docs/d.md; check "$?" 1 "Bypass Permissions disclaimer aborts the spawn"
grep -q 'disclaimer has not been accepted' "$TMP/m4.err"; check "$?" 0 "disclaimer abort explains the one-time operator step"
check "$(wc -c < "$HOME/stub-keys.log" | tr -d ' ')" 0 "no key sent to the disclaimer"
check "$(worktrees)" "$before" "worktree torn down after disclaimer abort"

# 5. reviewer preflight
rm "$TMP/bin/kiro-cli"
run ready "$P_ALL" "$TMP/m5" docs/e.md; check "$?" 1 "kiro-cli absent, kiro enabled: preflight fails"
grep -q 'missing tool: kiro-cli' "$TMP/m5.err"; check "$?" 0 "preflight names the missing reviewer CLI"
run ready "$P_ALL" "$TMP/m6" --models '{"reviewers":{"kiro":{"enabled":false}}}' docs/e.md; check "$?" 0 "kiro-cli absent, kiro disabled: spawn proceeds"
ln -s "$TMP/kiro-cli" "$TMP/bin/kiro-cli"

# 6. simulated Git Bash -> WSL hop with --models JSON
JSON='{"reviewers":{"kiro":{"enabled":false},"gemini-pro":{"model":"g-4.x_y"}},"innerAgent":{"effort":"high"}}'
run ready "$TMP/winbin:$P_ALL" "$TMP/m8" --models "$JSON" docs/g.md; check "$?" 0 "simulated MINGW spawn hops into WSL"
if [ -s "$HOME/wsl-cmd" ]; then
  check "$(mval "$TMP/m8" RUNNER)" wsl "manifest RUNNER=wsl after hop"
  WT=$(mval "$TMP/m8" WORKTREE_PATH)
  check "$(cat "$WT/.committee-loop-models.json" 2>/dev/null)" "$JSON" "--models JSON survives the hop byte-for-byte"
else
  note "FAIL: no hop recorded; stderr: $(head -3 "$TMP/m8.err" | tr '\n' ' ')"; fail=1
fi

# 7. hop carries COMMITTEE_* and the Windows-side core.autocrlf (invisible to WSL git)
printf 'line1\nline2\n' > "$ORIGIN/docs/crlf.md"; git -C "$ORIGIN" add docs/crlf.md; git -C "$ORIGIN" commit -qm crlf
printf 'line1\r\nline2\r\n' > "$ORIGIN/docs/crlf.md"
printf '[core]\n\tautocrlf = true\n' > "$TMP/wingit"
GIT_CONFIG_GLOBAL="$TMP/wingit" run ready "$TMP/winbin:$P_ALL" "$TMP/m9" docs/crlf.md; check "$?" 0 "hop with Windows-side core.autocrlf=true"
grep -q 'COMMITTEE_MAX_JOBS=50' "$HOME/wsl-cmd"; check "$?" 0 "COMMITTEE_MAX_JOBS forwarded across the hop"
grep -q 'GIT_CONFIG_VALUE_0=true' "$HOME/wsl-cmd"; check "$?" 0 "host core.autocrlf forwarded across the hop"
B9=$(mval "$TMP/m9" BRANCH)
check "$(git -C "$ORIGIN" cat-file -p "$B9:docs/crlf.md" | grep -c $'\r')" 0 "loop branch keeps LF blobs (no CRLF seed commit)"
check "$(git -C "$ORIGIN" log --format=%s main.."$B9" | grep -c '^seed:')" 0 "no seed commit for a line-ending-only difference"
git -C "$ORIGIN" config core.autocrlf false
GIT_CONFIG_GLOBAL="$TMP/wingit" run ready "$TMP/winbin:$P_ALL" "$TMP/m10" docs/h.md; check "$?" 0 "hop with repo-local core.autocrlf=false"
grep -q 'GIT_CONFIG_' "$HOME/wsl-cmd"; check "$?" 1 "repo-local core.autocrlf keeps precedence (not overridden)"
git -C "$ORIGIN" config --unset core.autocrlf
git -C "$ORIGIN" config extensions.worktreeConfig true; git -C "$ORIGIN" config --worktree core.autocrlf false
GIT_CONFIG_GLOBAL="$TMP/wingit" run ready "$TMP/winbin:$P_ALL" "$TMP/m19" docs/h.md; check "$?" 0 "hop with worktree-scoped core.autocrlf=false"
grep -q 'GIT_CONFIG_' "$HOME/wsl-cmd"; check "$?" 1 "worktree-scoped core.autocrlf keeps precedence (not overridden)"
git -C "$ORIGIN" config --worktree --unset core.autocrlf; git -C "$ORIGIN" config --unset extensions.worktreeConfig

# 7b. a job started on a server another job created gets its own git overrides, not the server's
GIT_CONFIG_GLOBAL="$TMP/wingit" run ready "$TMP/winbin:$P_ALL" "$TMP/m14" docs/a.md
echo ready > "$HOME/stub-mode"
(cd "$ORIGIN" && GIT_CONFIG_COUNT=0 PATH="$P_ALL" bash "$SPAWN" docs/b.md) > "$TMP/m15" 2> "$TMP/m15.err"
check "$?" 0 "second job spawned on the running tmux server"
check "$(cat "$(mval "$TMP/m14" WORKTREE_PATH)/.stub-git-env")" "1 true" "hop job's inner claude sees the host core.autocrlf"
check "$(cat "$(mval "$TMP/m15" WORKTREE_PATH)/.stub-git-env")" "0 none" "second job on that server gets its own git overrides, not the first job's"

# 7c. a Git-for-Windows linked worktree (gitdir: C:/...) is rejected before the hop
git -C "$ORIGIN" worktree add -q "$TMP/winwt" -b winwt
printf 'gitdir: C:/Users/me/origin/.git/worktrees/winwt\n' > "$TMP/winwt/.git.win"
mv "$TMP/winwt/.git" "$TMP/winwt/.git.real"; mv "$TMP/winwt/.git.win" "$TMP/winwt/.git"
rm -f "$HOME/wsl-cmd"; echo ready > "$HOME/stub-mode"
(cd "$TMP/winwt" && GIT_DIR="$TMP/winwt/.git.real" GIT_WORK_TREE="$TMP/winwt" PATH="$TMP/winbin:$P_ALL" bash "$SPAWN" docs/a.md) > "$TMP/m18" 2> "$TMP/m18.err"
check "$?" 1 "Git-for-Windows linked worktree rejected"
grep -q 'linked worktree created by Git for Windows' "$TMP/m18.err"; check "$?" 0 "rejection explains the primary-checkout / WSL-worktree alternative"
check "$([ -e "$HOME/wsl-cmd" ] && echo hopped || echo none)" none "no WSL hop attempted for it"
mv "$TMP/winwt/.git.real" "$TMP/winwt/.git"

# 8. --models validation
run ready "$P_ALL" "$TMP/m11" --models '{"reviewers":{"KIRO":{"enabled":false}}}' docs/h.md; check "$?" 1 "non-lowercase reviewer key rejected"
run ready "$P_ALL" "$TMP/m12" --models '{"reviewers":{"claude":{"enabled":false},"codex":{"enabled":false},"kiro":{"enabled":false},"gemini":{"enabled":false},"gemini-pro":{"enabled":false}}}' docs/h.md; check "$?" 1 "--models disabling every reviewer rejected"
run ready "$P_ALL" "$TMP/m13" --models '{"reviewers":{"claude":{"enabled":false},"codex":{"enabled":false},"kiro":{"enabled":false},"gemini":{"enabled":false},"gemini-pro":{"enabled":false},"fable":{"enabled":true}}}' docs/h.md; check "$?" 1 "--models with only fable enabled rejected (no quorum, no iter-1 reviewer)"
run ready "$P_ALL" "$TMP/m16" --models '{"reviewers":{"claude":{"enabled":false},"codex":{"enabled":false},"kiro":{"enabled":false}}}' docs/h.md; check "$?" 1 "--models leaving only gemini reviewers rejected (no iter-1 reviewer)"
run ready "$P_ALL" "$TMP/m17" --models '{"reviewers":{"codex":{"enabled":false},"kiro":{"enabled":false},"gemini-pro":{"enabled":false}}}' docs/h.md; check "$?" 0 "--models with claude + gemini accepted"

[ "$fail" = 0 ] && note "ALL WSL-SMOKE CHECKS PASSED" || note "WSL-SMOKE CHECKS FAILED"
exit "$fail"
