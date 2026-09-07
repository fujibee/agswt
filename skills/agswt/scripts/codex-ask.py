#!/usr/bin/env python3
"""agswt codex-ask — identity and rate limits for Codex profiles, from the binary.

    codex-ask.py [--timeout SECS] <codex-home>...

One JSON object per line, one per directory, in argument order:

    {"config_dir": ..., "email": ..., "plan": ..., "five": 22.0, "seven": 3.0,
     "five_r": 1788670242, "seven_r": 1789257042, "status": "ok",
     "limits": [{"limit_id": "codex", "name": null, "five": 22.0, ...},
                {"limit_id": "codex_bengalfox", "name": "GPT-5.3-Codex-Spark", ...}],
     "credits": {"limit": 3000, "used": 2335.7, "remaining_percent": 22,
                 "resets_at": 1790812800} | null}

`five`/`seven` are used-percent of the short (5h) and long (7d) windows of
the PRIMARY limit (`limits[0]`, the one the app server reports at top
level); `*_r` are their reset times in epoch seconds. A plan may have only
one window -- Pro Lite reports a weekly window and nothing shorter -- and
that is a fact about the plan, not a failed read, so `status` stays "ok"
with `five` null. `limits` carries every limit id the server returned
(measured 2026-09-07: a second id for the Spark model, with its own
windows). `credits` is the monthly credit pool the TUI shows as "Monthly
credit limit" (the server's `individualLimit`), or null when the plan has
none. `email`/`plan` are null when the profile is not signed in; the
windows are null when the limits could not be read, and `status` says why.

THIS IS THE ONE PLACE THAT SPEAKS TO CODEX. Every other script that wants a
Codex identity or usage calls this file, so the protocol lives in one spot.

Why the app server and not the session logs. Codex has no usage command in
the way `claude -p "/usage"` is one, and the earlier plan was to read the
`rate_limits` snapshots Codex writes into every session rollout. Measured
2026-09-05 (codex-cli 0.153.4): that source goes wrong the moment a window
is reset out of band. One rate-limit reset credit was consumed at 16:50 and
the rollouts on disk kept answering "7d 100%" from before it — the same
session file carries both the old and the new reset epoch, and the newest
line in the newest file is right only by luck of which session spoke last.
The app server returns what the server says now, for the account this
directory holds, and it is the vendor's own binary reading its own
credential — the same footing as `claude -p "/usage"`.

Method names, from `codex app-server generate-json-schema` (0.153.4):
`account/read` → {account: {type, email, planType} | null}, and
`account/rateLimits/read` → {rateLimits: {primary, secondary, ...}}. A
profile that is not signed in answers `account: null` and refuses the
rate-limit read with JSON-RPC error -32600 "authentication required".

The read is not write-free: the app server touches its sqlite WALs and
models_cache.json under CODEX_HOME, and in an empty directory it creates the
sqlite files, installation_id and skills/. It does NOT create a session or a
rollout (measured: sessions/ unchanged across three reads). Accepted, and
said here rather than hidden.
"""
import json
import os
import select
import subprocess
import sys
import time

TIMEOUT = 60
dirs = []
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == "--timeout":
        TIMEOUT = int(args.pop(0))
    elif a in ("-h", "--help"):
        print(__doc__.strip())
        sys.exit(0)
    else:
        dirs.append(a)
if not dirs:
    print("codex-ask: at least one CODEX_HOME directory is required", file=sys.stderr)
    sys.exit(2)

# Fixed cwd for the same reason report.sh fixes it for claude: whatever the
# binary decides to note about "the project it was started in" lands in ONE
# predictable place instead of a fresh one per invocation location.
QUERY_CWD = os.path.expanduser("~")


def rpc(o):
    return (json.dumps(o) + "\n").encode()


def stderr_tail(p):
    """Last non-empty stderr line of a finished process, cleaned of ANSI
    colour, or "" -- appended to a failure status so the reader gets the
    cause and not only the exit code."""
    import re
    try:
        err = p.stderr.read().decode("utf-8", "replace") if p.stderr else ""
    except Exception:
        return ""
    lines = [l.strip() for l in err.splitlines() if l.strip()]
    if not lines:
        return ""
    return re.sub(r"\x1b\[[0-9;]*m", "", lines[-1])[:200]


def ask(d):
    row = {"config_dir": d, "email": None, "plan": None,
           "five": None, "seven": None, "five_r": None, "seven_r": None,
           "status": None, "limits": [], "credits": None}
    env = dict(os.environ)
    # Setting CODEX_HOME to the default path is harmless for Codex (measured:
    # `CODEX_HOME=~/.codex codex login status` answers the same as unset), so
    # unlike CLAUDE_CONFIG_DIR it is always set, and the default needs no case.
    env["CODEX_HOME"] = d
    try:
        # stderr is CAPTURED, not discarded. When the app server exits before
        # answering, its last stderr line is the only thing that says why --
        # measured 2026-09-06 from inside Codex's own sandbox, where it exits
        # 1 at once and a status of "exited with status 1" named nothing.
        p = subprocess.Popen(["codex", "app-server"], cwd=QUERY_CWD, env=env,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
    except OSError as e:
        row["status"] = f"codex did not run ({e})"
        return row

    deadline = time.time() + TIMEOUT
    answers = {}

    def pump(want):
        """Read lines until every id in `want` has answered or time runs out."""
        buf = b""
        while time.time() < deadline and not want.issubset(answers):
            r, _, _ = select.select([p.stdout], [], [], 0.25)
            if not r:
                if p.poll() is not None:
                    return
                continue
            chunk = os.read(p.stdout.fileno(), 65536)
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if "id" in msg and ("result" in msg or "error" in msg):
                    answers[msg["id"]] = msg

    try:
        p.stdin.write(rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                           "params": {"clientInfo": {"name": "agswt", "title": "agswt",
                                                     "version": "0"},
                                      "capabilities": {}}}))
        p.stdin.flush()
        pump({1})
        if 1 not in answers:
            # Two different facts: the process died (a directory that cannot
            # be used, a binary that refuses to start) or it is alive and
            # silent. Reporting both as a timeout blamed the clock for a
            # process that had already exited in under a second.
            rc = p.poll()
            if rc is not None:
                why = stderr_tail(p)
                row["status"] = (f"app server exited with status {rc} before answering"
                                 + (f": {why}" if why else ""))
            else:
                row["status"] = f"app server did not initialize within {TIMEOUT}s"
            return row
        p.stdin.write(rpc({"jsonrpc": "2.0", "method": "initialized", "params": {}}))
        p.stdin.write(rpc({"jsonrpc": "2.0", "id": 2, "method": "account/read", "params": {}}))
        p.stdin.write(rpc({"jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read",
                           "params": {}}))
        p.stdin.flush()
        pump({2, 3})
        if 3 not in answers and p.poll() is not None:
            why = stderr_tail(p)
            row["status"] = (f"app server exited with status {p.poll()} before answering"
                             + (f": {why}" if why else ""))
            return row
    except (BrokenPipeError, OSError) as e:
        row["status"] = f"app server closed the pipe ({e})"
        return row
    finally:
        try:
            p.terminate()
            p.wait(timeout=5)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass

    acct = (answers.get(2, {}).get("result") or {}).get("account")
    if acct:
        row["email"] = acct.get("email")
        row["plan"] = acct.get("planType")
    lim = answers.get(3)
    if lim is None:
        row["status"] = f"no rate-limit answer within {TIMEOUT}s"
    elif "error" in lim:
        msg = lim["error"].get("message", "")
        if acct is None or "authentication" in msg:
            row["status"] = "not signed in"
        else:
            row["status"] = f"rate limits refused: {msg}"
    else:
        res = lim.get("result") or {}
        rl = res.get("rateLimits") or {}

        def windows(entry):
            """One limit entry -> {five, seven, five_r, seven_r}.

            primary is the short window (300 min), secondary the long one
            (10080 min). Matched by DURATION, not by position: a plan that
            reports only one window (Pro Lite: weekly, as primary), or
            reports them the other way round, must not land the week in
            the 5H column."""
            out = {"five": None, "seven": None, "five_r": None, "seven_r": None}
            for w in (entry.get("primary"), entry.get("secondary")):
                if not w:
                    continue
                mins = w.get("windowDurationMins") or 0
                key = "five" if mins <= 24 * 60 else "seven"
                out[key] = w.get("usedPercent")
                out[key + "_r"] = w.get("resetsAt")
            return out

        # Every limit id the server knows for this account, top-level one
        # first. Measured 2026-09-07 on a Pro Lite account: "codex" (weekly
        # only) and "codex_bengalfox" named GPT-5.3-Codex-Spark with its own
        # 5h and weekly windows. The TUI's /status shows them as separate
        # blocks, and so does report.
        by_id = res.get("rateLimitsByLimitId") or {}
        ordered = [rl.get("limitId")] + [k for k in by_id if k != rl.get("limitId")]
        for lid in ordered:
            entry = rl if lid == rl.get("limitId") else by_id.get(lid)
            if not entry:
                continue
            item = {"limit_id": lid, "name": entry.get("limitName"),
                    "reached": entry.get("rateLimitReachedType")}
            item.update(windows(entry))
            row["limits"].append(item)
        if row["limits"]:
            row.update({k: row["limits"][0][k] for k in ("five", "seven", "five_r", "seven_r")})
        if not row["plan"]:
            row["plan"] = rl.get("planType")

        # The monthly credit pool ("Monthly credit limit" in the TUI, the
        # same 2,337-of-3,000 figure -- measured 2026-09-07 on a Team
        # account). Absent on plans without one.
        il = rl.get("individualLimit")
        if isinstance(il, dict) and il.get("limit") is not None:
            try:
                row["credits"] = {"limit": float(il.get("limit")),
                                  "used": float(il.get("used") or 0),
                                  "remaining_percent": il.get("remainingPercent"),
                                  "resets_at": il.get("resetsAt")}
            except (TypeError, ValueError):
                row["credits"] = None

        if row["five"] is None and row["seven"] is None:
            row["status"] = "read, but no rate-limit window in the answer"
        elif row["limits"][0]["reached"]:
            row["status"] = f"limit reached: {row['limits'][0]['reached']}"
        else:
            row["status"] = "ok"
    return row


for d in dirs:
    print(json.dumps(ask(d), ensure_ascii=False))
    sys.stdout.flush()
