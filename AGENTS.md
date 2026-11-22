# Agent contract — skillz

This repository is the canonical owner of your machine's skills. Agents may read
it freely and may write through the CLI. The rules below keep the tiers honest.

The `ops/` directory is optional lab integration. The core CLI and MCP server do
not import it; do not make the core depend on it.

## Before editing

1. Read [`CONVENTIONS.md`](CONVENTIONS.md).
2. Run `bin/skillz verify` and `bin/skillz status` to see the current state.
3. If the task is about an existing skill, read its `SKILL.md` and `skill.json`
   before changing either.

## Where things go

| You are doing this | Write here | Never write here |
| --- | --- | --- |
| Adding or editing a usable skill | `skills/<name>/` | `cache/`, `state/` |
| Retiring a skill | `archive/<name>/<date>/` via `bin/skillz archive` | by hand |
| Recording an external file | `external.lock.json` via `bin/skillz external add` | a prose-only URL |
| Fetching a URL for a skill | `cache/external/` | `skills/` |
| Runtime config, pids, logs | `state/` | tracked files |

**`cache/` is disposable.** If losing a file would lose knowledge, it does not
belong in `cache/`. **`state/` is runtime.** If a value is needed after a reboot,
it belongs in a tracked config template, not in `state/`.

## After editing an active skill

```sh
bin/skillz verify
bin/skillz seal <name>      # only after an intentional content change
bin/skillz catalog
```

`verify` must pass. `seal` updates the tree hash and file map in `skill.json`;
running it without a content change is a no-op.

## Mutating operations

The MCP surface is read-only on purpose. Use the CLI for writes:

```sh
bin/skillz adopt <path> [--move --link]
bin/skillz archive <name> --reason "..."
bin/skillz restore <name>
bin/skillz external add|fetch|verify
bin/skillz link|unlink
bin/skillz gc
```

Do not edit `archive/` in place. To change a retired skill, restore it, edit it,
seal it, and archive it again. The archive is history; rewriting it destroys the
only record of what was retired.

## External files

- Record every non-trivial external dependency with `skillz external add`.
- Prefer `--retention referenced` for URLs and large files; the cache can
  rebuild them. Use `--retention owned` only for bytes that must survive without
  the network.
- Never commit secrets, tokens, or private keys into `skills/`, `external/`, or
  `external.lock.json`. Put them in `state/` or the user's keychain.
- `skillz external verify` must pass before an archive operation.

## Serving and exposing

- `bin/skillz serve` binds loopback. Do not pass `--allow-non-loopback` unless a
  real auth gateway is in front of it and the user asked for that exposure.
- The WAN ingress is the public boundary. Its agreement, token and border key
  live under `state/ops/`; the tracked templates contain placeholders only.
- After changing `ops/`, run `ops/install.sh doctor`. A signed border probe must
  succeed and an unsigned probe must be refused.

## Reporting

Use `bin/skillz status --json` for machine-readable state. Use
`bin/skillz catalog` to refresh the human index after any tier change.
