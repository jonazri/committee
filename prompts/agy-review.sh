#!/usr/bin/env bash
# Run one Antigravity (agy) CLI reviewer for committee.
#   Usage: agy-review.sh <mode> <model> <prompt> <out_md> <out_err> <home_base>
#     mode       : auto | read-only
#     model      : agy model id or display name (e.g. gemini-3.5-flash, or the display name "Gemini 3.1 Pro (High)")
#     prompt     : the -p framing string (single argv token; no further escaping needed)
#     out_md     : path for the review output
#     out_err    : path for diagnostics
#     home_base  : per-run dir for the agy HOME redirect (REQUIRED for BOTH auto and read-only — both run
#                  under the deny lockdown; created by the caller via mktemp -d, removed by an
#                  EXIT/INT/TERM trap in the caller)
#   STDIN: the already-<reviewed_content>-fenced material to review.
#
# Contract: on success out_md is non-empty. On ANY failure (setup, auth, agy error, empty
# review INPUT, empty output, non-zero/timeout exit) the helper leaves out_md EMPTY and writes
# the reason to out_err, so the caller's single "is out_md empty?" check is sufficient
# (ran_ok=false). Exits 0 for every review OUTCOME — including fail-closed drops — so a skip is not
# mistaken for a crash. The ONLY non-zero exit is the arity guard (exit 2) for a caller bug (too few
# args): the write-the-reason contract can't be honored without out_err, so that fails loud instead.
#
# agy headlessly auto-acts with NO opt-in flag, and --sandbox does not stop it, so BOTH modes run agy
# under a permissions.deny glob list in a per-run HOME, and NEITHER passes --dangerously-skip-permissions
# (that flag BYPASSES the deny gate — it was the auto-mode hole that let a prompt-injected/plan diff make
# Gemini WRITE files and RUN shell, "execute the plan", 2026-06-23). SECURITY POSTURE (2026-06-23
# decision, supersedes the 2026-06-21 read-only-only posture):
#   * BOTH modes DENY writes (write_file/edit_file/replace) and shell (command/run_command) — a reviewer
#     never writes or executes. Reliably blocked by catch-all tool(*) globs (verified).
#   * Read-only ADDITIONALLY denies the network/URL exfil tools (read_url/fetch/web_search/browser_action)
#     for untrusted content; auto ALLOWS them (trusted content — the reviewer may consult the web). Auto
#     STILL cannot touch the repo (writes/shell are denied above in both modes).
#   * BOTH modes DELIBERATELY ALLOW file reads (read_file/view_file/grep_search/list_dir) so a reviewer
#     can consult repo context. agy's reads are NOT filesystem-confined (it reads /etc/passwd and
#     out-of-repo paths) and agy's path-globs cannot scope reads (only catch-all tool(*), all-or-nothing;
#     `allow` cannot override `deny` — all verified), so we CANNOT confine reads to the repo without
#     disabling them entirely. ACCEPTED RISK: a prompt-injected diff can make a reviewer read local files
#     (incl. ~/.gemini OAuth creds) and echo them into the review output — read-only closes the network
#     exfil channel but NOT the review-output channel, so it is NOT exfil-safe. Prefer auto only for
#     trusted content; treat read-only as best-effort for untrusted content. See spec §3/§6 + CLAUDE.md.
# Mutable auth/state is COPIED (not symlinked) into a per-run HOME so concurrent runs never write
# through to the real ~/.gemini (CONCURRENCY isolation — the per-run HOME is NOT a credential boundary,
# since reads are unconfined: the real ~/.gemini creds are reachable regardless of where the copy lives).
set -u

# Arity guard BEFORE dereferencing $1..$5 — `set -u` would otherwise abort with a cryptic
# "unbound variable" on a too-few-args call instead of a clear usage error. out_md/out_err are
# required to honor the write-the-reason contract (we cannot write a reason without out_err).
# home_base ($6) is now required by BOTH the auto and read-only branches (each checks $home_base and
# drops fail-closed if empty), but the arity guard still allows a 5-arg call so that drop path — not a
# cryptic `set -u` abort — handles a missing home_base. Callers always pass 6, so this is defensive.
if [ "$#" -lt 5 ]; then
  echo "agy-review: usage: agy-review.sh <mode> <model> <prompt> <out_md> <out_err> <home_base> (got $# args; home_base is required for both modes — a missing one drops the reviewer fail-closed)" >&2
  exit 2
fi
mode=$1; model=$2; prompt=$3; out_md=$4; out_err=$5; home_base=${6:-}
: > "$out_md"; : > "$out_err"

# Buffer stdin and GUARD against an empty review body. A missing/empty diff yields an empty
# <reviewed_content> fence; agy may emit prose ("nothing to review") for empty input and exit 0,
# which the caller's empty-check would mistake for a real review. Strip the fence tags + all
# whitespace; if nothing remains, drop fail-closed WITHOUT invoking agy (deterministic drop on a
# missing-diff infrastructure failure, not a bogus review).
input=$(cat)
body=$(printf '%s' "$input" | sed -e 's#</\{0,1\}reviewed_content>##g' | tr -d '[:space:]')
if [ -z "$body" ]; then
  echo "agy-review: empty review input (fenced body had no content — missing/empty diff) — reviewer dropped" > "$out_err"
  exit 0
fi

cx=0
if [ "$mode" = "read-only" ] || [ "$mode" = "auto" ]; then
  # BOTH modes run agy under a per-run HOME + permissions.deny lockdown, and NEITHER passes
  # --dangerously-skip-permissions: that flag BYPASSES the deny gate, and was the auto-mode hole that let
  # a prompt-injected/plan diff make Gemini WRITE files and RUN shell ("execute the plan", 2026-06-23). A
  # reviewer never needs to write or execute, so writes+shell are denied in BOTH modes (see deny list
  # below). BOTH modes therefore REQUIRE a non-empty home_base ($6): the deny lockdown + copied auth live
  # under it, and an empty value would build filesystem-root paths. Drop fail-closed with a clear reason
  # rather than relying on the cwd-containment check below to catch it implicitly (it does — `cd ""` stays
  # in cwd — but an explicit guard is clearer and not shell-behavior-dependent).
  if [ -z "$home_base" ]; then
    echo "agy-review: $mode mode requires a non-empty home_base (\$6) — reviewer dropped" > "$out_err"
    exit 0
  fi
  deny="$home_base/.gemini/antigravity-cli/settings.json"
  # Hygiene: keep the per-run HOME out of the repo working tree (cwd = projectRoot in production) so a
  # per-run state dir never pollutes cwd / git status — run this FIRST, before writing ANY state (deny
  # file / copied auth), so the refusal truly fires before anything lands under cwd. (Under the
  # accept-reads posture this is NOT a credential boundary — reads are unconfined — but a HOME under cwd
  # is still undesirable.) home_base is created by the caller (mktemp -d) in production; create it if
  # absent so `cd` can resolve its real path. (On the refusal path only this empty dir exists; the
  # caller's trailing `rm -rf` removes it.)
  mkdir -p "$home_base" 2>/dev/null
  if homerp=$(cd "$home_base" && pwd -P) && cwdrp=$(pwd -P); then
    case "$homerp/" in
      "$cwdrp"/*) echo "agy-review: per-run HOME ($homerp) is INSIDE cwd ($cwdrp) — refusing to place per-run state under the repo; reviewer dropped (set TMPDIR outside the repo)" > "$out_err"; exit 0 ;;
    esac
  fi
  # The deny block is the load-bearing control: writes+shell in BOTH modes, plus network in read-only.
  # enableTelemetry/showFeedbackSurvey mirror the real ~/.gemini/antigravity-cli/settings.json so a fresh
  # HOME never emits survey/telemetry text into the review output.
  # DENIED in BOTH modes: write_file/edit_file/replace (writes), command/run_command (shell).
  # NOT denied in either mode: read_file/view_file/grep_search/list_dir — reads are deliberately allowed
  # (accepted risk; see the header). The base list is one of THREE copies that must stay in sync: here,
  # spec §2, and Verified Fact #5 — update all three together when adding/removing a tool name.
  base_deny='"write_file(*)","edit_file(*)","replace(*)","command(*)","run_command(*)"'
  # read-only ADDS the network/URL exfil tools (read_url/fetch/web_search/browser_action — spec §7 #6(c));
  # auto OMITS them (a trusted-content reviewer may consult the web), but auto STILL cannot touch the repo.
  if [ "$mode" = "read-only" ]; then
    deny_list="$base_deny,\"read_url(*)\",\"fetch(*)\",\"web_search(*)\",\"browser_action(*)\""
  else
    deny_list="$base_deny"
  fi
  if ! { mkdir -p "$home_base/.gemini/antigravity-cli" \
        && printf '{"enableTelemetry":false,"showFeedbackSurvey":false,"permissions":{"deny":[%s]}}' "$deny_list" > "$deny" \
        && [ -s "$deny" ]; }; then
    echo "agy-review: $mode lockdown setup failed (deny file not written) — reviewer dropped" > "$out_err"
    exit 0
  fi
  # Copy mutable auth/state into the per-run home (concurrent-safe; real ~/.gemini never written).
  # settings.json carries gemini's auth selectedType; both installation_id files (top-level +
  # antigravity-cli) are copied so agy treats the per-run HOME as an established, signed-in
  # install. The §7 #1 smoke test ("produced output (auth OK)") is the arbiter that this set
  # is complete — add gemini-credentials.json / config/ there if it ever fails.
  # NOT copied: trustedFolders.json — a fresh per-run HOME inherits no workspace-trust; if agy ever
  # needs one, write a minimal projectRoot-only trust file rather than copying the real one.
  for f in oauth_creds.json google_accounts.json installation_id state.json settings.json; do
    [ -e "$HOME/.gemini/$f" ] && cp -p "$HOME/.gemini/$f" "$home_base/.gemini/$f"
  done
  for f in antigravity-oauth-token installation_id; do
    [ -e "$HOME/.gemini/antigravity-cli/$f" ] && cp -p "$HOME/.gemini/antigravity-cli/$f" "$home_base/.gemini/antigravity-cli/$f"
  done
  # Symlink only the large, immutable builtin assets.
  ln -sfn "$HOME/.gemini/antigravity-cli/builtin" "$home_base/.gemini/antigravity-cli/builtin" 2>/dev/null || true
  printf '%s\n' "$input" | HOME="$home_base" timeout -k 30 240 agy -p "$prompt" --model "$model" > "$out_md" 2> "$out_err"; cx=$?
else
  # Fail closed: never fall through to the privileged path on an unrecognized mode.
  echo "agy-review: unknown mode '$mode' (expected auto|read-only) — reviewer dropped" > "$out_err"
  exit 0
fi
# Non-zero/timeout agy exit -> empty out_md so the caller's single empty-check fires even when
# agy crashed after writing partial output (the "OR non-zero exit" half of the contract).
if [ "$cx" -ne 0 ]; then
  : > "$out_md"
  echo "agy exited non-zero ($cx)" >> "$out_err"
elif [ ! -s "$out_md" ]; then
  # Exit 0 but EMPTY output (agy ran, produced no review): honor the contract's "empty output ->
  # reason in out_err" promise so a consumer always has a diagnostic, not just on non-zero exit.
  echo "agy exited 0 but produced empty output — no review (auth/quota/capacity, or a read-only skip)" >> "$out_err"
fi
exit 0
