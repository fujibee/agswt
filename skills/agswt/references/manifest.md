# What a profile actually contains

Switching `CLAUDE_CONFIG_DIR` moves **everything** under that
directory, not just the parts you were thinking about. This is the complete list.
Migrate against it, not from memory — a partial migration looks successful and
fails days later.

## Layout

```
<config_dir>/
├── .claude.json          MCP servers (BOTH scopes), oauth account, per-project state
├── settings.json         hooks, permissions allowlist, enabled plugins, model, language
├── remote-settings.json  remote-control channel flag
├── CLAUDE.md             global instructions
├── commands/             slash commands
├── skills/               skills
└── projects/
    └── <slug>/
        ├── memory/           persistent memory + MEMORY.md index
        ├── *.jsonl           session transcripts (mode 0600)
        └── <session-id>/     sidecar
            └── tool-results/ cached tool output
```

`<slug>` is the project's absolute path with every `/` replaced by `-`, so
`/Users/me/projects/app` becomes `-Users-me-projects-app`. Moving or renaming the
project directory orphans its slug — the history is intact but invisible. That is
what `rename-workspace` fixes.

### The three that get missed

**MCP servers live in two scopes.** Inside `.claude.json`:

```jsonc
{
  "mcpServers": { … },                              // user scope
  "projects": {
    "/abs/path/to/project": { "mcpServers": { … } } // project scope
  }
}
```

Copying only the top-level key drops every per-project server, and nothing warns
you. Prefer `claude mcp add-json` over hand-editing: the file is rewritten by a
running client, so a direct edit can be clobbered.

**Sidecar directories.** `projects/<slug>/<session-id>/` is a directory, not a
`.jsonl`. Any migration written as `cp *.jsonl` misses all of them. They hold
cached tool output; losing them does not break `resume`, but old large outputs
can no longer be expanded.

**Transcripts are mode 0600.** Readable only by their owner. Crossing user
accounts needs a world-readable staging directory:

```bash
# as the source user
mkdir -p /tmp/stage && cp <config>/projects/<slug>/*.jsonl /tmp/stage/
chmod -R a+r /tmp/stage
```

Staging drops the original mtimes, and the session picker orders by mtime — so
restore each file's time from the last record it contains:

```python
last = None
with open(path, encoding="utf-8", errors="ignore") as fh:
    for line in fh:            # line-wise: a byte-slice tail can split a
        try:                   # multibyte char and lose the whole file
            rec = json.loads(line)
        except ValueError:
            continue
        if rec.get("timestamp"):
            last = rec["timestamp"]
ts = datetime.fromisoformat(last.replace("Z", "+00:00")).timestamp()
os.utime(path, (ts, ts))
os.chmod(path, 0o600)          # put the mode back too
```

## Copy first, delete later

Every migration is a **copy**, verified by count, and only then does a human
delete the source. Two reasons this is not excessive caution:

- A source you cannot re-read (another user's home, a machine you are about to
  wipe) makes a partial copy unrecoverable.
- Counts are the only honest check. Compare per category — transcripts, memory
  files, sidecar directories — not a single total, or a missing category hides
  inside a matching number.

## Never symlink these

| Path | Symlink? | Why |
|---|---|---|
| `settings.json` | **No** | Rewritten via temp-file-and-rename; the link is replaced by a real file |
| `.claude.json` | **No** | Same, and it is written constantly |
| `CLAUDE.md` | Yes | Read-only in practice; one source of truth is the point |
| `commands/` | Yes | Installers add files here; every profile should see them |
| `skills/` | Yes | Same |

A symlinked `settings.json` does not fail loudly. It works until the client next
writes, then the profile quietly has its own copy and stops tracking the
original.

## Shared originals — where the symlinks point

`CLAUDE.md`, `commands/`, and `skills/` are symlinked, not copied, so every
profile reads one source of truth. That source is **the default directory,
`~/.claude`**, unless `create-profile --shared <dir>` names another. The
choice is printed at creation time.

`settings.json` is the opposite: **always a copy, never a symlink** (the
client rewrites it with a temp-file-and-rename that would materialize the
link and corrupt the shared original). Its source is `--from <profile>`,
defaulting to `~/.claude`. The running session's `CLAUDE_CONFIG_DIR` is
never used implicitly — an environment-dependent default means two agents
running the same command produce different profiles.
