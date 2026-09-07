# Traps

Every entry here was hit on a real machine. They are ordered by how likely you
are to meet them, and each names the symptom first — because the symptom is
rarely a hint about the cause.

The two Keychain entries no longer apply to `agswt` itself: `report` asks the
`claude` binary rather than reading the credential. They are kept because the
binary reads the same Keychain, so the symptoms still reach you — just one layer
down.

Verified 2026-08-22 · macOS 15, Apple Silicon · Claude Code 2.1.239

---

## Every account reads "not logged in" at once

**Symptom.** Every profile reports missing credentials, including one you are
actively using in another window.

**Cause.** The macOS login keychain is locked. A locked keychain fails *every*
read with `errSecInteractionNotAllowed` (OSStatus −25308, surfacing as exit code
36 from `security`) and prints nothing at all — empty stdout, empty stderr. A
healthy account is indistinguishable from a signed-out one.

**Confirm.** Do not probe by reading some other item's secret. The earlier
advice here (`security find-generic-password -s "AirPort" -w`) reads a
*System*-keychain item, so on an unlocked machine it raises an
administrator-password dialog and hangs whatever ran it until somebody
answers (measured 2026-09-05) — silent in the broken state, a prompt in the
healthy one. There is no prompt-free query for lock state
(`security show-keychain-info` reports timeout settings, not whether it is
locked). The confirmation *is* the fix below: unlocking an already-unlocked
keychain is harmless.

**Fix.** From a terminal that can prompt for a password:

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

---

## Keychain reads fail even after unlocking

**Symptom.** The keychain is open, a human can read items, and your process still
gets exit 36.

**Cause.** The process is not in a GUI session, so no Security Agent exists to
satisfy the request. Anything under an agent harness, a launchd job, or a
background daemon lands here.

**Confirm.**

```bash
launchctl managername   # "Aqua" is fine, "Background" is not
```

**Fix.** None from inside that context. This measurement cannot be automated
from a background job on macOS; run it from a real terminal.

---

## The obvious refresh command does not refresh

**Symptom.** An idle profile is permanently stale and the tool demands a
re-login, even though its refresh token has weeks left.

**Cause.** `claude auth status` reads the stored credential without renewing it.
Measured against an access token 33 hours expired: `expiresAt` did not move by a
millisecond. It looks like the polite choice and does nothing.

**Fix.** Make a call that reaches the API. It costs a handful of tokens:

```bash
CLAUDE_CONFIG_DIR=<dir> claude -p "hi"
```

Do not swap this back for a read-only subcommand later.

---

## Idle profiles are always stale — by design

**Symptom.** Measurement profiles expire every few hours and need nudging on
nearly every run.

**Cause.** An access token lasts roughly eight hours and a refresh token roughly
a month, and renewal is a side effect of *using* the tool. A profile that exists
only to be measured is never used.

**Fix.** Expect it. Try the usage call, and on a 401 nudge once and retry, rather
than treating staleness as an error.

---

## Pointing the variable at the default directory breaks it

**Symptom.** A profile reports a null email and no plan, while the same account
works normally.

**Cause.** `CLAUDE_CONFIG_DIR=~/.claude` is **not** a no-op. The client then
looks for the *hashed* keychain item, and the hashed item only exists for
non-default directories:

```
default (~/.claude)  →  "Claude Code-credentials"
any other directory  →  "Claude Code-credentials-" + sha256(abspath)[:8]
```

**Fix.** Leave the variable unset for the default. Set it only for real profiles.

---

## Keychain metadata goes to stderr

**Symptom.** `security find-generic-password` returns nothing when captured in a
script, though it prints fine in a terminal.

**Cause.** Attribute output goes to stderr. Only `-w` — the secret itself —
goes to stdout.

**Fix.** Capture with `2>&1` for metadata; keep `-w` separate for the value.

---

## `timeout` does not exist on macOS

**Symptom.** `command not found: timeout`, and probe loops that appeared to run
did nothing at all.

**Cause.** GNU coreutils is not installed by default. It is easy to build a whole
diagnostic around a command that never executed.

**Fix.**

```bash
curl --max-time 20 …
perl -e 'alarm 25; exec @ARGV' <cmd>   # exit 142 means it was still running
```

---

## A nested `.envrc` erases its parent

**Symptom.** A subdirectory loses the account binding — and the GitHub identity,
and everything else the parent set.

**Cause.** direnv loads only the *nearest* `.envrc`. A child file replaces the
parent rather than extending it.

**Fix.** Begin every nested `.envrc` with `source_up`, then override only what
differs:

```bash
source_up
export GH_TOKEN="$(gh auth token --user other-account)"
```

---

## Never call the OAuth token endpoint yourself

**Symptom.** An account is signed out for no apparent reason after you added
"efficient" token handling.

**Cause.** Refresh tokens commonly rotate. A rotation performed behind the
client's back invalidates the copy the client still holds.

**Fix.** Always let the vendor's own binary own refresh. Shelling out costs a
subprocess and makes this failure impossible.

---

## `claude -p` stalls three seconds waiting on stdin

**Symptom.** Every scripted `/usage` read takes three seconds longer than it
should, and a warning appears on stderr: `no stdin data received in 3s,
proceeding without it`. Captured with `2>&1`, the warning lands in front of
your JSON and breaks the parse.

**Cause.** Run non-interactively without a redirected stdin, the binary waits
for piped input before giving up. Same family as the `codex exec` hang, with a
timeout instead of a hang.

**Fix.** Close stdin explicitly and keep stderr out of the data stream:

```bash
claude -p "/usage" --output-format json </dev/null 2>/dev/null
```

Measured 2026-08-22, Claude Code 2.1.240.

---

## A profile with MCP servers pollutes the JSON output

**Symptom.** `--output-format json` parses fine for some profiles and dies
with `Extra data` for others — the ones that work in daily use.

**Cause.** When the profile has MCP servers configured, the binary can print
log lines to *stdout* after the JSON object, e.g. `Client.listTools() called
but server does not advertise tools capability - returning empty list`. A
whole-stream `json.load` then fails, and the failure correlates with the
profiles that are most used.

**Fix.** Parse the first line (or the first JSON object) only; treat the rest
of stdout as noise. Reproduced 2026-08-22 on two profiles with MCP servers;
absent on two without.

---

## Moving a profile directory strands its credential

**Symptom.** A profile is renamed or reorganized (`mv watch/acme clients/acme`) and
immediately reads as signed out, though nothing was deleted.

**Cause.** The macOS Keychain service name encodes the sha256 of the config
directory's absolute path. Move the directory and the binary derives a new
hash, looks for an item that does not exist, and finds nothing. The old item
is still in the Keychain — under a name nothing will ever ask for again.

**Fix.** Move the directory, then sign in again in the new location — the
transcripts, memory, settings, and MCP config all travel with the directory;
only the credential stays behind. Treat a reorganize as `mv` plus one OAuth
sign-in, and prefer choosing the structure at creation (names may be nested:
`work/acme`, `clients/acme`) so the sign-in is not needed at all.

---

## Signing in ahead of time does not spare the first interactive launch

**Symptom.** `claude auth status` reports the profile logged in, `-p` calls
work — yet the first *interactive* launch in that profile shows the login
screen anyway.

**Cause.** Not established mechanically; observed twice on freshly created
profiles (2026-08-23, Claude Code 2.1.240) after ruling out everything else: direnv had
applied, the environment pointed at the right directory, the launcher passed
the environment through untouched, and the credential existed. The
non-interactive paths never see this screen, which is why scripted
verification cannot catch it.

**Fix.** Design around it, not through it: for a working profile skip the
CLI sign-in entirely — bind and migrate first (pure file operations), then
launch claude in the bound directory and sign in there, once. That first
interactive sign-in is the real one. Reserve `claude auth login` for
watch-only profiles that will never be launched. A second sign-in, when it
does happen, is harmless — it lands in the same profile and touches nothing
else (measured) — it is simply wasted motion.

---

## Rebinding a directory hides its existing conversations

**Symptom.** A directory is bound to a new profile; `claude -c` then reports
`No conversation found to continue`, though you were talking there minutes
ago.

**Cause.** Continuation looks inside the *current* profile's store, and the
old conversations live in the previous profile's store under the same slug.
Nothing was lost — it is looking in the right place for the wrong history.

**Fix.** Bring the history along:

```bash
migrate-workspace.sh --from <old-profile> --to <new-profile> --project <dir>
```

Then `claude -c` finds it — and the conversation genuinely continues on the
new account (measured: a session begun on one account resumed on another
after migration; transcripts are local files, and the API call carries them
as context under whichever account is signed in now). Your own files, your
own accounts. Note the *tooling* around the continued session — settings,
CLAUDE.md, MCP servers — is the new profile's, so behavior may differ even
though the conversation is the same.

---

## 15. A symlinked skills directory breaks skill installers

**Symptom.** After `npx skills add -g`, the skill is listed as installed but
never loads; the link the installer created points at a path that does not
exist (e.g. `../../../.agents/skills/...` resolving outside your home).

**Cause.** The profile's `skills/` was itself a symlink to a shared directory.
The installer computes a *relative* link target against the logical parent
path, but writing through a directory symlink lands the entry at the
*physical* location — a different depth, so the relative target walks past
the wrong root. The installer's code is correct for real directories, which
is what every normal setup has; the directory symlink is what breaks it.

**Fix.** Share per entry, not per directory: `skills/` (and `commands/`) are
real directories whose entries are absolute symlinks to the shared originals.
`create-profile` builds them that way. To repair an existing profile:

```bash
rm <profile>/skills            # the directory symlink only
mkdir <profile>/skills
for s in ~/.claude/skills/*; do ln -s "$s" <profile>/skills/"$(basename "$s")"; done
```

The trade-off is honest: a shared entry added *outside* an installer no longer
appears in every profile automatically — the installer (which installs
globally per real directory) is the distribution mechanism now.

---

## Codex: session rollouts keep answering from before a reset

**Symptom.** A usage reader built on the `rate_limits` snapshots in
`<CODEX_HOME>/sessions/…/rollout-*.jsonl` reports the 7-day window at 100%
while Codex itself shows 3%.

**Cause.** A rate-limit reset credit ("Full reset (Weekly + 5 hr)") was
consumed. Every snapshot written before it is now wrong, and the same session
file carries both the old and the new reset epoch. "Newest line in the newest
file" is right only if the last session to speak did so after the reset.

**Fix.** Ask the app server — `scripts/codex-ask.py` — which returns the
server's current answer for the account this directory holds. Measured
2026-09-05, codex-cli 0.153.4.

---

## Codex: `codex login status` does not say who

**Symptom.** Every profile reports `Logged in using ChatGPT` and nothing
distinguishes them.

**Cause.** The status subcommand reports the mode, not the account.

**Fix.** `account/read` on the app server returns the e-mail and plan;
`codex-ask.py` prints both. Never read them out of `auth.json`.

---

## Codex: a usage read through the app server writes into the home

**Symptom.** A "read-only" report leaves modified sqlite WALs and a fresh
`models_cache.json` in every Codex profile it polled, and an empty profile
directory gains sqlite files, `installation_id` and `skills/`.

**Cause.** The app server is the Codex runtime; it opens its stores on start.

**Fix.** None needed — it does not create sessions or rollouts (measured
across three reads), and the footprint is the same class as `claude -p`
leaving a `projects/<slug>` directory. Know that it happens, and do not
mistake the WAL timestamps for use.

---

## Codex: `codex exec` hangs forever

**Symptom.** No output, never returns, dies on your timeout.

**Cause.** Waiting on stdin — `Reading additional input from stdin...`, on
stderr where a piped call never shows it.

**Fix.**

```bash
codex exec --skip-git-repo-check "…" </dev/null
```

---

## Codex: nothing in this skill that writes can run inside the Codex sandbox

**Symptom.** Driven from a Codex session, `report` shows every Codex row as
`app server exited with status 1` and every Claude row as `no quota line`,
and `wire-direnv` ends with `direnv allow failed`. The same commands work
from a terminal.

**Cause.** Codex's sandbox (workspace-write) refuses writes outside the
workspace and `/tmp`. The app server needs its sqlite stores under
`CODEX_HOME`; the claude binary needs its own state; direnv records the
allow under `~/.local/share/direnv`. Measured 2026-09-06, codex-cli 0.153.4:

```
$ codex sandbox -- codex app-server
Error: failed to initialize sqlite state runtime under /Users/me/.codex: …
$ direnv allow .        # from inside the sandbox
… operation not permitted
```

**Fix.** Run `report`, `wire-direnv` and `create-profile` with the sandbox
lifted for that command (Codex asks for approval), or from a normal shell.
Every script now appends the failing binary's last stderr line to its
status, so the sandbox names itself instead of hiding behind an exit code.
