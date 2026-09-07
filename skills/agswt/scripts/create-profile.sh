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
#   create-profile.sh <name> [--tool claude|codex] [--from <profile>] [--shared <dir>] [--profiles-root <dir>]
#     <name> may contain '/' for a nested profile: create-profile.sh work/acme
#     --tool    which tool's profile to create (default: claude). A Codex
#               profile lives under the Codex root (~/.codex_profiles) under
#               the SAME name, so "work/acme" can have both halves.
#     --from    where settings.json / config.toml is copied FROM (default: the tool's default dir)
#     --shared  where CLAUDE.md/commands/skills (AGENTS.md/prompts/skills) link TO (default: same)
set -uo pipefail

CLAUDE_DEFAULT="$HOME/.claude"
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/agswt-common.sh"
CLAUDE_PROFILES="$(agswt_profiles_root)"
CODEX_PROFILES="$(agswt_codex_profiles_root)"
CODEX_DEFAULT="$AGSWT_CODEX_DEFAULT"
AGSWT_VERSION="$(cat "$_here/../VERSION" 2>/dev/null | tr -d '[:space:]')"

note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*"; }
die()   { printf 'create-profile: %s\n' "$*" >&2; exit 2; }
head_() { printf '\n== %s\n' "$*"; }

usage() {
  printf 'usage: create-profile.sh <name> [--tool claude|codex] [--from <profile>] [--shared <dir>] [--profiles-root <dir>]\n'
  printf '       <name> may contain / to nest under a group (parents are created)\n'
}

NAME=""; FROM=""; SHARED=""; SHARED_SET=""; TOOL=claude
while [ $# -gt 0 ]; do
  case "$1" in
    --tool) TOOL="${2:?--tool needs claude or codex}"; shift 2
            case "$TOOL" in claude|codex) ;; *) die "--tool must be claude or codex, not $TOOL" ;; esac ;;
    --from) FROM="${2:?--from needs a profile}"; shift 2 ;;
    --shared) SHARED="${2:?--shared needs a dir}"; SHARED_SET=1; shift 2 ;;
    --profiles-root) CLAUDE_PROFILES="${2:?--profiles-root needs a dir}"; CODEX_PROFILES="$CLAUDE_PROFILES"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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
# A '/' makes a nested profile: work/acme lives at <root>/work/acme and is named
# "work/acme" everywhere. Discovery finds it by the same rule that finds any
# other -- a directory holding .claude.json -- so "work" needs no registration.
case "$NAME" in
  /*|*/) die "name must not start or end with '/': $NAME" ;;
  *..*)  die "name must not contain '..': $NAME" ;;
esac

# =========================================================================
# Codex. Same four steps, different files. Kept as one block rather than
# interleaved with the Claude steps so that each tool's rules can be read
# top to bottom -- the two share the shape (copy the rewritten file, link the
# shared originals, never touch the credential, stop before sign-in) but
# not one file name.
# =========================================================================
if [ "$TOOL" = codex ]; then
  DIR="$CODEX_PROFILES/$NAME"
  note "tool = codex"
  note "name = $NAME"
  note "dir  = $DIR"

  if [ -e "$DIR" ]; then
    if agswt_is_codex_profile "$DIR"; then
      die "a Codex profile already exists at $DIR — pick another name, or sign in to it with:
    CODEX_HOME=$DIR codex login"
    fi
    die "$DIR already exists (and is not a Codex profile). Refusing to write into it."
  fi

  head_ "Directory"
  case "$NAME" in
    */*) parent="$CODEX_PROFILES/$(dirname "$NAME")"
         if [ ! -d "$parent" ]; then
           note "creating parent group $parent"
         elif agswt_is_codex_profile "$parent"; then
           note "parent $parent is itself a profile — allowed, it will keep working as one"
         fi ;;
  esac
  mkdir -p "$DIR" || die "could not create $DIR"
  ok "created $DIR"

  head_ "Shared configuration"
  if [ -n "$FROM" ]; then
    case "$FROM" in /*) SRC="$FROM" ;; *) SRC="$CODEX_PROFILES/$FROM" ;; esac
    [ -d "$SRC" ] || die "--from profile not found: $SRC"
  else
    SRC="$CODEX_DEFAULT"
  fi
  [ -n "$SHARED" ] || SHARED="$CODEX_DEFAULT"
  note "settings source  = $SRC$([ -n "$FROM" ] || printf ' (default; override with --from)')"
  note "shared originals = $SHARED$([ -n "$SHARED_SET" ] || printf ' (default; override with --shared)')"

  # config.toml is COPIED, never symlinked: Codex edits it itself (project
  # trust entries, model-migration notices, hook state), and a symlink would
  # write those edits into the original. A source without one is not an
  # error the way a missing settings.json is -- a pristine Codex install has
  # none -- but the profile still needs its marker, so an empty file is
  # written and announced.
  if [ -f "$SRC/config.toml" ]; then
    cp -p "$SRC/config.toml" "$DIR/config.toml" && ok "copied config.toml (never a symlink: Codex rewrites it)"
  else
    printf '# agswt: created empty; %s had no config.toml to seed from\n' "$SRC" > "$DIR/config.toml" \
      && note "$SRC/config.toml not present — wrote an empty one so the profile is discoverable"
  fi
  for f in hooks.json; do
    if [ -f "$SRC/$f" ]; then
      cp -p "$SRC/$f" "$DIR/$f" && ok "copied $f"
    else
      note "$SRC/$f not present, skipped"
    fi
  done
  # rules/ holds exec-policy files; per-profile copy, same reasoning as config.
  if [ -d "$SRC/rules" ]; then
    cp -Rp "$SRC/rules" "$DIR/rules" && ok "copied rules/ ($(find "$DIR/rules" -type f | wc -l | tr -d ' ') file(s))"
  else
    note "$SRC/rules not present, skipped"
  fi

  # AGENTS.md is the Codex counterpart of CLAUDE.md: read, not rewritten, so
  # one symlinked source of truth.
  if [ -e "$SHARED/AGENTS.md" ]; then
    target="$(cd "$(dirname "$SHARED/AGENTS.md")" && pwd -P)/AGENTS.md"
    [ -L "$SHARED/AGENTS.md" ] && target="$(readlink "$SHARED/AGENTS.md")"
    ln -s "$target" "$DIR/AGENTS.md" && ok "symlinked AGENTS.md -> $target"
  else
    note "$SHARED/AGENTS.md not present, skipped"
  fi

  # prompts/ and skills/ follow the Claude rule for commands/ and skills/: a
  # REAL directory of absolute per-entry links, never a directory symlink
  # (traps #15). Dot-entries are skipped on purpose: skills/.system is
  # Codex's own, regenerated per home.
  for p in prompts skills; do
    if [ -d "$SHARED/$p" ]; then
      srcdir="$(cd "$SHARED/$p" && pwd -P)"
      mkdir -p "$DIR/$p"
      n=0
      for item in "$srcdir"/*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        ln -s "$item" "$DIR/$p/$(basename "$item")" && n=$((n+1))
      done
      ok "created $p/ with $n absolute links into $srcdir"
    else
      note "$SHARED/$p not present, skipped"
    fi
  done

  # THE CREDENTIAL IS NEVER COPIED. auth.json holds the account's tokens in
  # plaintext; a copy is a second signed-in instance of the same account,
  # which is the opposite of what a new profile is for.
  note "auth.json not copied — a profile gets its account by signing in, never by copying"

  for f in config.toml hooks.json; do
    [ -e "$DIR/$f" ] || continue
    [ -L "$DIR/$f" ] && warn "$f is a symlink — it must be a real file; Codex edits it in place"
  done
  if [ -e "$DIR/AGENTS.md" ] && [ ! -L "$DIR/AGENTS.md" ]; then
    warn "AGENTS.md is a real copy — it should be a symlink so there is one source of truth"
  fi
  for p in prompts skills; do
    [ -e "$DIR/$p" ] || continue
    if [ -L "$DIR/$p" ]; then
      warn "$p is a directory symlink — installers writing through it produce dead links; make it a real directory of per-entry links"
    else
      # Named, not counted: a count says something is wrong, a name says
      # which entry -- and the target shows that the SOURCE entry was already
      # dead (an installer's stale link), which is where the fix goes.
      for l in "$DIR/$p"/*; do
        [ -L "$l" ] && [ ! -e "$l" ] && warn "$p/$(basename "$l") is a broken link -> $(readlink "$l") (the source entry is itself dead; fix or remove it there)"
      done
    fi
  done

  head_ "Not ready yet"
  # For Codex the CLI login IS the route. `codex login` opens the browser
  # OAuth flow of the vendor's own binary and writes auth.json into this
  # directory; whether the first interactive launch would also offer a
  # sign-in has not been measured, so nothing here relies on it.
  printf '  The profile is PREPARED, not signed in.\n\n'
  printf '  Sign it in (browser OAuth, needs a human):\n\n'
  printf '    CODEX_HOME=%s codex login\n' "$DIR"
  printf '    CODEX_HOME=%s codex login --device-auth   # no browser on this machine\n\n' "$DIR"
  printf '  Then give it something to do:\n\n'
  printf '    bind a directory to it   wire-direnv.sh %s --dir <directory>\n\n' "$NAME"
  printf '  Codex history is not migrated between profiles: Codex is moving thread\n'
  printf '  history into sqlite (see codex migrate-rollouts), so copying files is not\n'
  printf '  a migration. See references/codex-notes.md.\n'
  exit 0
fi

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

  # CLAUDE.md is SYMLINKED as a file: one source of truth, read not rewritten.
  if [ -e "$SHARED/CLAUDE.md" ]; then
    target="$(cd "$(dirname "$SHARED/CLAUDE.md")" && pwd -P)/CLAUDE.md"
    [ -L "$SHARED/CLAUDE.md" ] && target="$(readlink "$SHARED/CLAUDE.md")"
    ln -s "$target" "$DIR/CLAUDE.md" && ok "symlinked CLAUDE.md -> $target"
  else
    note "$SHARED/CLAUDE.md not present, skipped"
  fi

  # skills/ and commands/ are REAL DIRECTORIES whose entries are absolute
  # symlinks -- never a symlink of the directory itself. Installers (e.g.
  # `npx skills add`) write new entries into these directories and compute
  # relative link targets against the LOGICAL path; written through a
  # directory symlink, the file lands at the physical location where that
  # relative target resolves somewhere else entirely (measured: dead links).
  # A real directory keeps installs local to this profile and correct; the
  # per-entry links still give every existing shared item one source of truth.
  for p in commands skills; do
    if [ -d "$SHARED/$p" ]; then
      # Resolve the shared side to its PHYSICAL path first, so entries link
      # to originals even when $SHARED/$p is itself a link.
      srcdir="$(cd "$SHARED/$p" && pwd -P)"
      mkdir -p "$DIR/$p"
      n=0
      for item in "$srcdir"/* "$srcdir"/.[!.]*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        ln -s "$item" "$DIR/$p/$(basename "$item")" && n=$((n+1))
      done
      ok "created $p/ with $n absolute links into $srcdir"
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
if [ -e "$DIR/CLAUDE.md" ] && [ ! -L "$DIR/CLAUDE.md" ]; then
  warn "CLAUDE.md is a real copy — it should be a symlink so there is one source of truth"
fi
for p in commands skills; do
  [ -e "$DIR/$p" ] || continue
  if [ -L "$DIR/$p" ]; then
    warn "$p is a directory symlink — installers writing through it produce dead links; make it a real directory of per-entry links"
  else
    # Named, not counted: a count says something is wrong, a name says
    # which entry -- and the target shows that the SOURCE entry was already
    # dead (an installer's stale link), which is where the fix goes.
    for l in "$DIR/$p"/*; do
      [ -L "$l" ] && [ ! -e "$l" ] && warn "$p/$(basename "$l") is a broken link -> $(readlink "$l") (the source entry is itself dead; fix or remove it there)"
    done
  fi
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
