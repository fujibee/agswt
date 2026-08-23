#!/usr/bin/env bash
# agswt wire-direnv — bind a directory to a profile, and prove the binding.
#
# Implements assets/WORKFLOW.yaml wire-direnv.
#
# Exists as a script for one reason: a nested .envrc REPLACES its parent
# wholesale unless it opens with source_up. Forget that line and the directory
# still works -- it picks the right profile and looks finished -- while every
# variable the parent exported is gone. The bill arrives later and somewhere
# else, as a push made from the wrong account. Detection after the fact only
# helps whoever runs doctor; writing it correctly helps everybody.
#
# Usage:
#   wire-direnv.sh <profile> [--dir <directory>] [--profiles-root <dir>]
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/agswt-common.sh"
CLAUDE_PROFILES="$(agswt_profiles_root)"
CLAUDE_DEFAULT="$HOME/.claude"
AGSWT_VERSION="$(cat "$_here/../VERSION" 2>/dev/null | tr -d '[:space:]')"

usage() {
  printf 'usage: wire-direnv.sh <profile> [--dir <directory>] [--migrate] [--profiles-root <dir>]\n'
  printf '       --migrate moves this directory'"'"'s existing history into the profile\n'
  printf '       the directory defaults to the current one\n'
}
problems=0
note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*"; problems=$((problems + 1)); }
die()   { printf 'wire-direnv: %s\n' "$*" >&2; exit 2; }
head_() { printf '\n== %s\n' "$*"; }

PROFILE=""; DIR="$PWD"; MIGRATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:?--dir needs a directory}"; shift 2 ;;
    --migrate) MIGRATE=1; shift ;;
    --profiles-root) CLAUDE_PROFILES="${2:?--profiles-root needs a dir}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) die "unknown option: $1
$(usage)" ;;
    # THE PROFILE IS THE FIRST POSITIONAL, and the directory is a flag. The
    # opposite order reads just as naturally, so a wrong guess must not be
    # absorbed silently -- it must say what it received.
    *) [ -z "$PROFILE" ] || die "got 2 positional arguments ('$PROFILE' then '$1'); only the profile is positional.
$(usage)"
       PROFILE="$1"; shift ;;
  esac
done

printf 'agswt wire-direnv — version %s\n' "${AGSWT_VERSION:-unknown}"
[ -n "$PROFILE" ] || die "a profile name is required
$(usage)"
[ -d "$DIR" ] || die "no such directory: $DIR"
DIR="$(cd "$DIR" && pwd -P)"

case "$PROFILE" in /*) PROFILE_DIR="$PROFILE" ;; *) PROFILE_DIR="$CLAUDE_PROFILES/$PROFILE" ;; esac
[ -d "$PROFILE_DIR" ] || die "profile not found: $PROFILE_DIR
  Create it first:  create-profile.sh $PROFILE"

head_ "Binding"
note "directory = $DIR"
note "profile   = $PROFILE_DIR"

# ------------------------------------------------------- step 2: refuse first

# Never overwrite. An existing .envrc is somebody's configuration, and the
# variables it exports are invisible from here.
if [ -e "$DIR/.envrc" ]; then
  die "$DIR/.envrc already exists — not overwriting it.
  Add this line yourself, keeping whatever is already there:
    export CLAUDE_CONFIG_DIR=$PROFILE_DIR"
fi

# --------------------------------------------- step 1: does a parent .envrc exist

head_ "Parent"
# Searched upward from the PARENT, not from here: this directory has no .envrc
# yet (refused above), and finding one further up is what decides whether the
# file needs source_up.
parent_envrc=""
p="$(dirname "$DIR")"
while [ -n "$p" ] && [ "$p" != "/" ]; do
  if [ -f "$p/.envrc" ]; then parent_envrc="$p/.envrc"; break; fi
  p="$(dirname "$p")"
done

if [ -n "$parent_envrc" ]; then
  note "found $parent_envrc — the new file must chain to it"
  printf 'source_up\nexport CLAUDE_CONFIG_DIR=%s\n' "$PROFILE_DIR" > "$DIR/.envrc" \
    || die "could not write $DIR/.envrc"
  ok "wrote .envrc with source_up"
else
  note "no parent .envrc above this directory"
  printf 'export CLAUDE_CONFIG_DIR=%s\n' "$PROFILE_DIR" > "$DIR/.envrc" \
    || die "could not write $DIR/.envrc"
  ok "wrote .envrc"
fi

# ---------------------------------------------------------- step 5: no direnv

# THE HOOK IS A SEPARATE QUESTION FROM THE BINARY, and `direnv exec` cannot
# answer it: exec loads the .envrc directly, bypassing the shell hook entirely.
# So every check below this line can pass while an interactive shell never
# reads the file at all -- green here, unbound in the terminal the person
# actually uses. Approximated by grepping the rc files, and said to be an
# approximation, because the only authority is `direnv status` in that shell.
hook_seen=""
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.config/fish/config.fish"; do
  [ -f "$rc" ] || continue
  grep -q 'direnv hook' "$rc" 2>/dev/null && hook_seen="${hook_seen}${hook_seen:+, }$rc"
done

if ! command -v direnv >/dev/null 2>&1; then
  head_ "direnv not installed"
  # Degraded on purpose, and said so. The file is written and correct; what is
  # missing is anything to load it, and pretending otherwise would report a
  # binding that does not bind.
  note "The .envrc is written but NOTHING WILL LOAD IT. This directory is not bound."
  note "To install it (two steps — the binary alone does nothing):"
  printf '\n    brew install direnv        # or: sudo apt install direnv\n'
  printf '    eval "$(direnv hook zsh)"  # add to ~/.zshrc (bash: ...hook bash)\n'
  printf '    https://direnv.net for other shells\n\n'
  note "Or skip direnv and export the variable yourself in every shell:"
  printf '\n    export CLAUDE_CONFIG_DIR=%s\n\n' "$PROFILE_DIR"
  exit 0
fi

if [ -z "$hook_seen" ]; then
  head_ "direnv hook"
  warn "direnv is installed but no 'direnv hook' line was found in your rc files. Without it .envrc is never loaded in an interactive shell — the checks below use 'direnv exec', which bypasses the hook and cannot see this."
  note "Add to ~/.zshrc (bash: ...hook bash):   eval \"\$(direnv hook zsh)\""
  note "This is a guess from the rc files. Confirm in your own shell with: direnv status"
fi

head_ "Allow"
(cd "$DIR" && direnv allow .) >/dev/null 2>&1 \
  && ok "direnv allow" || warn "direnv allow failed — run it yourself in $DIR"

# --------------------------------------------------------- step 4: prove it

head_ "Verification"
# BOTH HALVES, because either alone can be true while the binding is broken.
#
# The child having the right CLAUDE_CONFIG_DIR proves the export line works --
# and says nothing about source_up, since a file MISSING source_up sets that
# variable perfectly well while discarding everything else. So the parent's own
# exports are checked in the child too: that is the half that fails when the
# line is absent, and it is the half people skip.
child_ccd="$(cd "$DIR" && direnv exec . sh -c 'printf "%s" "${CLAUDE_CONFIG_DIR:-}"' 2>/dev/null)"
if [ "$child_ccd" = "$PROFILE_DIR" ]; then
  ok "in $DIR: CLAUDE_CONFIG_DIR = $child_ccd"
else
  warn "in $DIR: CLAUDE_CONFIG_DIR = ${child_ccd:-<unset>}, expected $PROFILE_DIR"
fi

if [ -n "$parent_envrc" ]; then
  parent_dir="$(dirname "$parent_envrc")"
  # What the parent exports, measured rather than assumed: read its own
  # environment, then look for the same names in the child.
  inherited=0; lost=""
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    # CLAUDE_CONFIG_DIR is excluded: the child overrides it deliberately, so a
    # difference there is the binding working, not inheritance failing. Left in,
    # it reported "source_up is not taking effect" on a directory where the
    # parent's GH_TOKEN had in fact arrived intact.
    [ "$var" = "CLAUDE_CONFIG_DIR" ] && continue
    pv="$(cd "$parent_dir" && direnv exec . sh -c "printf '%s' \"\${$var:-}\"" 2>/dev/null)"
    [ -n "$pv" ] || continue
    cv="$(cd "$DIR" && direnv exec . sh -c "printf '%s' \"\${$var:-}\"" 2>/dev/null)"
    if [ "$cv" = "$pv" ]; then inherited=$((inherited + 1))
    else lost="${lost}${lost:+, }$var"; fi
  done <<EOF
$(grep -oE '^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$parent_envrc" 2>/dev/null \
    | awk '{print $NF}' | sort -u)
EOF
  if [ -n "$lost" ]; then
    warn "the parent's exports did NOT reach this directory: $lost — source_up is not taking effect"
  elif [ "$inherited" -gt 0 ]; then
    ok "$inherited variable(s) inherited from $parent_envrc — source_up works"
  else
    note "the parent .envrc exports nothing measurable, so inheritance could not be proven here"
  fi

  # And the parent must be unchanged by any of this.
  parent_ccd="$(cd "$parent_dir" && direnv exec . sh -c 'printf "%s" "${CLAUDE_CONFIG_DIR:-}"' 2>/dev/null)"
  if [ "$parent_ccd" = "$PROFILE_DIR" ]; then
    note "$parent_dir also resolves to this profile (it did before, or inherits it)"
  else
    ok "$parent_dir keeps its own profile: ${parent_ccd:-<unset>}"
  fi
fi

# ---------------------------------------------------------- step 6: next step

printf '\n'
if [ "$problems" -eq 0 ]; then
  printf 'wire-direnv: bound, and the binding was measured on both sides\n\n'

  # A BOUND DIRECTORY IS NOT AN EMPTY ONE. The slug is derived from the path,
  # so whatever this directory accumulated under a DIFFERENT account is still
  # filed under that account -- present on disk, invisible to `claude -c` here.
  # "It is a new directory, so there is nothing to move" is never quite true
  # either: asking for this wiring from inside the directory is itself a
  # conversation, and it was recorded wherever the old account files things.
  # Left to be inferred, this gets skipped; so it is measured and stated.
  bound_slug="$(printf '%s' "$DIR" | tr '/' '-')"
  # Collected first, acted on after. WHICH action is right depends on HOW MANY
  # sources there are, and that is not known until the sweep finishes -- so
  # nothing may be printed or migrated from inside the loop.
  found=0; sources=""
  while IFS= read -r other; do
    [ -n "$other" ] || continue
    [ "$other" = "$PROFILE_DIR" ] && continue
    n=$(find "$other/projects/$bound_slug" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] || continue
    # TWO NAMES, NOT ONE. The sentence wants prose ("the default profile");
    # the command below is meant to be pasted and must carry the token
    # migrate-workspace actually parses. Using the readable one in both places
    # printed `--from the default profile` -- three words, and it cannot run.
    case "$other" in
      "$CLAUDE_DEFAULT")    label="the default profile"; arg="default" ;;
      "$CLAUDE_PROFILES"/*) label="${other#"$CLAUDE_PROFILES"/}"; arg="$label" ;;
      *)                    label="$other"; arg="$other" ;;
    esac
    found=$((found + 1))
    sources="$sources$arg	$label	$n
"
  done <<EOF
$(find "$CLAUDE_PROFILES" -mindepth 1 -maxdepth "${AGSWT_MAX_DEPTH:-4}" -type d -name projects 2>/dev/null | sed 's|/projects$||'; printf '%s\n' "$CLAUDE_DEFAULT")
EOF

  if [ "$MIGRATE" -eq 1 ] && [ "$found" -eq 1 ]; then
    m_arg="$(printf '%s' "$sources" | head -1 | cut -f1)"
    m_lab="$(printf '%s' "$sources" | head -1 | cut -f2)"
    printf '  Bringing this directory'"'"'s history over from %s:\n\n' "$m_lab"
    "$_here/migrate-workspace.sh" --from "$m_arg" --to "$PROFILE" --project "$DIR" 2>&1 | sed 's/^/    /'
    m_rc=${PIPESTATUS[0]}
    printf '\n'
    if [ "$m_rc" -eq 0 ]; then
      ok "history copied from $m_lab"
      # The word "migrate" reads as "move" to most people, and acting on that
      # reading means assuming the old copy is gone. It is not.
      note "$m_lab still holds its copy — removing it is a human decision"
    else
      warn "migrate-workspace exited $m_rc — read its output above; nothing was deleted"
    fi
  elif [ "$MIGRATE" -eq 1 ] && [ "$found" -gt 1 ]; then
    # NOT A CHOICE THIS SCRIPT GETS TO MAKE. Several accounts hold history for
    # this one directory, and merging them is a decision about which past is
    # authoritative -- so stop, name them, and hand back one command each.
    warn "history for this directory exists under $found profiles; not choosing between them"
    printf '%s' "$sources" | while IFS='	' read -r a l n; do
      [ -n "$a" ] || continue
      printf '    %s conversation(s) under %s:\n' "$n" "$l"
      printf '      migrate-workspace.sh --from %s --to %s --project %s\n' "$a" "$PROFILE" "$DIR"
    done
    printf '\n'
  elif [ "$MIGRATE" -eq 1 ]; then
    ok "nothing to migrate: no other profile holds this directory's history"
  else
    printf '%s' "$sources" | while IFS='	' read -r a l n; do
      [ -n "$a" ] || continue
      printf '  NOTE: this directory already has %s conversation(s) under %s.\n' "$n" "$l"
      printf '        They will NOT be visible to claude -c here until you bring them over:\n\n'
      printf '          migrate-workspace.sh --from %s --to %s --project %s\n\n' "$a" "$PROFILE" "$DIR"
      printf '        (that includes the conversation that asked for this wiring, if any)\n\n'
    done
  fi

  # THE BINDING DOES NOT REACH THE SESSION THAT ASKED FOR IT. direnv sets the
  # variable for processes started afterwards, so the claude already running
  # here keeps the old account -- and everything it writes keeps going to the
  # old profile while the report says the directory is bound. Saying "the
  # binding applies to new launches" only describes that; the reader still has
  # to work out that they must restart. Give the two commands instead.
  printf '  This session still runs on the OLD account — the binding only applies\n'
  printf '  to new launches. To switch now:\n\n'
  printf '    exit\n'
  printf '    claude\n\n'
  # A binding is not a sign-in: on a fresh profile that relaunch asks for an
  # account, which is easy to read as a fault in the wiring just measured.
  printf '  The first command leaves this claude; the second relaunches here on the\n'
  printf '  new profile, and it will ask you to sign in — that prompt is the real\n'
  printf '  sign-in, not a wiring failure.\n\n'
  printf '  Then see where it stands against your other accounts:  report.sh\n'
  exit 0
fi
printf 'wire-direnv: %d item(s) need attention\n' "$problems"
exit 1
