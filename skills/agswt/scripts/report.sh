#!/usr/bin/env bash
# agswt report — subscription usage for every account on this machine.
#
# Reads each profile by asking the claude binary, so this script never touches
# a credential and never calls the usage endpoint itself:
#
#     CLAUDE_CONFIG_DIR=<dir> claude -p "/usage" --output-format json
#
# Exists as a script rather than as workflow steps because an agent improvising
# these calls is slow and fragile: one run assembled them by hand and spent
# minutes on timeouts and retries. The invocation below is fixed on purpose.
#
# Usage: report.sh [--json] [--dir PATH]...
set -uo pipefail

CLAUDE_DEFAULT="$HOME/.claude"
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/agswt-common.sh"
CLAUDE_PROFILES="$(agswt_profiles_root)"
AGSWT_VERSION="$(cat "$_here/../VERSION" 2>/dev/null | tr -d '[:space:]')"

AS_JSON=0
agswt_require_profiles_root >/dev/null || exit 2

DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) AS_JSON=1; shift ;;
    --dir)  DIRS+=("${2:?--dir needs a path}"); shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) printf 'report: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ "$AS_JSON" -eq 1 ] || printf 'agswt report — version %s\n' "${AGSWT_VERSION:-unknown}"

if [ "${#DIRS[@]}" -eq 0 ]; then
  [ -d "$CLAUDE_DEFAULT" ] && DIRS+=("$CLAUDE_DEFAULT")
  # ONE RULE, applied recursively: a directory holding .claude.json IS a
  # profile; a directory without one is a group, and its children are searched.
  # Both can be true of the same directory -- a group that is itself signed in
  # -- and that falls out of the rule rather than needing a case of its own.
  #
  # Structured names come from this: <profiles-root>/work/oma is the profile
  # "work/oma", and nothing has to know that "work" is special.
  #
  # A profile's OWN subdirectories are not candidates. Descending into them
  # found 130+ plugin and marketplace directories on this machine and drowned
  # the table in depth warnings -- the recursion is for finding sibling
  # profiles under a group, not for walking the inside of one.
  #
  # Depth is capped because the rule alone would follow a symlink loop or walk
  # a home directory somebody parked here. Hitting the cap is reported, never
  # silently truncated: an account that exists and is not listed is the one
  # failure this report cannot afford.
  AGSWT_MAX_DEPTH="${AGSWT_MAX_DEPTH:-4}"
  DEPTH_HITS=""
  scan() {
    local dir="$1" depth="$2" sub
    if [ "$depth" -gt "$AGSWT_MAX_DEPTH" ]; then
      DEPTH_HITS="${DEPTH_HITS}${DEPTH_HITS:+, }${dir}"
      return 0
    fi
    # .claude.json ALONE DOES NOT MAKE A PROFILE. The client writes one
    # wherever it runs, so the file marks "something ran here" as much as it
    # marks an account. The two are told apart by oauthAccount: a real profile
    # carries one (measured: 26-66 keys with the block), a bare footprint does
    # not (10 keys, no block).
    #
    #   has children, no oauthAccount  -> a GROUP. No row, no sign-in advice:
    #                                     inviting somebody to sign in to a
    #                                     footprint is a wrong instruction.
    #   no children, .claude.json      -> a profile. Unsigned shows as
    #                                     unreadable WITH the sign-in command,
    #                                     because an intended-but-empty profile
    #                                     must not vanish.
    #   has oauthAccount               -> a profile, children or not.
    local kids has_acct=1
    kids="$(find "$dir" -mindepth 2 -maxdepth 2 -name .claude.json 2>/dev/null | head -1)"
    grep -q '"oauthAccount"' "$dir/.claude.json" 2>/dev/null || has_acct=0
    if [ -f "$dir/.claude.json" ] && { [ "$has_acct" -eq 1 ] || [ -z "$kids" ]; }; then
      DIRS+=("$dir")
    fi
    while IFS= read -r sub; do
      [ -n "$sub" ] && scan "$sub" "$((depth + 1))"
    done <<INNER
$(find "$dir" -mindepth 1 -maxdepth 1 -type d \
    ! -name projects ! -name memory ! -name plugins ! -name skills \
    ! -name commands ! -name todos ! -name statsig ! -name shell-snapshots \
    ! -name backups ! -name sessions ! -name '.*' 2>/dev/null | sort)
INNER
  }
  while IFS= read -r d; do
    [ -n "$d" ] && scan "$d" 1
  done <<EOF
$(find "$CLAUDE_PROFILES" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
EOF
  [ -z "$DEPTH_HITS" ] || printf '  [warn] stopped at depth %s, not searched: %s\n' \
    "$AGSWT_MAX_DEPTH" "$DEPTH_HITS"
fi
[ "${#DIRS[@]}" -gt 0 ] || { printf 'report: %s exists but holds no profiles\n' "$CLAUDE_PROFILES" >&2; exit 2; }

python3 - "$AS_JSON" "$CLAUDE_DEFAULT" "$CLAUDE_PROFILES" "${DIRS[@]}" <<'PY'
import json, os, re, subprocess, sys, datetime as dt

as_json = sys.argv[1] == "1"
default_dir = sys.argv[2]
profiles_root = sys.argv[3]
dirs = sys.argv[4:]


def label(d):
    """How a profile is named to a person: its path under the profiles root,
    so a nested profile reads as "work/oma" rather than an absolute path or a
    bare leaf that collides with its sibling group."""
    a = os.path.abspath(d)
    root = os.path.abspath(profiles_root)
    if a.startswith(root + os.sep):
        return a[len(root) + 1:]
    if a == os.path.abspath(default_dir):
        return "(default)"
    return a.replace(os.path.expanduser("~"), "~")

# 180s, not 120. Measured: a batch run left two profiles unanswered at 120 and
# both returned immediately when asked again one at a time, so the ceiling was
# the deadline rather than the account. Overridable for a slower machine.
TIMEOUT = int(os.environ.get("AGSWT_TIMEOUT", "180"))

# READING USAGE MUST NOT WRITE INTO THE ACCOUNT BEING READ.
# Asking the binary starts a real session, and a real session creates
# projects/<slug-of-the-cwd>/ in that profile -- so a read-only-looking report
# left a workspace and a transcript in EVERY account it polled, named after
# wherever the operator happened to run it. Two parts to stopping that:
#   1. --no-session-persistence, which suppresses the transcript.
#   2. a fixed cwd, so the directory that is still created is ONE predictable
#      one per profile instead of a fresh one per invocation location.
# $HOME is the choice: it always exists (nothing to create), it is the same on
# every run, and in most profiles that slug is already present -- so the usual
# outcome is no new directory at all. The empty directory that can remain is
# accepted deliberately; the binary creates it before any flag is consulted.
QUERY_CWD = os.path.expanduser("~")

QUOTA = re.compile(
    r'^Current (?:(session)|week \(([^)]*)\)):\s*(\d+(?:\.\d+)?)%\s*used'
    r'(?:\s*·\s*resets\s+(.+?))?\s*$', re.M)


def env_for(d):
    """CLAUDE_CONFIG_DIR must be UNSET for the default directory. Setting it to
    that same path is not a no-op: the client then looks for a hashed keychain
    item that only exists for non-default dirs and reports a null identity for
    a perfectly good account."""
    e = dict(os.environ)
    if os.path.abspath(d) == os.path.abspath(default_dir):
        e.pop("CLAUDE_CONFIG_DIR", None)
    else:
        e["CLAUDE_CONFIG_DIR"] = d
    return e


def signin_hint(d):
    base = "claude auth login --claudeai"
    return base if os.path.abspath(d) == os.path.abspath(default_dir) \
        else f"CLAUDE_CONFIG_DIR={d} {base}"


def ask(d, attempts=2):
    """Quota windows for one profile, or (None, why).

    stdin is closed and stderr discarded: with a terminal attached the call can
    sit waiting instead of answering. Only the FIRST stdout line is parsed --
    a profile carrying MCP servers can print other lines around the JSON, and
    json.loads over the whole stream then fails on output that did contain a
    perfectly good answer.

    Two attempts because a single call has come back with the session cost
    summary and no quota line at all, and because a batch run left two profiles
    unanswered that returned immediately when asked again.
    """
    why = "no attempt made"
    for _ in range(attempts):
        try:
            r = subprocess.run(
                ["claude", "-p", "/usage", "--output-format", "json",
                 "--no-session-persistence"],
                env=env_for(d), cwd=QUERY_CWD, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            why = f"timed out after {TIMEOUT}s"; continue
        except OSError as e:
            why = f"claude did not run ({e})"; continue
        first = (r.stdout or "").strip().splitlines()
        if not first:
            why = "no output"; continue
        try:
            payload = json.loads(first[0])
        except ValueError:
            why = f"first line was not JSON: {first[0][:120]!r}"; continue
        text = payload.get("result") or ""
        out = {}
        for m in QUOTA.finditer(text):
            # Model-specific rows ("Current week (Fable)") are dropped: this
            # report has two columns and 7d comes from "all models".
            # Chosen, not overlooked.
            key = "session" if m.group(1) else (m.group(2) or "").strip()
            if key in ("session", "all models"):
                out[key] = (float(m.group(3)), m.group(4))
        if out:
            return out, None
        why = "no quota line in the response"
    return None, why


def account_of(d):
    try:
        with open(os.path.join(d, ".claude.json")) as fh:
            acct = json.load(fh).get("oauthAccount") or {}
        if acct.get("emailAddress"):
            return acct["emailAddress"]
    except (ValueError, OSError):
        pass
    # The long-lived default directory has no oauthAccount block, so without
    # this it reports as ".claude" and cannot be deduplicated against the
    # profile signed into the same account.
    try:
        r = subprocess.run(["claude", "auth", "status", "--json"], env=env_for(d),
                           cwd=QUERY_CWD,
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, timeout=60)
        if r.returncode == 0:
            email = (json.loads(r.stdout) or {}).get("email")
            if email:
                return email
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return None


def parse_reset(text):
    if not text:
        return None
    m = re.match(r'([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*([ap]m)',
                 text.strip())
    if not m:
        return None
    months = {n: i for i, n in enumerate(
        "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)}
    hour = int(m.group(3)) % 12 + (12 if m.group(5) == "pm" else 0)
    now = dt.datetime.now().astimezone()
    try:
        t = now.replace(month=months[m.group(1)], day=int(m.group(2)), hour=hour,
                        minute=int(m.group(4) or 0), second=0, microsecond=0)
    except (ValueError, KeyError):
        return None
    if t < now - dt.timedelta(days=1):
        try:
            t = t.replace(year=t.year + 1)
        except ValueError:
            return None
    return t


def fmt_reset(text):
    """Absolute time plus a countdown, degrading to the phrase itself.

    An unparseable phrase is printed verbatim rather than dropped: a locale
    change should cost the countdown, not the line."""
    if not text:
        return "-"
    t = parse_reset(text)
    if t is None:
        return text
    secs = int((t - dt.datetime.now().astimezone()).total_seconds())
    if secs < 0:
        return f"{t:%m-%d %H:%M} (past)"
    d, rem = divmod(secs, 86400)
    h, m = rem // 3600, rem % 3600 // 60
    span = f"{d}d{h:02d}h{m:02d}m" if d else f"{h}h{m:02d}m"
    return f"{t:%m-%d %H:%M} (in {span})"


rows = []
for d in dirs:
    windows, why = ask(d)
    acct = account_of(d)
    row = {"config_dir": d, "account": acct or label(d),
           "identified": acct is not None}
    # PLAN is not available: the subscription name lived in the credential
    # blob, which is no longer read, and the prose does not carry it. The
    # column stays so it fills itself in if the binary ever reports one.
    row["plan"] = None
    if windows is None:
        row.update(status=f"usage unreadable ({why}) — sign in with: {signin_hint(d)}",
                   five=None, seven=None, five_r=None, seven_r=None)
    else:
        five, seven = windows.get("session"), windows.get("all models")
        row.update(five=five[0] if five else None, seven=seven[0] if seven else None,
                   five_r=five[1] if five else None, seven_r=seven[1] if seven else None)
        gaps = [n for n, v in (("5h", five), ("7d", seven)) if v is None]
        row["status"] = "ok" if not gaps else "read, but no " + "/".join(gaps) + " line"
    rows.append(row)

# One line per ACCOUNT, not per directory -- but the directories folded into
# each line are named. Several profiles signed into one account is a hygiene
# problem worth seeing, and collapsing them silently is what hides it.
merged = {}
for r in rows:
    key = r["account"] if r["identified"] else "dir:" + r["config_dir"]
    if key in merged:
        merged[key]["dirs"].append(r["config_dir"])
        continue
    r["dirs"] = [r["config_dir"]]
    merged[key] = r
rows = list(merged.values())

if as_json:
    print(json.dumps(rows, indent=2, ensure_ascii=False))
    sys.exit(0)

w = max([len(r["account"]) for r in rows] + [7])
print(f"{'ACCOUNT'.ljust(w)}  {'PLAN':<6} {'5H':>5} {'7D':>5}  "
      f"{'5H RESETS':<23} {'7D RESETS':<23} STATUS")
problems = 0
for r in rows:
    f5 = "-" if r["five"] is None else f"{r['five']:.0f}%"
    f7 = "-" if r["seven"] is None else f"{r['seven']:.0f}%"
    status = "" if r["status"] == "ok" else r["status"]
    if status:
        problems += 1
    print(f"{r['account'].ljust(w)}  {'-':<6} {f5:>5} {f7:>5}  "
          f"{fmt_reset(r['five_r']):<23} {fmt_reset(r['seven_r']):<23} {status}".rstrip())
    if len(r["dirs"]) > 1:
        print(f"{'':<{w}}  same account in {len(r['dirs'])} profiles: "
              + ", ".join(label(d) for d in r["dirs"]))

sys.exit(1 if problems else 0)
PY
