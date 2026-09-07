#!/usr/bin/env bash
# agswt report — subscription usage for every account on this machine.
#
# Reads each profile by asking the vendor's own binary, so this script never
# touches a credential and never calls a usage endpoint itself:
#
#     CLAUDE_CONFIG_DIR=<dir> claude -p "/usage" --output-format json
#     CODEX_HOME=<dir>        codex app-server   (account/read, account/rateLimits/read
#                                                 over stdio -- see codex-ask.py)
#
# Exists as a script rather than as workflow steps because an agent improvising
# these calls is slow and fragile: one run assembled them by hand and spent
# minutes on timeouts and retries. The invocations are fixed on purpose.
#
# Usage: report.sh [--md | --json] [--tool claude|codex] [--dir PATH]...
#   --md    a Markdown table — THE FORM TO SHOW A PERSON. Paste it as is.
#   --json  machine-readable rows
#   --tool  restrict to one tool (default: every tool that has a profile here)
#   --dir   report one directory; its tool is read from its contents
set -uo pipefail

CLAUDE_DEFAULT="$HOME/.claude"
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/agswt-common.sh"
CLAUDE_PROFILES="$(agswt_profiles_root)"
CODEX_PROFILES="$(agswt_codex_profiles_root)"
CODEX_DEFAULT="$AGSWT_CODEX_DEFAULT"
AGSWT_VERSION="$(cat "$_here/../VERSION" 2>/dev/null | tr -d '[:space:]')"

AS_JSON=0
AS_MD=0
TOOL=all
DIRS=()        # claude config directories
CODEX_DIRS=()  # codex homes
while [ $# -gt 0 ]; do
  case "$1" in
    --json) AS_JSON=1; shift ;;
    --md)   AS_MD=1; shift ;;
    --tool) TOOL="${2:?--tool needs claude or codex}"; shift 2
            case "$TOOL" in claude|codex) ;; *) printf 'report: --tool must be claude or codex, not %s\n' "$TOOL" >&2; exit 2 ;; esac ;;
    --dir)  d="${2:?--dir needs a path}"; shift 2
            # A directory names its own tool by what it holds. Guessing from
            # the flag alone would send a Codex home to the claude binary,
            # which answers "sign in" for a perfectly good account.
            if [ -f "$d/.claude.json" ]; then DIRS+=("$d")
            elif agswt_is_codex_profile "$d"; then CODEX_DIRS+=("$d")
            else DIRS+=("$d"); fi ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) printf 'report: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ "$AS_JSON" -eq 1 ] || [ "$AS_MD" -eq 1 ] || printf 'agswt report — version %s\n' "${AGSWT_VERSION:-unknown}"

# Whether directories were named on the command line, decided BEFORE discovery
# fills either list. Testing "both lists empty" at each discovery step instead
# meant that finding the Claude profiles switched the Codex discovery off.
EXPLICIT=0
[ "$(( ${#DIRS[@]} + ${#CODEX_DIRS[@]} ))" -gt 0 ] && EXPLICIT=1

# The Claude root is required only when Claude is the ONLY tool asked for. A
# machine that runs Codex alone has no ~/.claude_profiles and must not be
# told to create one before it can see its Codex accounts.
if [ "$TOOL" = claude ]; then
  agswt_require_profiles_root >/dev/null || exit 2
fi

if [ "$EXPLICIT" -eq 0 ] && [ "$TOOL" != codex ]; then
  [ -d "$CLAUDE_DEFAULT" ] && DIRS+=("$CLAUDE_DEFAULT")
  # ONE RULE, applied recursively: a directory holding .claude.json IS a
  # profile; a directory without one is a group, and its children are searched.
  # Both can be true of the same directory -- a group that is itself signed in
  # -- and that falls out of the rule rather than needing a case of its own.
  #
  # Structured names come from this: <profiles-root>/work/acme is the profile
  # "work/acme", and nothing has to know that "work" is special.
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

# Codex: the default home plus every profile under the Codex root. Discovery
# lives in agswt-common.sh so that doctor and report cannot disagree about
# what a Codex profile is.
if [ "$EXPLICIT" -eq 0 ] && [ "$TOOL" != claude ]; then
  agswt_is_codex_profile "$CODEX_DEFAULT" && CODEX_DIRS+=("$CODEX_DEFAULT")
  while IFS= read -r d; do
    [ -n "$d" ] && CODEX_DIRS+=("$d")
  done <<EOF
$(agswt_codex_profiles)
EOF
fi

if [ "${#DIRS[@]}" -eq 0 ] && [ "${#CODEX_DIRS[@]}" -eq 0 ]; then
  case "$TOOL" in
    codex) printf 'report: no Codex profiles: neither %s nor anything under %s\n' "$CODEX_DEFAULT" "$CODEX_PROFILES" >&2 ;;
    *)     printf 'report: no profiles found under %s (Claude) or %s (Codex)\n' "$CLAUDE_PROFILES" "$CODEX_PROFILES" >&2
           [ -d "$CLAUDE_PROFILES" ] || agswt_require_profiles_root >/dev/null ;;
  esac
  exit 2
fi
# A Codex profile exists but the binary does not: say so once, and drop the
# rows rather than printing one "did not run" per profile.
if [ "${#CODEX_DIRS[@]}" -gt 0 ] && ! command -v codex >/dev/null 2>&1; then
  printf '  [warn] %d Codex profile(s) found but no codex binary on PATH; Codex rows skipped\n' "${#CODEX_DIRS[@]}" >&2
  CODEX_DIRS=()
fi

python3 - "$AS_JSON$AS_MD" "$CLAUDE_DEFAULT" "$CLAUDE_PROFILES" "$CODEX_DEFAULT" "$CODEX_PROFILES" "$_here" \
  --claude "${DIRS[@]+"${DIRS[@]}"}" --codex "${CODEX_DIRS[@]+"${CODEX_DIRS[@]}"}" <<'PY'
import json, os, re, subprocess, sys, datetime as dt

as_json = sys.argv[1][0] == "1"
as_md = sys.argv[1][1] == "1"
default_dir = sys.argv[2]
profiles_root = sys.argv[3]
codex_default = sys.argv[4]
codex_root = sys.argv[5]
here = sys.argv[6]
dirs, codex_dirs = [], []
bucket = None
for a in sys.argv[7:]:
    if a == "--claude": bucket = dirs; continue
    if a == "--codex": bucket = codex_dirs; continue
    bucket.append(a)


def label(d, tool="claude"):
    """How a profile is named to a person: its path under the profiles root,
    so a nested profile reads as "work/acme" rather than an absolute path or a
    bare leaf that collides with its sibling group."""
    a = os.path.abspath(d)
    root = os.path.abspath(codex_root if tool == "codex" else profiles_root)
    if a.startswith(root + os.sep):
        return a[len(root) + 1:]
    if a == os.path.abspath(codex_default if tool == "codex" else default_dir):
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
            # stderr captured separately (never mixed into stdout, which is
            # parsed): its last line is appended to a failure reason. From
            # inside Codex's sandbox every profile came back "no quota line"
            # and nothing said why (measured 2026-09-06).
            r = subprocess.run(
                ["claude", "-p", "/usage", "--output-format", "json",
                 "--no-session-persistence"],
                env=env_for(d), cwd=QUERY_CWD, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            why = f"timed out after {TIMEOUT}s"; continue
        except OSError as e:
            why = f"claude did not run ({e})"; continue
        err_lines = [l.strip() for l in (r.stderr or "").splitlines() if l.strip()]
        err_tail = (": " + re.sub(r"\x1b\[[0-9;]*m", "", err_lines[-1])[:200]) if err_lines else ""
        first = (r.stdout or "").strip().splitlines()
        if not first:
            why = "no output" + err_tail; continue
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
        why = "no quota line in the response" + err_tail
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
    change should cost the countdown, not the line. Codex hands over epoch
    seconds instead of a phrase; those take the same path after conversion."""
    if not text:
        return "-"
    if isinstance(text, (int, float)):
        t = dt.datetime.fromtimestamp(text).astimezone()
    else:
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
    row = {"tool": "claude", "config_dir": d, "account": acct or label(d),
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


def ask_codex(cdirs):
    """One codex-ask.py call for every Codex home; the JSON-RPC lives there."""
    if not cdirs:
        return []
    cmd = [sys.executable, os.path.join(here, "codex-ask.py"),
           "--timeout", str(TIMEOUT)] + cdirs
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True,
                           timeout=TIMEOUT * (len(cdirs) + 1))
    except (OSError, subprocess.TimeoutExpired) as e:
        return [{"config_dir": d, "email": None, "plan": None, "five": None,
                 "seven": None, "five_r": None, "seven_r": None,
                 "status": f"codex-ask did not answer ({e})"} for d in cdirs]
    out = []
    for line in (r.stdout or "").splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    # Every directory asked for gets a row, answered or not. A helper that
    # died mid-list must not make the remaining accounts silently vanish.
    seen = {o.get("config_dir") for o in out}
    for d in cdirs:
        if d not in seen:
            out.append({"config_dir": d, "email": None, "plan": None, "five": None,
                        "seven": None, "five_r": None, "seven_r": None,
                        "status": "no answer from codex-ask"})
    return out


for a in ask_codex(codex_dirs):
    d = a["config_dir"]
    row = {"tool": "codex", "config_dir": d, "account": a["email"] or label(d, "codex"),
           "identified": a["email"] is not None, "plan": a["plan"],
           "five": a["five"], "seven": a["seven"],
           "five_r": a["five_r"], "seven_r": a["seven_r"],
           "limits": a.get("limits") or [], "credits": a.get("credits")}
    if a["status"] == "not signed in":
        row["status"] = f"not signed in — sign in with: CODEX_HOME={d} codex login"
    elif a["status"] == "ok" or a["status"].startswith(("read, but", "limit reached")):
        row["status"] = a["status"]
    else:
        row["status"] = f"usage unreadable ({a['status']})"
    rows.append(row)
    # A second limit id (measured 2026-09-07: the Spark model on Pro Lite has
    # its own 5h and weekly windows) is its own row, named after the limit,
    # under the same account -- the TUI's /status shows it as a separate
    # block, and folding it into the account row would hide a model that
    # is out while the main limit reads 0%.
    for extra in row["limits"][1:]:
        rows.append({"tool": "codex", "config_dir": d,
                     "account": row["account"], "identified": row["identified"],
                     "plan": a["plan"], "five": extra["five"], "seven": extra["seven"],
                     "five_r": extra["five_r"], "seven_r": extra["seven_r"],
                     "limits": [], "credits": None,
                     "limit_name": extra["name"] or extra["limit_id"],
                     "status": (f"limit reached: {extra['reached']}" if extra["reached"]
                                else "ok")})

# One line per ACCOUNT, not per directory -- but the directories folded into
# each line are named. Several profiles signed into one account is a hygiene
# problem worth seeing, and collapsing them silently is what hides it.
# Keyed by tool AND account: the same e-mail on Claude and on Codex is two
# subscriptions, not one.
merged = {}
for r in rows:
    key = (r["tool"], r["account"] if r["identified"] else "dir:" + r["config_dir"],
           r.get("limit_name"))
    if key in merged:
        merged[key]["dirs"].append(r["config_dir"])
        continue
    r["dirs"] = [r["config_dir"]]
    merged[key] = r
rows = list(merged.values())

if as_json:
    print(json.dumps(rows, indent=2, ensure_ascii=False))
    sys.exit(0)

if as_md:
    # The form a person reads. An agent that runs this and then rewrites the
    # numbers into prose loses the alignment that makes four accounts
    # comparable at a glance; so the table is produced here, once, and the
    # instruction in SKILL.md is to paste it unchanged. Footnotes carry what
    # a cell cannot: the directories folded into one account row.
    print("| Account | Tool | Plan | 5h | 7d | 5h resets | 7d resets | Status |")
    print("|---|---|---|---:|---:|---|---|---|")
    notes, problems = [], 0
    for r in rows:
        f5 = "-" if r["five"] is None else f"{r['five']:.0f}%"
        f7 = "-" if r["seven"] is None else f"{r['seven']:.0f}%"
        status = "ok" if r["status"] == "ok" else r["status"].replace("|", "\\|")
        if r["status"] != "ok":
            problems += 1
        tool = r["tool"] + (f" · {r['limit_name']}" if r.get("limit_name") else "")
        print(f"| {r['account']} | {tool} | {r['plan'] or '-'} | {f5} | {f7} | "
              f"{fmt_reset(r['five_r'])} | {fmt_reset(r['seven_r'])} | {status} |")
        if len(r["dirs"]) > 1:
            notes.append(f"- {r['account']} ({r['tool']}): same account in {len(r['dirs'])} profiles — "
                         + ", ".join(label(d, r["tool"]) for d in r["dirs"]))
        c = r.get("credits")
        if c:
            notes.append(f"- {r['account']} (codex): monthly credits {c['used']:,.0f} of "
                         f"{c['limit']:,.0f} used ({c['remaining_percent']}% left), "
                         f"resets {fmt_reset(c['resets_at'])}")
    if notes:
        print()
        print("\n".join(notes))
    sys.exit(1 if problems else 0)

w = max([len(r["account"]) for r in rows] + [7])
print(f"{'ACCOUNT'.ljust(w)}  {'TOOL':<6} {'PLAN':<6} {'5H':>5} {'7D':>5}  "
      f"{'5H RESETS':<23} {'7D RESETS':<23} STATUS")
problems = 0
for r in rows:
    f5 = "-" if r["five"] is None else f"{r['five']:.0f}%"
    f7 = "-" if r["seven"] is None else f"{r['seven']:.0f}%"
    status = "" if r["status"] == "ok" else r["status"]
    if status:
        problems += 1
    print(f"{r['account'].ljust(w)}  {r['tool']:<6} {(r['plan'] or '-'):<6} {f5:>5} {f7:>5}  "
          f"{fmt_reset(r['five_r']):<23} {fmt_reset(r['seven_r']):<23} {status}".rstrip())
    if r.get("limit_name"):
        print(f"{'':<{w}}  ^ limit: {r['limit_name']}")
    if len(r["dirs"]) > 1:
        print(f"{'':<{w}}  same account in {len(r['dirs'])} profiles: "
              + ", ".join(label(d, r["tool"]) for d in r["dirs"]))
    c = r.get("credits")
    if c:
        print(f"{'':<{w}}  monthly credits {c['used']:,.0f} of {c['limit']:,.0f} used "
              f"({c['remaining_percent']}% left), resets {fmt_reset(c['resets_at'])}")

sys.exit(1 if problems else 0)
PY
