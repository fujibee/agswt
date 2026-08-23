# Codex — research notes (not yet supported)

`agswt` does not manage Codex profiles yet. These findings are kept so that
adding support does not start from zero. All were verified on codex-cli
0.149.0, macOS 15, 2026-08-22.

## Profiles work the same way

`CODEX_HOME` isolates accounts exactly as `CLAUDE_CONFIG_DIR` does. Confirmed
by aiming it at an empty directory while the default stayed signed in:

```console
$ codex login status
Logged in using ChatGPT

$ CODEX_HOME=/tmp/probe codex login status
Not logged in
```

## Credentials are plaintext

`<CODEX_HOME>/auth.json` holds `auth_mode`, an id/access/refresh token trio
and `account_id` in the clear — no keychain involved, so none of the keychain
traps apply. Treat the file as a secret: never stage it through a shared
directory or copy it into a repo.

## `codex exec` hangs forever

**Symptom.** No output, never returns, dies on your timeout.

**Cause.** It is waiting on stdin — `Reading additional input from stdin...`,
written to stderr where a piped invocation never shows it.

**Fix.**

```bash
codex exec --skip-git-repo-check "…" </dev/null
```

---

## Codex has no usage endpoint

**Symptom.** You go looking for the API behind Codex's usage display and every
plausible path returns 403.

**Cause.** There isn't a public one. Four paths under
`chatgpt.com/backend-api/codex/` were probed; all 403.

**Fix.** Read what Codex already wrote. Every session log carries the server's
own answer:

```jsonc
// <CODEX_HOME>/sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl
"rate_limits": {
  "limit_id": "codex",
  "primary":   { "used_percent": 53.0, "window_minutes": 10080, "resets_at": 1787904600 },
  "secondary": null,
  "credits":   { "has_credits": true, "unlimited": false, "balance": null }
}
```

`window_minutes: 10080` is seven days, `resets_at` is epoch seconds, and
`secondary` is often null. Take the newest snapshot across all session files.
Guessing at an undocumented private API produces something that breaks silently
on the next release; this source is written by Codex itself and needs no
credentials.

---


## Codex

```
<CODEX_HOME>/
├── auth.json         credentials in plaintext (auth_mode, tokens, account_id)
├── config.toml       model, sandbox, approval settings
├── sessions/
│   └── <yyyy>/<mm>/<dd>/rollout-*.jsonl    transcripts AND usage snapshots
├── history.jsonl
├── skills/  prompts/  plugins/
└── *.sqlite          thread history, logs, queue
```

Codex keeps its credentials in a plain file rather than the system keychain,
which makes profiles simpler to inspect and simpler to leak. Treat `auth.json`
as a secret: never copy it into a repo, a scratch directory you will publish, or
a shared `/tmp` staging path.

Usage figures are embedded in the session logs — see `traps.md`.

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
traffic is not. A Codex implementation here would read the session rollout logs
Codex itself writes and would never touch `auth.json` — which sits entirely on
the permitted side of that line, and is the design this document already
records. Note OpenAI's consumer terms also prohibit "circumventing any rate
limits or restrictions", so the same framing rule as the Claude side applies:
this is visibility over your own accounts, never a way around a limit.
