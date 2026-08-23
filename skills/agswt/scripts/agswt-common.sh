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
