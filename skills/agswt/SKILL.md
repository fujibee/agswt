---
name: agswt
description: Create and switch between per-account profiles for Claude Code, migrate existing workspaces between them, wire direnv so a directory selects its own account, and report subscription usage across every account. Use when someone runs more than one Claude subscription on one machine, asks to separate accounts per project, needs to move a project's history to a different account, or wants to see how much of each plan is used.
---

# agswt

One machine, several subscriptions. `agswt` makes a directory decide which
account it talks to, moves existing work between accounts without losing
anything, and reports how much of each plan is left.

## What this is for

Two purposes: **different projects should run on different accounts**, and
**you want to know how much of every subscription is left**.

The model that serves both: **an account is assigned to a profile.** Create a
profile and sign an account into it — a profile may also exist only to be
watched, holding an account whose remaining quota you read but never spend.
To actually use a profile, bind a directory to it: everything under that
directory is then held to that profile, which is the point — the binding is
what keeps a project from quietly running on the wrong account.

## The mechanism underneath

Claude Code keeps **exactly one logged-in account per config directory**,
selected by `CLAUDE_CONFIG_DIR` (default `~/.claude`). That is the entire
isolation mechanism — no containers, no VMs, no signing out to switch.

A **profile** is one such directory plus the account signed into it. Profiles
live under **`~/.claude_profiles`** by default; set `AGSWT_PROFILES_ROOT` to
put them elsewhere. One
directory per account is all you need — `report` reads the profiles you already
work in.

Profile names may be nested (`work/oma`, `clients/acme`): a directory holding a
`.claude.json` is a profile, a directory without one is a group, and discovery
recurses. `create-profile` accepts nested names and creates missing parent
directories itself — a parent needs no preparation and may even be a profile
of its own. Prefer choosing the structure at creation: a profile directory can be moved
later — everything travels with it except the credential (the Keychain item is
keyed to the absolute path), so a move costs one fresh sign-in in the new
location. See `references/traps.md`.

> Earlier versions of this skill told you to keep a second, measurement-only
> profile per account, because reading the stored credential from outside gave
> stale numbers while a session was running. Asking the binary removed that
> problem: measured 2026-08-22, a work profile in active use, a separate
> measurement profile, and the default directory all returned identical figures.
> Do not build duplicate profiles.

## The typical path

Creating a profile changes nothing by itself — a profile only matters once
something runs against it. The path is:

    create-profile
        → wire-direnv <profile> --dir <dir>   for a directory that should use it
        → migrate-workspace --to <profile>    for an existing project moving in
        → launch claude in that directory — it asks you to sign in, once
        → report                              to see it among the others

If an agent session was already running while it wired the directory, that
session stays on the old account — the binding only applies to new launches.
Say so explicitly and give the two commands: `exit`, then `claude` in the
bound directory. Do not leave the restart implied.

Check for existing history **right after the wiring** — the binding is what
makes the question real, since nothing can reach the new profile before it
exists: look for the bound directory's conversations under other profiles —
**including the very conversation making the request** — because they will
look empty to `claude -c` now that the directory is rebound. "This is a new directory" stops
being true the moment someone talks in it. When history exists, do not just
mention the migration — **ask the one question and act on the answer**:
"carry this directory's existing conversations over to <new profile>?" On
yes, run `migrate-workspace` in the same flow, before handing over the
restart (copy-only, so nothing is risked). The one reason to answer no is a deliberate clean start on the
new account, which is why the question exists instead of automation.
`wire-direnv --migrate` does the same in one step for script users; without
the flag it detects and prints what it found, as a backstop for flows that
skipped the question.

Sign-in happens at the END, at the first interactive launch, not up front.
Measured twice: a profile signed in via `claude auth login` beforehand is
asked to sign in again anyway on its first interactive launch — the early
CLI sign-in buys nothing for a working profile. Binding and migration are
pure file operations and need no credential. The one exception is a
watch-only profile (an account you read quota from but never launch): sign
that one in with `CLAUDE_CONFIG_DIR=<dir> claude auth login --claudeai`,
because no interactive launch will ever come.

Without direnv, `wire-direnv` degrades to printing the `export
CLAUDE_CONFIG_DIR=…` line to set by hand — the binding still works, it is just
not automatic per directory.

## Operations

Some operations ship as scripts in `scripts/`; the rest are step lists in
`assets/WORKFLOW.yaml` that an agent follows directly. The dividing line is not
size but failure mode: **an operation whose mistakes fail loudly can be
improvised and retried; an operation whose mistakes succeed silently and break
later ships as a script.** Copying a file that should have been symlinked
produces a working-looking profile that corrupts its shared original days
later — that class gets code, not prose.

Argument shape is uniform: when an operation takes one profile, it is the
first positional argument; when it takes two (migrate's `--from`/`--to`),
both are named flags — two positionals that read naturally in either order
make the caller guess, and a guess that runs is worse than one that fails.
Everything else (directories, slugs, paths) is always a flag.

| Operation | What it does |
|---|---|
| `create-profile` | New work profile, then **stops** and prints the sign-in command |
| `verify` | Confirm a profile is actually signed in |
| `migrate-workspace` | Move one project's data between profiles |
| `wire-direnv` | Bind a directory to a profile via `.envrc` |
| `rename-workspace` | Make a stored slug follow a moved directory |
| `doctor` | Check for the failure modes in `references/traps.md` |
| `report` | Usage across all profiles |

## Never attempt the login yourself

Signing in is an OAuth flow: it opens a browser and needs a human. **Prepare
everything, print the exact command, and stop.** Do not run `claude auth login`,
and do not report a profile as ready before its login has been confirmed.

The handoff looks like this:

```
Profile 'priv' is ready (not signed in yet — that happens at first launch).
Next, pick one:
  bind a directory to it:    wire-direnv priv --dir <dir>
  move an existing project:  migrate-workspace --to priv ...
Then launch claude in the bound directory and complete the sign-in screen.

Watch-only profile (never launched interactively)? Sign it in now instead:
    CLAUDE_CONFIG_DIR=~/.claude_profiles/priv claude auth login --claudeai
```

`verify` calls `claude auth status` — run it after the first launch (or after
the CLI sign-in of a watch-only profile) to confirm which account landed.

## Migrating a workspace

Read `references/manifest.md` before touching anything. Switching a config
directory moves **everything** under it, not just the obvious parts, and the
parts people forget are:

- **MCP servers live in two scopes.** `mcpServers` (user) and
  `projects[<path>].mcpServers` (project). Copying only the first silently drops
  every per-project server.
- **Session sidecar directories.** `projects/<slug>/<session-id>/tool-results/`
  sits beside the transcripts and is not a `*.jsonl`, so every glob misses it.
- **Transcripts are mode 0600.** Another OS user cannot read them; stage through
  a world-readable directory when crossing accounts, then restore both the mode
  and the mtime.

Two rules that are not negotiable:

1. **Copy, verify counts per category, then let the human delete.** A single
   total hides a whole missing category.
2. **Never symlink `settings.json`.** Claude Code rewrites it with a
   temp-file-and-rename, which replaces a symlink with a real file and silently
   breaks the link. `CLAUDE.md`, `commands/` and `skills/` *are* safe to symlink
   and should be, so there is one source of truth.

## Reporting usage

`report` prints one row per profile: plan, short and long window percentages,
and when each resets.

Run `scripts/report.sh` — do not hand-build the loop from the steps below;
an agent improvising it loses minutes to timeouts and parse edge cases the
script already handles (closed stdin, log lines after the JSON, per-profile
timeout with one retry).

**Ask the binary. Never read the credential yourself.**

```bash
CLAUDE_CONFIG_DIR=<dir> claude -p "/usage" --output-format json </dev/null 2>/dev/null
```

Parse only the first line of stdout: a profile with MCP servers configured can
print log lines after the JSON object.

The numbers come back in the `result` field on fixed-format lines. Measured
2026-08-22 on Claude Code 2.1.240: `total_cost_usd` is 0 and `duration_api_ms`
is 0, so this runs no model turn and bills nothing. Switching
`CLAUDE_CONFIG_DIR` returns that directory's account, confirmed against three
directories holding three different accounts.

This is not merely convenient, it is the only appropriate design. Anthropic's
terms scope OAuth credentials to Claude Code and other native Anthropic
applications; a script that lifts the token out of the Keychain and calls the
API itself is a third-party tool using a subscription credential. Routing every
read through the unmodified binary keeps the token where it belongs — and as a
side effect deletes the Keychain handling, the hashed service-name derivation,
and their whole class of failures from this skill.

An idle profile may still hold an expired access token. Renewal happens as a
side effect of using the tool, so on failure nudge once with
`claude -p "hi"` and retry. Whether `/usage` alone renews an expired token has
not been measured.

Never call the OAuth token endpoint directly. Refresh tokens rotate, and a
rotation performed behind the client's back signs that account out.

## Optional pieces

`agswt` works without any of these; wire them in if they are present.

- **direnv** — makes the binding automatic per directory. See `wire-direnv`.
  Installing it is two steps, and the second is the one people miss:

  ```bash
  brew install direnv        # macOS   (apt install direnv on Debian/Ubuntu)
  eval "$(direnv hook zsh)"  # add to ~/.zshrc — bash/fish variants: direnv.net
  ```

  Without the shell hook, direnv is installed but no `.envrc` is ever read —
  nothing fails, nothing binds. Every newly wired directory also starts
  **blocked** until `direnv allow` runs in it once; that is per-directory and
  by design. Nested `.envrc` files **must** start with `source_up`, or the
  parent's variables vanish entirely.

  Without direnv at all, the binding is manual: run
  `export CLAUDE_CONFIG_DIR=<profile-dir>` in each shell (or once per
  multiplexer session) — it works identically, it is just not automatic.
- **A terminal multiplexer** — one session per profile keeps windows separate.
- **`gh`** — pin a GitHub identity per directory alongside the account.

## Not yet supported

Codex uses the same one-account-per-directory model via `CODEX_HOME`, and the
research for adding it is in `references/codex-notes.md`. It is not implemented.
