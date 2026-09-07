#!/usr/bin/env bash
# agswt doctor — check the failure modes in references/traps.md.
#
# Read-only. Prints findings and exits non-zero if anything needs a human.
#
# Usage: doctor.sh [directory]     (defaults to the current directory)
set -uo pipefail

DIR="${1:-$PWD}"
# The version ships INSIDE the skill directory, because that is what the skills
# CLI copies to an install. Read only -- bumping is a release step, not this
# script's business. An absent file is reported, never passed over in silence:
# "unknown" is a fact about the install worth seeing.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/agswt-common.sh"
CLAUDE_PROFILES="$(agswt_profiles_root)"
CODEX_PROFILES="$(agswt_codex_profiles_root)"
CODEX_DEFAULT="$AGSWT_CODEX_DEFAULT"
PROFILES_ROOT_OK=1
[ -d "$CLAUDE_PROFILES" ] || PROFILES_ROOT_OK=0
AGSWT_VERSION="$(cat "$_here/../VERSION" 2>/dev/null | tr -d '[:space:]')"
printf 'agswt doctor — version %s\n' "${AGSWT_VERSION:-unknown}"
CLAUDE_DEFAULT="$HOME/.claude"

problems=0
note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*"; problems=$((problems + 1)); }
head_() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- resolution

head_ "Resolution in $DIR"

resolve() {
  # direnv is optional. Without it, report the ambient environment instead of
  # pretending the directory has no binding.
  local var="$1"
  if command -v direnv >/dev/null 2>&1 && [ -f "$DIR/.envrc" ]; then
    (cd "$DIR" && direnv exec . sh -c "printf '%s' \"\${$var:-}\"" 2>/dev/null)
  else
    printf '%s' "${!var:-}"
  fi
}

ccd="$(resolve CLAUDE_CONFIG_DIR)"
note "CLAUDE_CONFIG_DIR = ${ccd:-<unset, using ~/.claude>}"
ch="$(resolve CODEX_HOME)"
note "CODEX_HOME        = ${ch:-<unset, using ~/.codex>}"
# Unlike CLAUDE_CONFIG_DIR, pointing CODEX_HOME at its own default is harmless
# (measured 2026-09-05, codex-cli 0.153.4: identical answer to unset), so no
# warning for that case here.
if [ -n "$ch" ] && [ ! -d "$ch" ]; then
  warn "CODEX_HOME points at $ch, which does not exist. Codex will create an empty, signed-out home there on first launch."
elif [ -n "$ch" ] && ! agswt_is_codex_profile "$ch"; then
  warn "CODEX_HOME points at $ch, which holds neither auth.json nor config.toml — not a profile, and not signed in."
fi

# Setting the variable explicitly to the default path is NOT a no-op: the client
# then looks for the hashed keychain item, which only exists for non-default
# dirs, and reports a null identity for a perfectly good account.
if [ -n "$ccd" ] && [ "$(cd "$ccd" 2>/dev/null && pwd -P)" = "$(cd "$CLAUDE_DEFAULT" 2>/dev/null && pwd -P)" ]; then
  warn "CLAUDE_CONFIG_DIR points at the default ~/.claude. Unset it instead — setting it explicitly makes the client look for a hashed keychain item that does not exist for the default dir."
fi

# A nested .envrc replaces its parent wholesale unless it starts with source_up.
if [ -f "$DIR/.envrc" ]; then
  parent="$(cd "$DIR/.." 2>/dev/null && pwd -P)"
  while [ -n "$parent" ] && [ "$parent" != "/" ]; do
    if [ -f "$parent/.envrc" ]; then
      if ! grep -qE '^[[:space:]]*source_up' "$DIR/.envrc"; then
        warn ".envrc here has a parent at $parent/.envrc but no source_up — the parent's bindings are being discarded."
      else
        ok ".envrc chains to its parent via source_up"
      fi
      break
    fi
    parent="$(dirname "$parent")"
  done
fi

# ------------------------------------------------------------------- direnv

head_ "direnv"
# Three separate ways this is broken, so three separate lines: the binary can
# be absent, present-but-unhooked, or hooked with this directory not allowed.
# They need different fixes and one combined verdict would hide which.
if ! command -v direnv >/dev/null 2>&1; then
  warn "direnv is not installed. Directory-scoped profiles need it: brew install direnv (or apt), then add  eval \"\$(direnv hook zsh)\"  to your rc file."
else
  ok "direnv installed ($(direnv version 2>/dev/null || echo 'version unknown'))"

  # The hook is what makes an interactive shell read .envrc at all. It cannot
  # be probed with `direnv exec`, which loads the file directly and bypasses
  # the hook -- so a tool that checks itself this way reports success on a
  # shell where nothing is ever loaded. Grepping the rc files is an
  # approximation and is labelled as one.
  hook_seen=""
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.config/fish/config.fish"; do
    [ -f "$rc" ] || continue
    grep -q 'direnv hook' "$rc" 2>/dev/null && hook_seen="${hook_seen}${hook_seen:+, }$rc"
  done
  if [ -n "$hook_seen" ]; then
    ok "direnv hook found in $hook_seen (approximate — confirm with: direnv status)"
  else
    warn "no 'direnv hook' line found in your rc files. Without it .envrc is never loaded in an interactive shell. Add  eval \"\$(direnv hook zsh)\"  and confirm with: direnv status"
  fi

  # And this directory specifically: a correct .envrc that was never allowed
  # is inert, and looks identical to no .envrc at all from the outside.
  if [ -f "$DIR/.envrc" ]; then
    # `direnv status` prints TWO "RC allowed" lines: one for the rc it has
    # LOADED (which is whatever the surrounding shell had) and one for the rc
    # it FOUND here. Only the second describes this directory.
    #
    # And the value is a status code, not a boolean: 0 means allowed, non-zero
    # means it is not. Read as a boolean -- and matched against either line --
    # the check called an un-allowed directory allowed, which is the answer
    # that lets a broken binding look finished.
    allowed_line="$(cd "$DIR" && direnv status 2>/dev/null | grep '^Found RC allowed' | head -1)"
    case "$allowed_line" in
      "Found RC allowed 0") ok ".envrc here is allowed" ;;
      "") warn "could not read 'direnv status' for $DIR" ;;
      *)  warn "$DIR/.envrc is NOT allowed ($allowed_line), so it is not in effect. Run: direnv allow $DIR" ;;
    esac
  else
    note "no .envrc here (this directory is not bound to a profile)"
  fi
fi

# ----------------------------------------------------------- session context

if [ "$(uname -s)" = "Darwin" ]; then
  head_ "Session context"
  mgr="$(launchctl managername 2>/dev/null || echo unknown)"
  if [ "$mgr" = "Aqua" ]; then
    ok "GUI session ($mgr) — keychain reads can prompt"
  else
    warn "launchctl managername reports '$mgr'. Outside a GUI session there is no Security Agent, so every keychain read fails with errSecInteractionNotAllowed no matter what is unlocked. Run this from a real terminal."
  fi

  # ------------------------------------------------------------------ keychain

  head_ "Keychain"
  # NOT PROBED, on purpose. Earlier versions read an unrelated item's secret
  # (`security find-generic-password -s AirPort -w`) to see whether the login
  # keychain was locked: exit 36 meant locked. That item lives in the SYSTEM
  # keychain, so on an UNLOCKED machine the same command raised an
  # administrator-password dialog ("security wants to use the System
  # keychain") and hung this script for as long as nobody answered it --
  # measured 2026-09-05. A check that is silent in the broken state and
  # prompts for admin in the healthy one is worse than no check. And there is
  # no prompt-free way to ask: `security show-keychain-info` reports timeout
  # settings, not lock state, and every secret read can prompt.
  note "lock state is not probed (every way to ask can raise a password dialog)"
  note "if report shows EVERY account signed out at once, the keychain is locked:"
  note "  security unlock-keychain ~/Library/Keychains/login.keychain-db"
fi

# ------------------------------------------------------------------ profiles

head_ "Profiles"

list_dirs() { [ -d "$1" ] && find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true; }

# ONE RULE for what a profile is, shared with report: a directory holding
# .claude.json IS one; a directory without one is a group whose children are
# searched. Both can be true at once -- a group that is itself signed in --
# and that needs no case of its own. Structured names ("work/acme") fall out of
# it, so nothing here has to know which names are groups.
#
# A profile's OWN subdirectories are skipped: descending into them reaches
# 130+ plugin and marketplace directories, which is not where a sibling
# profile lives. Depth is capped against a symlink loop, and hitting the cap
# is reported rather than quietly truncating the account list.
AGSWT_MAX_DEPTH="${AGSWT_MAX_DEPTH:-4}"
_depth_hits=""
list_profiles() {
  local dir="$1" depth="${2:-1}" sub
  if [ "$depth" -gt "$AGSWT_MAX_DEPTH" ]; then
    _depth_hits="${_depth_hits}${_depth_hits:+ }${dir}"
    return 0
  fi
  # .claude.json alone does not make a profile: the client writes one wherever
  # it runs. oauthAccount is what separates an account's container from the
  # footprint of a command that happened to execute there. A group with no
  # account is not listed and is never told to sign in; an intended profile
  # that has not signed in still is.
  local kids has_acct=1
  kids="$(find "$dir" -mindepth 2 -maxdepth 2 -name .claude.json 2>/dev/null | head -1)"
  grep -q '"oauthAccount"' "$dir/.claude.json" 2>/dev/null || has_acct=0
  if [ -f "$dir/.claude.json" ] && { [ "$has_acct" -eq 1 ] || [ -z "$kids" ]; }; then
    printf '%s\n' "$dir"
  fi
  while IFS= read -r sub; do
    [ -n "$sub" ] && list_profiles "$sub" "$((depth + 1))"
  done <<INNER
$(find "$dir" -mindepth 1 -maxdepth 1 -type d \
    ! -name projects ! -name memory ! -name plugins ! -name skills \
    ! -name commands ! -name todos ! -name statsig ! -name shell-snapshots \
    ! -name backups ! -name sessions ! -name '.*' 2>/dev/null | sort)
INNER
}
all_profiles() {
  local root="$1" d
  [ -d "$root" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] && list_profiles "$d" 1
  done <<OUTER
$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
OUTER
}
# Label a profile the way a person names it: its path under the profiles root.
prof_label() {
  case "$1" in
    "$CLAUDE_PROFILES"/*) printf '%s' "${1#"$CLAUDE_PROFILES"/}" ;;
    *) basename "$1" ;;
  esac
}

found_any=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  found_any=1
  name="$(prof_label "$p")"
  if [ -f "$p/settings.json" ] || [ -d "$p/projects" ]; then
    # A symlinked settings.json survives until the client next writes, then
    # silently becomes a private copy.
    if [ -L "$p/settings.json" ]; then
      warn "claude/$name: settings.json is a symlink. It is rewritten with temp-file-and-rename, so the link will be replaced by a real file. Use a copy."
    fi
    n_ws=$(list_dirs "$p/projects" | wc -l | tr -d ' ')
    note "claude/$name — $n_ws workspace(s)"
  fi
done <<EOF
$(all_profiles "$CLAUDE_PROFILES")
EOF


# Codex profiles: the default home plus the Codex root. Discovery is the
# shared rule in agswt-common.sh, so this list is the one report prints.
codex_label() {
  case "$1" in
    "$CODEX_DEFAULT") printf '(default)' ;;
    "$CODEX_PROFILES"/*) printf '%s' "${1#"$CODEX_PROFILES"/}" ;;
    *) basename "$1" ;;
  esac
}
found_codex=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  found_codex=1
  name="$(codex_label "$p")"
  if [ -f "$p/auth.json" ]; then
    # The credential is plaintext. Codex writes it 0600; a copy made with
    # default umask is world-readable, and nothing else will ever say so.
    mode="$(stat -f %Lp "$p/auth.json" 2>/dev/null || stat -c %a "$p/auth.json" 2>/dev/null)"
    [ "$mode" = "600" ] || warn "codex/$name: auth.json is mode ${mode:-?}, not 600 — the tokens inside are plaintext. Fix: chmod 600 $p/auth.json"
    state="signed in"
  else
    state="not signed in (CODEX_HOME=$p codex login)"
  fi
  if [ -L "$p/config.toml" ]; then
    warn "codex/$name: config.toml is a symlink. Codex edits it in place (project trust, hook state), so those edits land in the original. Use a copy."
  fi
  for d in prompts skills; do
    [ -L "$p/$d" ] && warn "codex/$name: $d is a directory symlink — installers writing through it produce dead links; make it a real directory of per-entry links"
  done
  n_sess=$(find "$p/sessions" -name 'rollout-*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
  note "codex/$name — $state, $n_sess session rollout(s)"
done <<EOF
$(agswt_is_codex_profile "$CODEX_DEFAULT" && printf '%s\n' "$CODEX_DEFAULT"; agswt_codex_profiles)
EOF
[ "$found_codex" -eq 1 ] || note "no Codex profiles (no $CODEX_DEFAULT, nothing under $CODEX_PROFILES)"

if [ "$found_any" -eq 1 ]; then
  :
elif [ "$PROFILES_ROOT_OK" -eq 0 ]; then
  # Distinguish the two ways of finding nothing. An absent root is the state a
  # machine is in when its profiles were made before this default existed --
  # reporting it as "no profiles" sends someone to create-profile to build a
  # second set beside the ones they already have.
  warn "profiles root $CLAUDE_PROFILES does not exist. If your profiles are elsewhere, set AGSWT_PROFILES_ROOT to that directory; if you have none yet, see create-profile."
else
  note "no profiles found under $CLAUDE_PROFILES — see create-profile"
fi

# -------------------------------------------------------- workspace integrity

head_ "Workspace integrity"

# Memory with no transcripts beside it is NOT by itself a partial migration.
#
# Two things were wrong with saying it was, and both produced false alarms on a
# healthy machine -- 11 of 13 findings on the first dogfood run.
#
# FIRST, a slug is not a workspace's only home. The same project can be open
# under more than one profile, and a transcript carries a session id in its
# FILE NAME, so the question "did this session's transcript survive?" is
# answered by looking for that id anywhere under any profile -- not by
# assuming the sibling slug holds it. Below, every transcript on the machine is
# indexed by session id once, and a slug with no local transcripts is only
# called a loss when nothing else claims its sessions either.
#
# SECOND, memory can legitimately outlive its transcripts. Memory written long
# before the profile directory existed was inherited, not migrated badly, and
# transcripts age out while memory is kept on purpose. So the mtime comparison
# below decides which sentence to print, and the count comparison decides
# whether it is a WARNING at all: a warning needs a source that actually holds
# more than we do. Without one, this is an observation, and observations do not
# set the exit code.

# Index every transcript on the machine by the session id in its file name.
# One pass, reused for every workspace.
ALL_TX="$(mktemp)"; trap 'rm -f "$ALL_TX"' EXIT INT TERM
find "$CLAUDE_PROFILES" "$CLAUDE_DEFAULT" -type f -name '*.jsonl' 2>/dev/null \
  | while IFS= read -r f; do printf '%s\t%s\n' "$(basename "$f" .jsonl)" "$f"; done \
  > "$ALL_TX" 2>/dev/null || true

checked=0
while IFS= read -r prof; do
  [ -n "$prof" ] || continue
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    checked=$((checked + 1))
    label="$(prof_label "$prof")/$(basename "$ws")"
    mem=$(find "$ws/memory" -type f 2>/dev/null | wc -l | tr -d ' ')
    tx=$(find "$ws" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
    side=$(find "$ws" -mindepth 1 -maxdepth 1 -type d ! -name memory 2>/dev/null | wc -l | tr -d ' ')

    if [ "$mem" -gt 0 ] && [ "$tx" -eq 0 ]; then
      # Does the SAME slug hold transcripts under some other profile?
      slug="$(basename "$ws")"
      elsewhere=$(awk -F'\t' -v s="/$slug/" '$2 ~ s {n++} END {print n+0}' "$ALL_TX")
      if [ "$elsewhere" -gt 0 ]; then
        warn "$label: $mem memory file(s), no transcripts here, but $elsewhere transcript(s) for the same workspace live under another profile — a migration copied memory/ and left the *.jsonl behind."
      else
        # Nothing anywhere claims this workspace. Inherited history, or
        # transcripts aged out. Say which, and do not call it a problem.
        prof_epoch=$(stat -f %B "$prof" 2>/dev/null || stat -c %W "$prof" 2>/dev/null || echo 0)
        mem_epoch=$(find "$ws/memory" -type f -exec stat -f %m {} \; 2>/dev/null | sort -n | head -1)
        mem_epoch="${mem_epoch:-0}"
        if [ "$prof_epoch" -gt 0 ] && [ "$mem_epoch" -gt 0 ] \
           && [ "$((prof_epoch - mem_epoch))" -gt 604800 ]; then
          note "$label: $mem memory file(s), no transcripts anywhere — memory predates the profile by over a week, so this history was inherited, not lost."
        else
          note "$label: $mem memory file(s), no transcripts anywhere — nothing else holds them either, so there is nothing to recover."
        fi
      fi
    fi
    [ "$side" -gt 0 ] && note "$label: mem=$mem tx=$tx sidecar=$side"
  done <<INNER
$(list_dirs "$prof/projects")
INNER
done <<EOF
$(all_profiles "$CLAUDE_PROFILES")
EOF
[ "$checked" -gt 0 ] || note "no workspaces to check"

# -------------------------------------------------------------------- verdict

printf '\n'
if [ "$problems" -eq 0 ]; then
  printf 'doctor: no problems found\n'
  exit 0
fi
printf 'doctor: %d item(s) need attention\n' "$problems"
exit 1
