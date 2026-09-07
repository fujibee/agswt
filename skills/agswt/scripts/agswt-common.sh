# agswt-common.sh — sourced by every agswt script. Not executable on its own.
#
# ONE definition of where profiles live. It used to be a literal in each
# script, which is a rename waiting to go half-done: the scripts that were
# updated and the ones that were not would read different roots and each
# report, correctly and uselessly, that the other's profiles do not exist.

# Default root. Override for a whole shell with AGSWT_PROFILES_ROOT, the same
# way AGSWT_MAX_DEPTH overrides the recursion limit.
AGSWT_DEFAULT_PROFILES_ROOT="$HOME/.claude_profiles"

agswt_profiles_root() {
  printf '%s' "${AGSWT_PROFILES_ROOT:-$AGSWT_DEFAULT_PROFILES_ROOT}"
}

# For the scripts that READ profiles. A root that does not exist and a root
# holding no profiles produce the same empty listing, and the difference is
# the whole answer: one means "nothing set up yet", the other means "you are
# pointed at the wrong place" -- which is exactly what happens on a machine
# whose profiles predate this default. So say which one it is, and name the
# override in the same breath.
agswt_require_profiles_root() {
  root="$(agswt_profiles_root)"
  [ -d "$root" ] && { printf '%s' "$root"; return 0; }
  printf 'agswt: no profiles root at %s\n' "$root" >&2
  if [ -n "${AGSWT_PROFILES_ROOT:-}" ]; then
    printf '  (AGSWT_PROFILES_ROOT is set to that path; it does not exist)\n' >&2
  else
    printf '  That is the default. If your profiles live somewhere else, point at it:\n' >&2
    printf '    export AGSWT_PROFILES_ROOT=<dir>\n' >&2
    printf '  Or create the first profile:  create-profile.sh <name>\n' >&2
  fi
  return 1
}

# ---------------------------------------------------------------------- codex
#
# Codex has the same shape one level down: one signed-in account per
# CODEX_HOME (default ~/.codex). Its profiles live under a SEPARATE root,
# mirrored by name -- <codex-root>/work/acme is the Codex half of the profile
# "work/acme", and <claude-root>/work/acme the Claude half. Two roots rather than
# a tool subdirectory inside one profile because the Claude discovery rule
# ("a directory holding .claude.json is a profile; a directory without one is
# a group") would read a codex/ subdirectory as a group and descend into it.
AGSWT_DEFAULT_CODEX_PROFILES_ROOT="$HOME/.codex_profiles"
AGSWT_CODEX_DEFAULT="$HOME/.codex"

agswt_codex_profiles_root() {
  printf '%s' "${AGSWT_CODEX_PROFILES_ROOT:-$AGSWT_DEFAULT_CODEX_PROFILES_ROOT}"
}

# What makes a directory a Codex profile. auth.json is the account (written by
# `codex login`); config.toml is what create-profile seeds before any sign-in.
# Either marks an INTENDED profile -- an unsigned one must still be listed, so
# that report can print its sign-in command instead of letting it vanish.
agswt_is_codex_profile() {
  [ -f "$1/auth.json" ] || [ -f "$1/config.toml" ]
}

# Every Codex profile under the root, depth-capped, one path per line. The
# recursion rule mirrors the Claude one: a profile's own subdirectories are
# not candidates (sessions/, skills/, plugins/ hold hundreds of directories),
# and a directory that is not a profile is a group whose children are tried.
agswt_codex_profiles() {
  local root; root="$(agswt_codex_profiles_root)"
  [ -d "$root" ] || return 0
  local max="${AGSWT_MAX_DEPTH:-4}"
  _agswt_codex_scan() {
    local dir="$1" depth="$2" sub
    [ "$depth" -gt "$max" ] && return 0
    if agswt_is_codex_profile "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
    while IFS= read -r sub; do
      [ -n "$sub" ] && _agswt_codex_scan "$sub" "$((depth + 1))"
    done <<INNER
$(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | sort)
INNER
  }
  local d
  while IFS= read -r d; do
    [ -n "$d" ] && _agswt_codex_scan "$d" 1
  done <<OUTER
$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
OUTER
}

# Resolve a profile NAME to its Codex directory, the way the Claude scripts
# resolve one against CLAUDE_PROFILES: absolute paths pass through.
agswt_codex_profile_dir() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    default) printf '%s' "$AGSWT_CODEX_DEFAULT" ;;
    *) printf '%s/%s' "$(agswt_codex_profiles_root)" "$1" ;;
  esac
}
