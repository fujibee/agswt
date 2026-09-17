#!/usr/bin/env bash
# agswt switch-account — sign a profile into a different account, and say
# what that changes.
#
# Usage:
#   switch-account.sh <profile> [--type claude|codex] [--dirs <root>]... [--timeout <secs>] [--dry-run]
#     <profile>   a name under the profiles root, an absolute path, or "default"
#     --type      which half to switch (default: claude)
#     --dirs      where to look for .envrc bindings (default: ~/projects, if it exists)
#     --timeout   how long to wait for the browser sign-in (default: 300)
#     --dry-run   show the account and the bound directories, then stop before signing in
#
# The assignment of an account to a profile IS the sign-in, so switching is
# signing in again. This script runs the vendor's own login command and waits
# for the browser flow to finish -- measured 2026-09-17 from an agent shell:
# `claude auth login --claudeai` starts a localhost callback server and prints
# "Login successful." once the browser returns, provided the process is still
# alive; `codex login` does the same on port 1455. Nothing here reads or
# writes a credential; the binary does the whole exchange.
#
# What it says before switching is the point: which account is signed in
# now, and which directories are bound to this profile -- because every one of
# them changes account, INCLUDING sessions already running there. Measured
# 2026-09-17, Claude Code 2.1.273: a session started under the old account
# reported the new one in /status right after the switch, with no restart.
# The client reads the credential per request; nothing is held from launch.
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/agswt-common.sh"
CLAUDE_PROFILES="$(agswt_profiles_root)"
CLAUDE_DEFAULT="$HOME/.claude"
CODEX_PROFILES="$(agswt_codex_profiles_root)"
CODEX_DEFAULT="$AGSWT_CODEX_DEFAULT"
AGSWT_VERSION="$(cat "$_here/../VERSION" 2>/dev/null | tr -d '[:space:]')"

note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*"; }
die()   { printf 'switch-account: %s\n' "$*" >&2; exit 2; }
head_() { printf '\n== %s\n' "$*"; }
usage() { sed -n '2,12p' "$0"; }

PROFILE=""; TYPE=claude; ROOTS=(); TIMEOUT=300; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --type|--tool) TYPE="${2:?--type needs claude or codex}"; shift 2
            case "$TYPE" in claude|codex) ;; *) die "--type must be claude or codex, not $TYPE" ;; esac ;;
    --dirs) ROOTS+=("${2:?--dirs needs a directory}"); shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1
$(usage)" ;;
    *) [ -z "$PROFILE" ] || die "got 2 positional arguments ('$PROFILE' then '$1'); only the profile is positional.
$(usage)"
       PROFILE="$1"; shift ;;
  esac
done
printf 'agswt switch-account — version %s\n' "${AGSWT_VERSION:-unknown}"
[ -n "$PROFILE" ] || die "a profile name is required
$(usage)"
[ "${#ROOTS[@]}" -gt 0 ] || { [ -d "$HOME/projects" ] && ROOTS=("$HOME/projects"); }

# ------------------------------------------------------------------ resolve
if [ "$TYPE" = claude ]; then
  case "$PROFILE" in
    /*) DIR="$PROFILE" ;;
    default) DIR="$CLAUDE_DEFAULT" ;;
    *) DIR="$CLAUDE_PROFILES/$PROFILE" ;;
  esac
  VAR=CLAUDE_CONFIG_DIR
  [ -d "$DIR" ] || die "profile not found: $DIR"
else
  DIR="$(agswt_codex_profile_dir "$PROFILE")"
  VAR=CODEX_HOME
  [ -d "$DIR" ] || die "profile not found: $DIR"
fi

# Run a vendor command under this profile. For the Claude DEFAULT directory
# the variable must be unset, not set to the same path (traps.md).
run_as() {
  if [ "$TYPE" = claude ] && [ "$(cd "$DIR" && pwd -P)" = "$(cd "$CLAUDE_DEFAULT" 2>/dev/null && pwd -P)" ]; then
    env -u CLAUDE_CONFIG_DIR "$@"
  else
    env "$VAR=$DIR" "$@"
  fi
}

# Who is signed in, from the binary. Claude: `auth status --json` prints its
# JSON either way and exits 1 when signed out (traps.md). Codex: identity via
# the app server (codex-ask.py), which is the only place the e-mail comes from.
identity() {
  if [ "$TYPE" = claude ]; then
    run_as claude auth status --json </dev/null 2>/dev/null | python3 -c '
import sys, json
try: o = json.load(sys.stdin)
except Exception: print("unknown"); sys.exit()
print(o.get("email") or "(no e-mail)" if o.get("loggedIn") else "signed out")'
  else
    python3 "$_here/codex-ask.py" "$DIR" 2>/dev/null | python3 -c '
import sys, json
try: o = json.loads(sys.stdin.readline())
except Exception: print("unknown"); sys.exit()
print(o.get("email") or ("signed out" if o.get("status") == "not signed in" else o.get("status") or "unknown"))'
  fi
}

head_ "Profile"
note "type    = $TYPE"
note "profile = $DIR"
BEFORE="$(identity)"
note "signed in now: $BEFORE"

# ------------------------------------------------------------- bound dirs
# Every .envrc under the roots is resolved THROUGH direnv, so source_up
# inheritance and shell expansion are direnv's, not a grep's. A directory
# resolving to this profile changes account at its next launch; a directory
# whose parent resolves to it is covered by the parent line.
head_ "Directories bound to this profile"
BOUND=()
if command -v direnv >/dev/null 2>&1 && [ "${#ROOTS[@]}" -gt 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    d="$(dirname "$f")"
    v="$(cd "$d" && direnv exec . sh -c "printf '%s' \"\${$VAR:-}\"" 2>/dev/null)"
    [ -n "$v" ] || continue
    [ "$(cd "$v" 2>/dev/null && pwd -P)" = "$(cd "$DIR" && pwd -P)" ] || continue
    covered=0
    for b in "${BOUND[@]+"${BOUND[@]}"}"; do case "$d/" in "$b"/*) covered=1 ;; esac; done
    [ "$covered" -eq 1 ] || BOUND+=("$d")
  done <<EOF2
$(for r in "${ROOTS[@]}"; do find "$r" -maxdepth 4 -name .envrc -not -path '*/node_modules/*' 2>/dev/null; done | sort)
EOF2
  if [ "${#BOUND[@]}" -gt 0 ]; then
    for b in "${BOUND[@]}"; do note "${b#"$HOME"/}  (and everything under it, relative to ~)"; done
  else
    note "none found under: ${ROOTS[*]}"
  fi
else
  note "not searched (direnv missing or no --dirs); bindings are in .envrc files"
fi
if [ "$TYPE" = claude ] && [ "$DIR" = "$CLAUDE_DEFAULT" ] || [ "$TYPE" = codex ] && [ "$DIR" = "$CODEX_DEFAULT" ]; then
  note "this is the default directory: every directory with no binding uses it too"
fi

# ---------------------------------------------------------------- sign in
if [ "$DRY" -eq 1 ]; then
  head_ "Dry run"
  note "stopping before the sign-in. To switch, run without --dry-run, or yourself:"
  if [ "$TYPE" = claude ]; then note "    ${VAR}=${DIR} claude auth login --claudeai"; else note "    ${VAR}=${DIR} codex login"; fi
  exit 0
fi
head_ "Sign in"
note "A browser window opens; approve with the account you want here."
  note "Waiting up to ${TIMEOUT}s. Every session on this profile follows, running ones included."
if [ "$TYPE" = claude ]; then
  run_as perl -e "alarm $TIMEOUT; exec @ARGV" claude auth login --claudeai </dev/null 2>&1 \
    | grep -vE 'oauth/authorize' | sed 's/^/    /'
  rc=${PIPESTATUS[0]}
else
  run_as perl -e "alarm $TIMEOUT; exec @ARGV" codex login </dev/null 2>&1 | sed 's/^/    /'
  rc=${PIPESTATUS[0]}
fi
if [ "$rc" -eq 142 ]; then
  warn "no browser approval within ${TIMEOUT}s. Run it yourself:"
  if [ "$TYPE" = claude ]; then note "    ${VAR}=${DIR} claude auth login --claudeai"; else note "    ${VAR}=${DIR} codex login"; fi
  exit 1
fi

# ------------------------------------------------------------------ verify
head_ "Result"
AFTER="$(identity)"
note "was: $BEFORE"
note "now: $AFTER"
case "$AFTER" in
  "signed out"|unknown|"not signed in"*) warn "the profile is not signed in — the browser flow did not complete"; exit 1 ;;
esac
if [ "$AFTER" = "$BEFORE" ]; then
  note "same account as before — the browser was approved with the account already signed in"
else
  ok "switched"
fi
if [ "${#BOUND[@]}" -gt 0 ]; then
  printf '\n  Everything under these directories now runs as %s, running sessions included:\n' "$AFTER"
  for b in "${BOUND[@]}"; do printf '    ~/%s\n' "${b#"$HOME"/}"; done
fi
if [ "$TYPE" = claude ]; then
  printf '  (Claude Code re-reads the credential per request: a running session showed\n'
  printf '  the new account in /status without a restart -- measured on 2.1.273.)\n'
else
  printf '  (Codex: a shared app-server need not restart -- a new thread on the same\n'
  printf '  server picked up the new account. An already-open thread is not measured.)\n'
fi
exit 0
