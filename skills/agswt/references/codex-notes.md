# Codex

How `agswt` handles Codex, and what it deliberately leaves alone. Everything
below was measured on codex-cli 0.153.4, macOS, 2026-09-05 unless another
date is given; the 2026-08-22 findings were on 0.149.0.

## Profiles work the same way

`CODEX_HOME` isolates accounts exactly as `CLAUDE_CONFIG_DIR` does. Confirmed
by aiming it at an empty directory while the default stayed signed in:

```console
$ codex login status
Logged in using ChatGPT

$ CODEX_HOME=/tmp/probe codex login status
Not logged in
```

Codex profiles live under **`~/.codex_profiles`** (override with
`AGSWT_CODEX_PROFILES_ROOT`), a separate root from the Claude one, **mirrored
by name**: `~/.codex_profiles/work/acme` is the Codex half of the profile
`work/acme`, `~/.claude_profiles/work/acme` the Claude half. Two roots rather
than a `codex/` subdirectory inside one profile, because the Claude discovery
rule ("a directory holding `.claude.json` is a profile; one without is a
group") would read that subdirectory as a group and walk into it.

A directory is a Codex profile when it holds **`auth.json`** (the account,
written by `codex login`) **or `config.toml`** (what `create-profile` seeds
before any sign-in). Either marks an intended profile, so an unsigned one is
listed with its sign-in command instead of vanishing.

One difference from Claude worth knowing: setting `CODEX_HOME` explicitly to
its own default is harmless. `CODEX_HOME=~/.codex codex login status` answers
exactly as the unset form does, so `doctor` does not warn about it the way it
warns about `CLAUDE_CONFIG_DIR=~/.claude`.

## What a Codex home contains

```
<CODEX_HOME>/
├── auth.json                 credentials in PLAINTEXT (auth_mode, tokens, account_id), mode 0600
├── config.toml               model, sandbox, approval, MCP servers, project trust, hook state
├── hooks.json                hook definitions
├── rules/                    exec-policy rules
├── AGENTS.md                 global instructions (Codex's CLAUDE.md), if you keep one
├── prompts/                  custom prompts (slash commands)
├── skills/                   skills; skills/.system is Codex's own
├── plugins/                  plugin cache and app-server plugin state
├── sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl    transcripts, with rate-limit snapshots inside
├── history.jsonl             prompt history
├── state_5.sqlite, thread_history_1.sqlite, logs_2.sqlite, memories_1.sqlite, …
│                             thread history, logs, queue, memories (names carry a schema version)
├── models_cache.json, installation_id
└── .codex-global-state.json  the desktop app's own state
```

`create-profile --tool codex` seeds a new profile from the default home by
the same two rules as the Claude side:

- **Copied, never symlinked**: `config.toml`, `hooks.json`, `rules/`. Codex
  edits `config.toml` in place (project trust entries, model-migration
  notices, hook state), and a symlink would push those edits into the
  original. A source with no `config.toml` gets an empty one, announced, so
  the profile is discoverable.
- **Linked, one source of truth**: `AGENTS.md` as a file; `prompts/` and
  `skills/` as real directories of absolute per-entry links (never a
  directory symlink — traps #15). Dot-entries such as `skills/.system` are
  skipped: they are Codex's, regenerated per home.
- **Never touched**: `auth.json`. A profile gets its account by signing in.
  Treat the file as a secret — plaintext tokens, never staged through a
  shared directory, never copied into a repo. `doctor` warns when its mode
  is not `0600`, which is what a `cp` under the default umask produces.

## Signing in

```bash
CODEX_HOME=<dir> codex login                 # browser OAuth
CODEX_HOME=<dir> codex login --device-auth   # no browser on this machine
```

This is the vendor's own flow, run by the unmodified binary, writing
`auth.json` into that directory. Unlike the Claude side, the CLI login is the
route the skill hands you: whether Codex's first interactive launch would
also offer a sign-in has not been measured, so nothing relies on it.

`codex login status` says whether a home is signed in — but not as whom:

```console
$ codex login status
Logged in using ChatGPT
```

No e-mail, no plan. The identity comes from the app server (next section),
which is how `report` labels the row.

## Reading usage: ask the app server

Codex has no `/usage` command the way `claude -p "/usage"` is one. What it
has is an app server — `codex app-server` speaks JSON-RPC over stdio — with
two read-only methods that answer the question directly:

| Method | Answers |
|---|---|
| `account/read` | `{account: {type, email, planType}}`, or `account: null` when signed out |
| `account/rateLimits/read` | `{rateLimits: {primary, secondary, …}}` — the same object the TUI's status view shows |

Method names come from `codex app-server generate-json-schema` (0.153.4).
The exchange, as `scripts/codex-ask.py` performs it:

```
→ {"id":1,"method":"initialize","params":{"clientInfo":{"name":"agswt","title":"agswt","version":"0"},"capabilities":{}}}
← {"id":1,"result":{"userAgent":…,"codexHome":"/Users/me/.codex",…}}
→ {"method":"initialized","params":{}}
→ {"id":2,"method":"account/read","params":{}}
→ {"id":3,"method":"account/rateLimits/read","params":{}}
← {"id":2,"result":{"account":{"type":"chatgpt","email":"me@example.com","planType":"team"},"requiresOpenaiAuth":true}}
← {"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":22,"windowDurationMins":300,"resetsAt":1788670242},"secondary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1789257042},"planType":"team",…}}}
```

`primary` is the 5-hour window (300 minutes), `secondary` the 7-day one
(10080); `resetsAt` is epoch seconds. `codex-ask.py` matches the two by
duration, not by position. A signed-out home answers `account: null` and
refuses the rate-limit read with JSON-RPC error `-32600 … authentication
required`. Two profiles answer in under a second together.

**Run `codex-ask.py` — do not re-implement the exchange.** It is the one
place in this skill that speaks to Codex, so `report` and anything else that
wants an identity or a number read the same thing.

**The read is not write-free.** The app server touches its sqlite WALs and
`models_cache.json` under `CODEX_HOME`, and in an empty directory it creates
the sqlite files, `installation_id` and `skills/`. It does **not** create a
session or a rollout — `sessions/` was unchanged across three reads. The
same shape as the Claude side, where `claude -p` leaves a `projects/<slug>`
directory; accepted, and written down here.

This sits on the same footing as `claude -p "/usage"`: the vendor's own
binary reads its own credential; the skill never opens `auth.json`.

**Inside Codex's own sandbox the app server cannot start** — `failed to
initialize sqlite state runtime under <CODEX_HOME>`, because the sandbox
refuses writes outside the workspace (measured 2026-09-06 with
`codex sandbox -- codex app-server`). A Codex session driving `report` has
to run it with the sandbox lifted; the status line carries that stderr so
the failure is not mistaken for a signed-out profile. See traps.md.

### Several limits per account: windows per limit id, credits, and one you cannot read

`account/rateLimits/read` returns `rateLimitsByLimitId`, one entry per limit
the account has, and the windows differ by plan:

| Plan (measured) | limit id | windows |
|---|---|---|
| Team | `codex` | 5h + weekly |
| Pro Lite | `codex` | weekly only |
| Pro Lite | `codex_bengalfox` (limitName `GPT-5.3-Codex-Spark`) | 5h + weekly, its own |

`report` prints one row per limit id — the first as the account row, the
others named after the limit — and treats a plan with a single window as
read correctly, not as a missing 5h (measured 2026-09-07). The same answer
carries `individualLimit`, which is the pool the TUI shows as "Monthly
credit limit" (the same 2,337-of-3,000 figure, measured on a Team account);
`report` prints it under the table as monthly credits. Plans without a pool
return no such block.

That leaves the limit the standard models do not draw on.

The premium model (`gpt-5.6-sol`) draws on a different limit, `premium`,
and it is not a window: measured 2026-09-05 in two sol sessions, the
server's snapshot read `limit_id: premium`, `primary: null`,
`secondary: null`, `credits.has_credits: false`,
`rate_limit_reached_type: workspace_member_credits_depleted` — a credit pool
per workspace member, and it was empty, which is when the TUI offers to
switch to luna. The app server did not include `premium` in
`rateLimitsByLimitId` when asked afterwards, and the read takes no
parameters (`params: null` in the schema), so **the premium balance cannot
be read from outside a session**. What can be seen is only that it ran out,
and only inside a session that used sol. A `report` row saying `codex 68%`
therefore says nothing about whether sol is usable; `/status` inside a sol
session is the one place that does.

## Why not the session logs

The earlier plan (2026-08-22) was to read the `rate_limits` snapshots Codex
writes into every session rollout — no process to start, no credential
involved, and the numbers are the server's own. That source is real and still
there, but it goes wrong the moment a window is reset out of band.

Measured 2026-09-05: one rate-limit reset credit ("Full reset (Weekly + 5
hr)") was consumed at 16:50. The rollouts on disk kept answering "7d 100%"
from before it; the same session file carries both the old and the new reset
epoch, and the newest line in the newest file was right only by luck of which
session happened to speak last. The app server says what the server says now.

The old finding is kept because the snapshot format is still useful for
reading history (each `event_msg` of type `token_count` carries
`rate_limits` with `primary`/`secondary` windows and `plan_type`), and
because the reasoning against guessing at a private endpoint still stands:
four paths under `chatgpt.com/backend-api/codex/` were probed on 2026-08-22
and all returned 403, and nothing here calls them.

## `codex exec` hangs forever

**Symptom.** No output, never returns, dies on your timeout.

**Cause.** It is waiting on stdin — `Reading additional input from stdin...`,
written to stderr where a piped invocation never shows it.

**Fix.**

```bash
codex exec --skip-git-repo-check "…" </dev/null
```

## Not supported: moving Codex history

`migrate-workspace` and `rename-workspace` are Claude-only. Codex keeps
thread history in sqlite (`state_5.sqlite`, `thread_history_1.sqlite`) beside
the rollout files, and `codex migrate-rollouts` exists to move "legacy local
sessions to paginated thread history" — the database is becoming the source
of truth. Copying `sessions/` between homes is therefore not a migration but
a database merge, and this skill does not attempt one. Whether copied
rollouts would be visible to `codex resume` has not been measured.

`wire-direnv` says so when it binds a Codex half, so the omission is stated
rather than discovered.

## Where OpenAI stands on tools like this

Primary source, verified 2026-08-22. The Codex lead, Tibo Sottiaux
([@thsottiaux, 2026-08-21](https://x.com/thsottiaux/status/2090675027670978569)),
responding to reports of usage-limit changes: "We've investigated a few messages
about codex usage limits being different. That's not something we change without
engaging the community and being transparent. What we did see is that when
talking to affected users many were using sub2api. Converting a subscription
into api traffic — often shared with several users — is not allowed under our
terms of service."

The line is the same shape as Anthropic's: your own account, your own included
usage, through a real client is fine; re-serving a subscription as shared API
traffic is not. agswt asks the unmodified Codex binary about the signed-in
user's own account and never reads `auth.json` — entirely on the permitted
side of that line. OpenAI's consumer terms also prohibit "circumventing any
rate limits or restrictions", so the same framing rule as the Claude side
applies: this is visibility over your own accounts, never a way around a
limit.
