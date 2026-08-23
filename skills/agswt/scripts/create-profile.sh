#!/usr/bin/env bash
# agswt create-profile — prepare a profile directory and stop at sign-in.
#
# Implements assets/WORKFLOW.yaml create-profile, steps 1-4.
#
# Exists as a script because both ways this goes wrong are silent. Copying
# what must be symlinked (or the reverse) still produces a directory that
# looks finished, and the damage surfaces days later when the client next
# writes. And step 4 is a STOP -- an instruction that an agent, told to
# complete a task, is inclined to walk straight past.
#
# THIS SCRIPT NEVER SIGNS IN. OAuth needs a browser and a human. It prints the
# command and exits; a profile it prepared is NOT ready, and it says so.
#
# Usage:
#   create-profile.sh <name> [--from <profile>] [--shared <dir>] [--profiles-root <dir>]
#     <name> may contain '/' for a nested profile: create-profile.sh work/oma
#     --from    where settings.json is copied FROM   (default: ~/.claude)
#     --shared  where CLAUDE.md/commands/skills link TO (default: ~/.claude)
set -uo pipefail

CLAUDE_DEFAULT="$HOME/.claude"
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/agswt-common.sh"
CLAUDE_PROFILES="$(agswt_profiles_root)"
AGSWT_VERSION="$(cat "$_here/../VERSION" 2>/dev/null | tr -d '[:space:]')"

note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*"; }
die()   { printf 'create-profile: %s\n' "$*" >&2; exit 2; }
head_() { printf '\n== %s\n' "$*"; }

usage() {
  printf 'usage: create-profile.sh <name> [--from <profile>] [--shared <dir>] [--profiles-root <dir>]\n'
  printf '       <name> may contain / to nest under a group (parents are created)\n'
}

NAME=""; FROM=""; SHARED=""; SHARED_SET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:?--from needs a profile}"; shift 2 ;;
    --shared) SHARED="${2:?--shared needs a dir}"; SHARED_SET=1; shift 2 ;;
    --profiles-root) CLAUDE_PROFILES="${2:?--profiles-root needs a dir}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) die "unknown option: $1
$(usage)" ;;
    *) [ -z "$NAME" ] || die "got 2 positional arguments ('$NAME' then '$1'); only the profile name is positional.
$(usage)"
       NAME="$1"; shift ;;
  esac
done

printf 'agswt create-profile — version %s\n' "${AGSWT_VERSION:-unknown}"
[ -n "$NAME" ] || die "a profile name is required
$(usage)"

# ------------------------------------------------- step 1: choose_tool_and_name

head_ "Name"
# A '/' makes a nested profile: work/oma lives at <root>/work/oma and is named
# "work/oma" everywhere. Discovery finds it by the same rule that finds any
# other -- a directory holding .claude.json -- so "work" needs no registration.
case "$NAME" in
  /*|*/) die "name must not start or end with '/': $NAME" ;;
  *..*)  die "name must not contain '..': $NAME" ;;
esac
DIR="$CLAUDE_PROFILES/$NAME"
note "name = $NAME"
note "dir  = $DIR"

# Never silently reuse. An existing directory may already hold somebody's
# history, and adopting it would make this command look like it created
# something it merely walked into.
if [ -e "$DIR" ]; then
  if [ -f "$DIR/.claude.json" ]; then
    die "a profile already exists at $DIR — pick another name, or sign in to it with:
    CLAUDE_CONFIG_DIR=$DIR claude auth login --claudeai"
  fi
  die "$DIR already exists (and is not a profile). Refusing to write into it."
fi

# --------------------------------------------------- step 2: create_directory

head_ "Directory"
# A nested name creates its parents. That is the point of the feature, and a
# parent may itself be a signed-in profile -- the discovery rule allows both,
# so nothing here has to forbid it. Announced because a directory appearing
# that nobody typed is worth seeing.
case "$NAME" in
  */*) parent="$CLAUDE_PROFILES/$(dirname "$NAME")"
       if [ ! -d "$parent" ]; then
         note "creating parent group $parent"
       elif [ -f "$parent/.claude.json" ]; then
         note "parent $parent is itself a profile — allowed, it will keep working as one"
       fi ;;
esac
mkdir -p "$DIR/projects" || die "could not create $DIR/projects"
ok "created $DIR/projects"

# ------------------------------------------------- step 3: seed_shared_config

head_ "Shared configuration"
# Where to seed from. An explicit --from wins; otherwise the default directory,
# which is the one that certainly exists.
# THE SOURCE IS NAMED, NEVER INHERITED. Without --from this is the default
# directory and nothing else -- in particular NOT the CLAUDE_CONFIG_DIR this
# script happens to be running under. That variable is per-shell hidden state,
# so adopting it makes the same command produce different profiles for two
# people, or for the same person in two terminals. One agent improvising this
# step picked its own ambient value and produced exactly that.
if [ -n "$FROM" ]; then
  case "$FROM" in /*) SRC="$FROM" ;; *) SRC="$CLAUDE_PROFILES/$FROM" ;; esac
  [ -d "$SRC" ] || die "--from profile not found: $SRC"
else
  SRC="$CLAUDE_DEFAULT"
fi
# Shared originals are the default directory's, so every profile sees one copy
# of a command or skill an installer adds. Overridable, never guessed.
[ -n "$SHARED" ] || SHARED="$CLAUDE_DEFAULT"

note "settings source  = $SRC$([ -n "$FROM" ] || printf ' (default; override with --from)')"
note "shared originals = $SHARED$([ -n "$SHARED_SET" ] || printf ' (default; override with --shared)')"

# Refuse rather than seed something arbitrary. A profile with no settings.json
# is a profile whose hooks and permissions silently differ from every other
# one, and guessing a substitute source hides that behind a success message.
if [ ! -f "$SRC/settings.json" ]; then
  die "no settings.json at $SRC — nothing to seed from.
  Name the source explicitly:
    create-profile.sh $NAME --from <profile>"
fi

if true; then

  # COPIED, NEVER SYMLINKED. Both of these are rewritten by the client through
  # temp-file-and-rename, which REPLACES a symlink with a real file: the link
  # survives until the first write, then the profile quietly stops tracking
  # the original. A symlink here does not fail, it just stops being true.
  for f in settings.json remote-settings.json; do
    if [ -f "$SRC/$f" ]; then
      cp -p "$SRC/$f" "$DIR/$f" && ok "copied $f (never a symlink: the client rewrites it)"
    else
      note "$SRC/$f not present, skipped"
    fi
  done

  # SYMLINKED, because one source of truth is the point: an installer that
  # adds a command or a skill should reach every profile at once. These are
  # read in practice, not rewritten in place.
  for p in CLAUDE.md commands skills; do
    if [ -e "$SHARED/$p" ]; then
      # Link to the ORIGINAL, following a source that is itself a link, so a
      # chain of profiles does not end up pointing at each other.
      target="$(cd "$(dirname "$SHARED/$p")" && pwd -P)/$(basename "$p")"
      [ -L "$SHARED/$p" ] && target="$(readlink "$SHARED/$p")"
      ln -s "$target" "$DIR/$p" && ok "symlinked $p -> $target"
    else
      note "$SHARED/$p not present, skipped"
    fi
  done
fi

# Prove the two rules held, rather than trusting that the branches above ran.
# This is the failure the whole script exists to prevent, so it is checked
# rather than assumed.
for f in settings.json remote-settings.json; do
  [ -e "$DIR/$f" ] || continue
  [ -L "$DIR/$f" ] && warn "$f is a symlink — it must be a real file; the client will replace it on first write"
done
for p in CLAUDE.md commands skills; do
  [ -e "$DIR/$p" ] || continue
  [ -L "$DIR/$p" ] || warn "$p is a real copy — it should be a symlink so installers reach every profile"
done

# ------------------------------------------------- step 4: stop_and_hand_off

head_ "Not ready yet"
# The operation ENDS here, and what ends it is no longer a command to run.
# Signing in through the CLI does NOT spare a working profile its sign-in
# screen: the first interactive launch asks again regardless (measured twice).
# So the honest handoff is not "log in, then confirm" -- it is "bind it, then
# launch, and sign in there, once".
printf '  The profile is PREPARED, not signed in.\n'
printf '  Signing in happens at the first launch, not here.\n\n'
printf '  Next, give it something to do:\n\n'
printf '    bind a directory to it   wire-direnv.sh %s --dir <directory>\n' "$NAME"
printf '    move an existing project migrate-workspace.sh --to %s ...\n\n' "$NAME"
printf '  Then run claude in that directory. It will ask you to sign in —\n'
printf '  that screen IS the sign-in for this profile. Once is enough.\n\n'
# The one profile that never gets a launch: nothing would ever carry it through
# the screen above, so it is the only case where the CLI login is the real one.
printf '  Exception — a profile you only ever poll (never launch claude in it):\n\n'
printf '    CLAUDE_CONFIG_DIR=%s claude auth login --claudeai\n\n' "$DIR"
exit 0
