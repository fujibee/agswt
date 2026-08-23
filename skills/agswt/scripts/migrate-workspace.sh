#!/usr/bin/env bash
# agswt migrate-workspace — copy one project's history from one profile to another.
#
# Implements assets/WORKFLOW.yaml migrate-workspace, steps 1-8. Read
# references/manifest.md before changing anything here: this is the operation
# that loses things, and every category below is one somebody has lost.
#
# COPIES, NEVER MOVES. The source is left exactly as it was found and the
# deletion is handed to a human (step 8). An agent that deletes the only copy
# of a history to "finish" a migration has not finished it.
#
# Usage:
#   migrate-workspace.sh --from <profile> --to <profile> --project <abs-path>
#   migrate-workspace.sh --from <profile> --to <profile> --slug <slug>
#     --dry-run     report what would happen, write nothing
#     --verify-only check an existing migration; copy nothing, then verify
#     --stage <dir> world-readable staging dir (cross-user copies, step 3)
#
# <profile> is a directory under the profiles root, or an absolute path.
set -uo pipefail

CLAUDE_DEFAULT="$HOME/.claude"

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/agswt-common.sh"
CLAUDE_PROFILES="$(agswt_profiles_root)"
AGSWT_VERSION="$(cat "$_here/../VERSION" 2>/dev/null | tr -d '[:space:]')"

agswt_require_profiles_root >/dev/null || exit 2
problems=0
note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*"; problems=$((problems + 1)); }
die()   { printf 'migrate-workspace: %s\n' "$*" >&2; exit 2; }
head_() { printf '\n== %s\n' "$*"; }

FROM=""; TO=""; PROJECT=""; SLUG=""; DRY=0; STAGE=""; VERIFY_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from)    FROM="${2:?--from needs a profile}"; shift 2 ;;
    --to)      TO="${2:?--to needs a profile}"; shift 2 ;;
    --project) PROJECT="${2:?--project needs a path}"; shift 2 ;;
    --slug)    SLUG="${2:?--slug needs a slug}"; shift 2 ;;
    --stage)   STAGE="${2:?--stage needs a dir}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

printf 'agswt migrate-workspace — version %s\n' "${AGSWT_VERSION:-unknown}"
[ -n "$FROM" ] && [ -n "$TO" ] || die "--from and --to are required"
[ -n "$PROJECT" ] || [ -n "$SLUG" ] || die "one of --project or --slug is required"

resolve_profile() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    default|"$CLAUDE_DEFAULT") printf '%s' "$CLAUDE_DEFAULT" ;;
    *)  printf '%s/%s' "$CLAUDE_PROFILES" "$1" ;;
  esac
}
SRC_PROFILE="$(resolve_profile "$FROM")"
DST_PROFILE="$(resolve_profile "$TO")"
[ -d "$SRC_PROFILE" ] || die "source profile not found: $SRC_PROFILE"
[ -d "$DST_PROFILE" ] || die "destination profile not found: $DST_PROFILE"
[ "$SRC_PROFILE" != "$DST_PROFILE" ] || die "source and destination are the same profile"

# ------------------------------------------------------- step 1: compute_slugs

head_ "Slug"
if [ -z "$SLUG" ]; then
  # The slug is the absolute path with every '/' replaced by '-'. Derived from
  # the path as given, NOT from a realpath: a moved directory keeps its old
  # slug, and silently following the move would address a workspace that does
  # not hold the history being asked about. rename-workspace is that job.
  case "$PROJECT" in
    /*) : ;;
    *)  die "--project must be an absolute path (got: $PROJECT)" ;;
  esac
  SLUG="$(printf '%s' "$PROJECT" | tr '/' '-')"
fi
note "slug = $SLUG"
SRC="$SRC_PROFILE/projects/$SLUG"
DST="$DST_PROFILE/projects/$SLUG"
[ -d "$SRC" ] || die "no such workspace in the source profile: $SRC"
note "source      = $SRC"
note "destination = $DST"

# --------------------------------------------------- step 2: inventory_source

head_ "Source inventory"
# Counted per category on purpose. A single total hides a category that came
# across as zero -- which is exactly how a migration reports success and loses
# every sidecar.
count_mem() { find "$1/memory" -type f 2>/dev/null | wc -l | tr -d ' '; }
count_tx()  { find "$1" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' '; }
count_side(){ find "$1" -mindepth 1 -maxdepth 1 -type d ! -name memory 2>/dev/null | wc -l | tr -d ' '; }

s_mem="$(count_mem "$SRC")"; s_tx="$(count_tx "$SRC")"; s_side="$(count_side "$SRC")"
note "memory files       $s_mem"
note "transcripts        $s_tx"
note "sidecar dirs       $s_side"
[ "$((s_mem + s_tx + s_side))" -gt 0 ] || die "source workspace holds nothing to migrate"

# The session ids this workspace owns, by transcript file name. Recorded BEFORE
# anything is written, so verification can ask "did these arrive?" rather than
# "do the totals look similar?" -- and can find them under any profile and any
# slug, which is the blind spot that made doctor call healthy machines broken.

SRC_IDS="$(mktemp)"; trap 'rm -f "$SRC_IDS"' EXIT INT TERM
find "$SRC" -maxdepth 1 -name '*.jsonl' 2>/dev/null \
  | while IFS= read -r f; do basename "$f" .jsonl; done | sort > "$SRC_IDS"

if [ "$DRY" -eq 1 ]; then
  head_ "Dry run"
  note "nothing was written. Re-run without --dry-run to copy."
  exit 0
fi

# --verify-only exists because the copy below runs unconditionally, so a plain
# re-run REPAIRS the destination and then checks it -- and reports a clean
# result it just created. That makes the check useless for the question people
# actually ask afterwards ("did last week's migration keep everything?"):
# measured by deleting a transcript from the destination and re-running, which
# said all session ids were present because it had put the file back a second
# earlier. Skipping the copy is what lets verification observe rather than
# participate.
if [ "$VERIFY_ONLY" -eq 0 ]; then

# ------------------------------------------------- step 3: stage_if_cross_user

head_ "Copy"
src_owner="$(stat -f %Su "$SRC" 2>/dev/null || stat -c %U "$SRC" 2>/dev/null || echo '?')"
dst_owner="$(stat -f %Su "$DST_PROFILE" 2>/dev/null || stat -c %U "$DST_PROFILE" 2>/dev/null || echo '?')"
if [ "$src_owner" != "$dst_owner" ]; then
  # Transcripts are mode 0600, so a cross-user copy cannot read them without a
  # world-readable staging step run BY THE SOURCE USER. This script cannot
  # become that user, so it stops rather than producing a partial copy.
  if [ -z "$STAGE" ]; then
    die "source is owned by '$src_owner' and destination by '$dst_owner'. Transcripts are mode 0600, so the SOURCE user must stage them first:
    mkdir -p /tmp/agswt-stage && cp '$SRC'/*.jsonl /tmp/agswt-stage/ && chmod -R a+r /tmp/agswt-stage
  then re-run with --stage /tmp/agswt-stage"
  fi
  note "cross-user copy, reading transcripts from $STAGE"
fi

mkdir -p "$DST" || die "cannot create $DST"

# ---------------------------------------------------------------- step 4: copy
copied_mem=0
if [ -d "$SRC/memory" ]; then
  mkdir -p "$DST/memory"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$SRC/memory/"}"
    mkdir -p "$DST/memory/$(dirname "$rel")"
    # MEMORY.md is merged in step 5, never overwritten here.
    [ "$rel" = "MEMORY.md" ] && continue
    cp -p "$f" "$DST/memory/$rel" && copied_mem=$((copied_mem + 1))
  done <<EOF
$(find "$SRC/memory" -type f 2>/dev/null)
EOF
fi

tx_src="$SRC"; [ -n "$STAGE" ] && tx_src="$STAGE"
copied_tx=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  cp -p "$f" "$DST/$base" 2>/dev/null || { warn "could not copy $base"; continue; }
  # Mode and mtime are both restored: staging destroys the mode, and the
  # session picker orders by mtime, so a copy that arrives with today's
  # timestamps reorders somebody's whole history.
  chmod 600 "$DST/$base" 2>/dev/null || true
  copied_tx=$((copied_tx + 1))
done <<EOF
$(find "$tx_src" -maxdepth 1 -name '*.jsonl' 2>/dev/null)
EOF

copied_side=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  cp -Rp "$d" "$DST/" 2>/dev/null && copied_side=$((copied_side + 1))
done <<EOF
$(find "$SRC" -mindepth 1 -maxdepth 1 -type d ! -name memory 2>/dev/null)
EOF
note "copied: memory $copied_mem, transcripts $copied_tx, sidecars $copied_side"

# ------------------------------------------------------- step 5: merge_indexes

head_ "Memory index"
SRC_IDX="$SRC/memory/MEMORY.md"; DST_IDX="$DST/memory/MEMORY.md"
if [ -f "$SRC_IDX" ]; then
  if [ -f "$DST_IDX" ]; then
    # Append what the destination does not already carry, line by line. A
    # re-run must not double the entries, so this is a set union and not a
    # concatenation -- and the destination's own lines keep their order.
    added=0
    tmp="$(mktemp)"
    cp "$DST_IDX" "$tmp"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      grep -Fqx -- "$line" "$tmp" || { printf '%s\n' "$line" >> "$tmp"; added=$((added + 1)); }
    done < "$SRC_IDX"
    mv "$tmp" "$DST_IDX"
    note "MEMORY.md merged: $added new line(s) appended, existing lines untouched"
  else
    cp -p "$SRC_IDX" "$DST_IDX"
    note "MEMORY.md copied (destination had none)"
  fi
fi

else
  head_ "Copy"
  note "skipped (--verify-only): the destination is being observed, not written"
fi

# ------------------------------------------------------- step 6: verify_counts

head_ "Verification"
d_mem="$(count_mem "$DST")"; d_tx="$(count_tx "$DST")"; d_side="$(count_side "$DST")"
row() {
  if [ "$2" -ge "$3" ]; then ok "$1: source $3, destination $2"
  else warn "$1: source $3, destination $2 — SHORT BY $((3 - 2))"; fi
}
row "memory files" "$d_mem" "$s_mem"
row "transcripts " "$d_tx" "$s_tx"
row "sidecar dirs" "$d_side" "$s_side"

# Counts agreeing is not the same as the right files arriving. Every session id
# recorded in step 2 is looked for BY NAME, and looked for across every profile
# and every slug -- a transcript that landed under a different slug is present
# on this machine and must not be reported as lost.
missing=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if [ -f "$DST/$id.jsonl" ]; then continue
  fi
  elsewhere="$(find "$CLAUDE_PROFILES" "$CLAUDE_DEFAULT" -type f -name "$id.jsonl" 2>/dev/null | head -1)"
  if [ -n "$elsewhere" ]; then
    warn "session $id is not in the destination, but exists at $elsewhere"
  else
    warn "session $id did not arrive and is nowhere on this machine"
  fi
  missing=$((missing + 1))
done < "$SRC_IDS"
[ "$missing" -eq 0 ] && ok "all $s_tx session id(s) present in the destination by name"

# --------------------------------------------------------- step 7: migrate_mcp

head_ "MCP servers"
# Two scopes, and the project one is the one that gets dropped. Reported rather
# than written: `claude mcp add-json` is the supported route and a running
# client rewrites .claude.json, so an edit from here can be clobbered.
SRC_JSON="$SRC_PROFILE/.claude.json"
if [ -f "$SRC_JSON" ] && [ -n "$PROJECT" ]; then
  python3 - "$SRC_JSON" "$PROJECT" <<'PY' || note "could not read .claude.json"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("  could not parse .claude.json (%s)" % e); sys.exit(0)
user = list((d.get("mcpServers") or {}))
proj = list(((d.get("projects") or {}).get(sys.argv[2]) or {}).get("mcpServers") or {})
print("  user scope   : %s" % (", ".join(user) or "none"))
print("  project scope: %s" % (", ".join(proj) or "none"))
if user or proj:
    print("  Not registered automatically. For each, in the destination profile:")
    for n in user:
        print("    claude mcp add-json %s '<json>' -s user" % n)
    for n in proj:
        print("    (from inside the project) claude mcp add-json %s '<json>' -s local" % n)
PY
else
  note "no .claude.json in the source profile, or --slug was used without --project"
fi

# ---------------------------------------------------- step 8: hand_off_deletion

head_ "Source"
sz="$(du -sh "$SRC" 2>/dev/null | cut -f1)"
note "$SRC still holds ${sz:-?} — memory $s_mem, transcripts $s_tx, sidecars $s_side"
note "NOTHING HAS BEEN DELETED. Removing the source is a human's decision."

# WHICH ACCOUNT DID THIS LAND IN. Someone arriving straight at migrate never
# passes wire-direnv or report, so nothing else in their path ever names the
# destination's account -- and moving history into the wrong one looks exactly
# like moving it into the right one. Read from the profile's own file; a name
# is not worth touching a credential for.
head_ "Destination account"
dst_email="$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print((d.get("oauthAccount") or {}).get("emailAddress") or "")' "$DST_PROFILE/.claude.json" 2>/dev/null)"
if [ -n "$dst_email" ]; then
  note "$TO is signed in as $dst_email"
else
  note "$TO is not signed in yet — it will ask at the first launch in a directory bound to it"
fi

printf '\n'
if [ "$problems" -eq 0 ]; then
  printf 'migrate-workspace: copied, every category and every session id verified\n'
  exit 0
fi
printf 'migrate-workspace: %d item(s) need attention\n' "$problems"
exit 1
