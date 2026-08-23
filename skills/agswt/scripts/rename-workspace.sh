#!/usr/bin/env bash
# agswt rename-workspace — make a stored slug follow a project that moved.
#
# Implements assets/WORKFLOW.yaml rename-workspace, steps 1-3.
#
# A workspace is addressed by its absolute path with every '/' turned into
# '-'. Move the project and the history is still there, still complete, and
# invisible: nothing looks up the old slug any more. This renames the slug.
#
# Exists as a script for the two steps either side of the mv, not the mv. A
# rename onto an EXISTING slug is a merge wearing a rename's clothes -- and mv
# performs it without complaint, mixing two projects' transcripts. And the
# contents mention the old path, where some references are stale and others
# are historical fact; rewriting them wholesale destroys the second kind.
#
# Usage:
#   rename-workspace.sh <profile> --from <old-abs-path> --to <new-abs-path>
#   rename-workspace.sh <profile> --old-slug <slug> --new-slug <slug>
#     --dry-run   report what would happen, move nothing
set -uo pipefail

CLAUDE_DEFAULT="$HOME/.claude"
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/agswt-common.sh"
CLAUDE_PROFILES="$(agswt_profiles_root)"
AGSWT_VERSION="$(cat "$_here/../VERSION" 2>/dev/null | tr -d '[:space:]')"

usage() {
  printf 'usage: rename-workspace.sh <profile> --from <old-abs-path> --to <new-abs-path> [--dry-run]\n'
  printf '       rename-workspace.sh <profile> --old-slug <slug> --new-slug <slug> [--dry-run]\n'
}
problems=0
note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*"; problems=$((problems + 1)); }
die()   { printf 'rename-workspace: %s\n' "$*" >&2; exit 2; }
head_() { printf '\n== %s\n' "$*"; }

PROFILE=""; FROM=""; TO=""; OLD_SLUG=""; NEW_SLUG=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)  PROFILE="${2:?--profile needs a name}"; shift 2 ;;   # accepted, but the positional form is the documented one
    --from)     FROM="${2:?--from needs a path}"; shift 2 ;;
    --to)       TO="${2:?--to needs a path}"; shift 2 ;;
    --old-slug) OLD_SLUG="${2:?--old-slug needs a slug}"; shift 2 ;;
    --new-slug) NEW_SLUG="${2:?--new-slug needs a slug}"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
    -*) die "unknown option: $1
$(usage)" ;;
    # Profile first, matching create-profile and wire-direnv. Paths stay flags:
    # --from/--to are two of a kind and their order is guessable-wrong.
    *) [ -z "$PROFILE" ] || die "got 2 positional arguments ('$PROFILE' then '$1'); only the profile is positional.
$(usage)"
       PROFILE="$1"; shift ;;
  esac
done

printf 'agswt rename-workspace — version %s\n' "${AGSWT_VERSION:-unknown}"
[ -n "$PROFILE" ] || die "a profile is required
$(usage)"
agswt_require_profiles_root >/dev/null || exit 2
case "$PROFILE" in /*) PROFILE_DIR="$PROFILE" ;; *) PROFILE_DIR="$CLAUDE_PROFILES/$PROFILE" ;; esac
[ -d "$PROFILE_DIR" ] || die "profile not found: $PROFILE_DIR"

# ------------------------------------------------------ step 1: locate_old_slug

head_ "Slugs"
if [ -z "$OLD_SLUG" ] || [ -z "$NEW_SLUG" ]; then
  [ -n "$FROM" ] && [ -n "$TO" ] || die "give either --from/--to (absolute paths) or --old-slug/--new-slug"
  case "$FROM" in /*) : ;; *) die "--from must be an absolute path: $FROM" ;; esac
  case "$TO" in   /*) : ;; *) die "--to must be an absolute path: $TO" ;; esac
  # The OLD slug comes from the OLD path -- the directory it names no longer
  # exists, which is the whole situation, so it is never resolved on disk.
  OLD_SLUG="$(printf '%s' "$FROM" | tr '/' '-')"
  NEW_SLUG="$(printf '%s' "$TO" | tr '/' '-')"
fi
[ "$OLD_SLUG" != "$NEW_SLUG" ] || die "old and new slug are the same: $OLD_SLUG"

OLD="$PROFILE_DIR/projects/$OLD_SLUG"
NEW="$PROFILE_DIR/projects/$NEW_SLUG"
note "old = $OLD_SLUG"
note "new = $NEW_SLUG"
[ -d "$OLD" ] || die "no such workspace: $OLD
  Nothing was moved. List what this profile holds:
    ls '$PROFILE_DIR/projects'"

# A DESTINATION THAT EXISTS MAKES THIS A MERGE, and mv would carry it out in
# silence -- moving the old directory INSIDE the new one, or interleaving two
# projects' transcripts. Refused: merging is migrate-workspace's job, where the
# counts and session ids are checked on both sides.
if [ -e "$NEW" ]; then
  n_tx=$(find "$NEW" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
  die "$NEW already exists (holds $n_tx transcript(s)). That would be a MERGE, not a rename.
  To combine them deliberately:
    migrate-workspace.sh --from $PROFILE --to $PROFILE --slug $OLD_SLUG"
fi

# Recorded BEFORE the move, so the check afterwards compares against what was
# actually there rather than against what the move just produced.
mem=$(find "$OLD/memory" -type f 2>/dev/null | wc -l | tr -d ' ')
tx=$(find "$OLD" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
side=$(find "$OLD" -mindepth 1 -maxdepth 1 -type d ! -name memory 2>/dev/null | wc -l | tr -d ' ')
IDS="$(mktemp)"; trap 'rm -f "$IDS"' EXIT INT TERM
find "$OLD" -maxdepth 1 -name '*.jsonl' 2>/dev/null \
  | while IFS= read -r f; do basename "$f" .jsonl; done | sort > "$IDS"
note "holds: memory $mem, transcripts $tx, sidecars $side"

if [ "$DRY" -eq 1 ]; then
  head_ "Dry run"
  note "would move $OLD -> $NEW"
  note "nothing was moved."
  exit 0
fi

# ------------------------------------------------------------- step 2: rename

head_ "Rename"
mv "$OLD" "$NEW" || die "mv failed: $OLD -> $NEW"
ok "moved to $NEW_SLUG"

# Same question migrate asks, in the shape a rename needs: not "did the files
# copy" but "is every session that was here, here now". A mv that half-failed
# leaves the counts looking plausible; the ids do not.
n_mem=$(find "$NEW/memory" -type f 2>/dev/null | wc -l | tr -d ' ')
n_tx=$(find "$NEW" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
n_side=$(find "$NEW" -mindepth 1 -maxdepth 1 -type d ! -name memory 2>/dev/null | wc -l | tr -d ' ')
[ "$n_mem" = "$mem" ] && [ "$n_tx" = "$tx" ] && [ "$n_side" = "$side" ] \
  && ok "counts unchanged: memory $n_mem, transcripts $n_tx, sidecars $n_side" \
  || warn "counts changed across the move: memory $mem->$n_mem, transcripts $tx->$n_tx, sidecars $side->$n_side"

missing=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  [ -f "$NEW/$id.jsonl" ] && continue
  elsewhere="$(find "$CLAUDE_PROFILES" "$CLAUDE_DEFAULT" -type f -name "$id.jsonl" 2>/dev/null | head -1)"
  if [ -n "$elsewhere" ]; then
    warn "session $id is not at the new slug, but exists at $elsewhere"
  else
    warn "session $id is gone and is nowhere on this machine"
  fi
  missing=$((missing + 1))
done < "$IDS"
[ "$missing" -eq 0 ] && ok "all $tx session id(s) present at the new slug"

[ -e "$OLD" ] && warn "$OLD still exists after the move" || ok "old slug is gone"

# ---------------------------------------------- step 3: report_stale_references

head_ "References to the old path"
# LISTED, NEVER REWRITTEN. Some of these are stale pointers and some are
# historical record -- "the bug was in /old/path/x" stays true after the move,
# and a mass replace turns a correct sentence into a false one. Only a person
# reading them can tell which is which.
if [ -n "$FROM" ]; then
  hits="$(grep -rIl -- "$FROM" "$NEW" 2>/dev/null | head -20)"
  n="$(printf '%s' "$hits" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    ok "no file mentions $FROM"
  else
    note "$n file(s) mention the old path. NOT rewritten — some are history, and only you can tell:"
    printf '%s\n' "$hits" | sed 's|^|    |'
    note "review them with:  grep -rn -- '$FROM' '$NEW'"
  fi
else
  note "old path unknown (--old-slug was used), so references were not searched"
fi

# A project's history is often spread over more than one profile -- that is the
# situation migrate-workspace exists for. Renaming here fixes ONE of them, and
# the others keep pointing at a path that no longer exists, invisibly. Say so;
# do not touch them, because each is its own decision.
head_ "The same workspace under other profiles"
others=0
while IFS= read -r other; do
  [ -n "$other" ] || continue
  [ -d "$other/projects/$OLD_SLUG" ] || continue
  case "$other" in "$PROFILE_DIR") continue ;; esac
  n=$(find "$other/projects/$OLD_SLUG" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
  note "$other still holds $OLD_SLUG ($n transcript(s)) — rename it too:"
  note "  rename-workspace.sh <that profile> --from '$FROM' --to '$TO'"
  others=$((others + 1))
done <<EOF
$(find "$CLAUDE_PROFILES" -mindepth 1 -maxdepth "${AGSWT_MAX_DEPTH:-4}" -type d -name projects 2>/dev/null | sed 's|/projects$||'; printf '%s\n' "$CLAUDE_DEFAULT")
EOF
[ "$others" -eq 0 ] && ok "no other profile holds this slug"

printf '\n'
if [ "$problems" -eq 0 ]; then
  printf 'rename-workspace: renamed, every session id accounted for\n'
  exit 0
fi
printf 'rename-workspace: %d item(s) need attention\n' "$problems"
exit 1
