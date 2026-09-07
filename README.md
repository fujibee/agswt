# agswt

*[日本語](README.ja.md)*

Profile and manage the multiple accounts one person holds.

`agswt` turns the accounts an individual owns into **profiles** and gives you
the machinery around them: creating a profile, letting a directory decide which
account it talks to, moving existing work between profiles without losing
anything, and one usage report across every plan — including the accounts you
are not currently signed into.

For Anthropic's official position on holding multiple accounts, see
[Where this stands with Anthropic's terms](#where-this-stands-with-anthropics-terms)
below.

Works with **Claude Code** and **Codex**: profiles, per-directory binding and
the usage report cover both; moving existing history is Claude-only (Codex
keeps its thread history in a database — see
[`codex-notes.md`](skills/agswt/references/codex-notes.md)).

## Install

```bash
npx skills add fujibee/agswt
```

## Using it

agswt is a skill, not a CLI — you drive it through your agent in plain
language:

1. **"Create a profile called `work/acme`."** The agent prepares the
   directory — no sign-in yet; that comes naturally at the end.
2. **"Use it under `~/code/acme`."** The agent checks direnv (and gives you
   the two-line install if it is missing), writes the `.envrc` with the right
   chaining to any parent, proves the binding on both sides, and can move an
   existing project's history in — all pure file work, no credential involved.
3. **Launch `claude` in that directory.** It asks you to sign in, once — that
   browser OAuth flow is the real sign-in, and only you can complete it.
   (Signing in earlier by CLI does not skip this screen — measured — so the
   flow simply does not bother.) A Codex profile is signed in by CLI instead:
   `CODEX_HOME=<dir> codex login`.
4. **Done.** Everything under that directory now runs on that account —
   nothing to remember per session. Ask for a `report` any time. An account
   you only want to *watch* is the one exception: sign it in by CLI, since
   it is never launched.

Profile names nest: `work/acme`, `clients/x` — a `/` in the name simply
creates the group, and the report shows the structure. A name is shared by
the two tools: **"Create a Codex profile `work/acme` too"** gives the same
name a Codex half, and binding the directory then sets `CODEX_HOME` beside
`CLAUDE_CONFIG_DIR`.

## Why

Two purposes: different projects should run on different accounts, and you
want to know how much of every subscription is left. The model that serves
both: **an account is assigned to a profile**, and **a directory is bound to a
profile** — everything under that directory is then held to that account.
The assignment is just the sign-in: to switch a profile to a different
account, sign in again from any session running on it, and every bound
directory follows. A
profile can also exist only to be watched, holding an account whose remaining
quota you read but never spend.

Underneath, each tool keeps exactly one logged-in account per config directory, selected
by `CLAUDE_CONFIG_DIR` (default `~/.claude`) for Claude Code and `CODEX_HOME`
(default `~/.codex`) for Codex. That is the whole isolation
mechanism. No containers, no VMs, and no signing out
to switch. What makes it awkward in practice is everything around it: which files
constitute an account, why a copied project loses half its history, and why a
perfectly healthy account reports itself as signed out.

Profiles live under **`~/.claude_profiles`** (Claude) and
**`~/.codex_profiles`** (Codex) by default; set `AGSWT_PROFILES_ROOT` and
`AGSWT_CODEX_PROFILES_ROOT` to keep them somewhere else — every script reads
the same variables, so a location changes in one place or not at all.

`agswt` is that knowledge, written down and executable.

## What it does

| Operation | What it does | Tools |
|---|---|---|
| `create-profile` | New profile, then stops and prints the sign-in command | Claude, Codex |
| `verify` | Confirm a profile is actually signed in, and as whom | Claude, Codex |
| `migrate-workspace` | Move one project's data between profiles | Claude |
| `wire-direnv` | Bind a directory to a profile via `.envrc` | both at once |
| `rename-workspace` | Make a stored slug follow a moved directory | Claude |
| `doctor` | Check the known failure modes | Claude, Codex |
| `report` | Usage across every profile | Claude, Codex |

## A sample of what it knows

- Signing in is an OAuth flow and needs a human. The skill prepares everything,
  prints the command, and **stops** — it never pretends a profile is ready.
- Usage is read by asking the `claude` binary (`claude -p "/usage"`), never by
  lifting the OAuth token out of the Keychain. Anthropic scopes that credential
  to Claude Code itself, so a script holding it is a third-party tool using a
  subscription credential — and the binary answers for free, at zero cost and
  with no model turn.
- A locked macOS login keychain fails every credential read with
  `errSecInteractionNotAllowed`, prints nothing, and makes every account look
  signed out — including ones that are working fine in another window.
- `claude auth status` reads a token without renewing it. Renewal only happens
  on a call that actually reaches the API.
- MCP servers live in two scopes. Copying only the user scope silently drops
  every per-project server.
- Session sidecar directories sit beside the transcripts and are not `*.jsonl`,
  so every glob misses them.
- `settings.json` must never be symlinked: it is rewritten with a
  temp-file-and-rename that replaces the link with a real file.
- Codex usage is read the same way — by asking the unmodified `codex` binary
  (its app server, over stdio) — never by opening `auth.json`, and never by
  scraping the rate-limit snapshots in the session logs: one rate-limit
  reset makes every snapshot written before it wrong.
- `codex login status` says logged-in-or-not, never as whom; the account
  behind a Codex profile comes from the app server too.

The full list, with symptoms and fixes, is in
[`skills/agswt/references/traps.md`](skills/agswt/references/traps.md).

## Where this stands with Anthropic's terms

Multi-account tooling around a subscription credential deserves an explicit
answer, so here it is. agswt is designed to stay inside the lines Anthropic's
own documents draw. We are not Anthropic and this is not a compliance ruling —
the quotes below are from the documents as of 2026-08-22, each linked so you
can read them yourself.

**Only Claude Code ever holds the credential.** The
[Claude Code documentation](https://code.claude.com/docs/en/legal-and-compliance)
states that developers "may not collect, store, or intermediate Claude.ai
credentials or session tokens." agswt does none of these: it never reads,
stores, copies, or transmits a token. Every usage read is
`claude -p "/usage"` executed by the unmodified Claude Code binary — the
binary is the only process that touches the OAuth credential, and
[`/usage` is a built-in command](https://code.claude.com/docs/en/commands)
that answers at zero cost with no model call.

**Sign-in completes through Anthropic's own flow.** The same page requires
that "sign-in to a Claude account must complete through Anthropic's own flow,"
and confirms that nothing prevents "an end user from signing in to the
unmodified Claude Code binary with their own Claude subscription." agswt
prepares a profile directory and then stops; you sign in through `claude`
itself. It does not implement or wrap a login flow.

**Your own accounts, your own usage.** The
[Consumer Terms](https://www.anthropic.com/legal/consumer-terms) prohibit
sharing an account or making it available to anyone else. agswt reads the
signed-in user's own included usage on their own accounts. Nothing is
re-served, resold, or intermediated, and no account is shared.

**A documented mechanism — and a documented use.** One logged-in account per
config directory, selected by `CLAUDE_CONFIG_DIR`, is Claude Code's own model,
and the [environment-variable reference](https://code.claude.com/docs/en/env-vars)
names this exact use for it: "Useful for running multiple accounts side by
side: for example, `alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work
claude'`". agswt adds bookkeeping around it, nothing more.

Two things agswt deliberately is **not**:

- **A way to get more usage.** The documentation notes that advertised limits
  "assume ordinary, individual usage." agswt gives you *visibility* — which
  account has how much left, so a limit never surprises you — and clean
  per-directory separation. It does not change what any plan gives you.
- **A statement that multiple accounts are endorsed.** The Consumer Terms
  contain no clause limiting how many accounts one person may hold — but
  silence is not permission, and the
  [Usage Policy](https://www.anthropic.com/legal/aup) prohibits using another
  account to get around a ban. A member of the Claude Code team has
  [said publicly](https://x.com/trq212/status/2024230184287949207) that "it's
  not against terms of service to have multiple MAX accounts," and that what
  crosses the line is using them "to do things like resell tokens." That is a
  useful signal about where enforcement aims — but a staff post is not the
  Terms, and this section rests on the documents above, not on it. agswt is
  for one person operating their own accounts, nothing else.

Terms change, and Anthropic reserves the right to enforce its restrictions
without notice. This section describes the documents as of the date above;
if you rely on it, read the linked sources.

**And with OpenAI's.** The Codex side is built on the same principle: the
unmodified `codex` binary reads its own credential, and agswt reads the
signed-in user's own account through it. The Codex lead has
[said publicly](https://x.com/thsottiaux/status/2090675027670978569)
(2026-08-21) that what is not allowed is "converting a subscription into api
traffic — often shared with several users"; agswt re-serves nothing. OpenAI's
consumer terms also prohibit circumventing rate limits, and agswt does not
change what any plan gives you. Details in
[`codex-notes.md`](skills/agswt/references/codex-notes.md).

## Alternatives

Profile switching over `CLAUDE_CONFIG_DIR` is a small genre — at least ten
tools, among them
[claude-code-profiles](https://github.com/quinnjr/claude-code-profiles) (the
most starred),
[claude-profile-manager](https://github.com/JakubKontra/claude-profile-manager)
(closest in spirit: per-project binding with direnv), and
[cprof](https://github.com/dcotelo/cprof) (the same idea, in the same words).
If switching is all you need, any of them works.

What sets agswt apart, as far as we have surveyed:

- **The usage report never touches a credential.** The existing tools that show
  remaining quota read or swap the OAuth credential themselves; agswt only ever
  asks the unmodified `claude` binary. The terms section above is why that
  difference matters.
- **It covers Codex in the same report.** Same profile names, same `.envrc`,
  one table across both subscriptions.
- **It moves history.** `migrate-workspace` carries an existing project's
  transcripts, memory, both MCP scopes, and sidecar directories between
  profiles with per-category count verification. Switchers decide where *new*
  work goes; nothing else we found moves what already exists.
- **It is a skill, not a CLI.** Instructions and scripts an agent executes
  (`npx skills add`), with the traps written down next to the code.

## Requirements

- macOS or Linux
- Claude Code and/or Codex (codex-cli 0.153 or later for the usage report:
  it needs the app server's `account/rateLimits/read`)
- Optional: `direnv` for automatic per-directory switching, `gh` to pin a GitHub
  identity alongside each account

## License

MIT
