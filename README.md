# skillz

**A canonical, tiered store for agent skills — with a read-only MCP face.**

A skill is a claim about how to act, written down so a later agent can act the same way. Once the
same claim lives in `~/.agents/skills`, a project's `.opencode/skills`, and a worktree's
`.claude/skills`, "which one is true?" has no answer that survives a new session.

`skillz` answers it once: one directory is canon, the other locations are views, retired skills are
kept rather than deleted, and every adopted skill carries a hash that `verify` recomputes.

## Install

```sh
git clone https://github.com/james-gibson/skillz.git
cd skillz
./bin/skillz init
./bin/skillz verify
```

Python 3.9+ and git. No packages, no build step. To put the CLI on your `PATH`:

```sh
./install.sh                  # ~/.local/bin/skillz
# or
export PATH="$PWD/bin:$PATH"
```

The first-skill walkthrough, the optional MCP server, and uninstall are in
[INSTALL.md](INSTALL.md).

## The four tiers

| Tier | Path | Tracked? | Lifetime | What belongs here |
| --- | --- | --- | --- | --- |
| **Active** | `skills/` | git | long-term | The canonical, currently usable skills. One directory per skill. |
| **Archive** | `archive/` | git | permanent | Retired skills, stored as `archive/<name>/<YYYY-MM-DD>/` with an `ARCHIVE.json` manifest. Append-only by convention. |
| **External** | `external/` + `external.lock.json` | git + lock | long-term | Files a skill depends on. Small owned payloads live under `external/`; anything re-fetchable or too large is referenced in the lock and materialised in the cache on demand. |
| **Cache** | `cache/` | **ignored** | disposable | Downloads, fetched externals, indexes, previews, adoption backups. Deleting it loses nothing that cannot be rebuilt. |

`state/` is a fifth, runtime-only area: pids, ports, generated configs and logs. It is ignored by git
and is **never** a source of truth.

The full rationale, including the canon/apocrypha/ephemera/sources framing, is in
[`docs/LORE.md`](docs/LORE.md). The hard rules are in [`CONVENTIONS.md`](CONVENTIONS.md). The agent
contract is in [`AGENTS.md`](AGENTS.md).

## The loop

| Act | Command | What it changes |
| --- | --- | --- |
| Inventory | `./bin/skillz inventory` | nothing; reports candidates, duplicates and drift |
| Adopt | `./bin/skillz adopt <path>` | copies into `skills/`, writes `skill.json` |
| Hire | `./bin/skillz hire <repo> --path <path>` | pins a skill from another repository |
| Sync | `./bin/skillz sync --check` | reports upstream drift without changing the canon |
| Update | `./bin/skillz sync --update` | refreshes a drifted pin and reseals |
| Seal | `./bin/skillz seal <name>` | re-hashes after an intentional edit |
| Verify | `./bin/skillz verify` | checks frontmatter, hashes, links and citations |
| Link | `./bin/skillz link` | symlinks the canon into an agent surface |
| Archive | `./bin/skillz archive <name> --reason "..."` | moves to `archive/<name>/<date>/` |
| Restore | `./bin/skillz restore <name>` | moves back and reseals |
| Sweep | `./bin/skillz gc` | empties `cache/` |

A link is a view, not a second copy. If an installer recreates `~/.agents/skills/<name>` as a real
directory, the canon has not moved: `inventory` reports the drift, and `link --force` re-asserts the
view after you confirm the installer's copy is not newer.

The repository ships one example skill, [`skills/example-skill`](skills/example-skill), so a fresh
clone has something to list, verify and read over MCP before you add your own.

## External sources

A skill may depend on something it did not write. Record it so the dependency is checkable:

```sh
./bin/skillz external add brand-assets ~/Pictures/brand.png \
  --used-by example-skill --retention owned
./bin/skillz external add component-spec https://fancy-ui.rama.app/llms.txt \
  --used-by example-skill --retention referenced --fetch
./bin/skillz external verify
```

`external.lock.json` records origin, SHA-256, size, license, which skills use it, and whether the
bytes are **owned** (`external/`, committed) or **referenced** (`cache/external/`, rebuildable).

## Hiring an expert

A skill can be pinned from another repository without losing its source. The skill becomes canon;
the commit it came from stays recorded:

```sh
./bin/skillz hire https://github.com/mattpocock/skills \
  --path skills --all --exclude deprecated,in-progress,misc \
  --license MIT --group mattpocock/skills \
  --note "Matt Pocock's engineering and productivity skills"
./bin/skillz sync --check
./bin/skillz sync --update
```

`--all` imports every `SKILL.md` under the path (minus the excluded segments) as one expert bundle.
`ask-matt` is the router; the rest of the set is what it routes to. Omit `--all` to hire one skill.

`hire` vendors each skill into `skills/<name>/`, copies the upstream `LICENSE`, writes
`sources.lock.json` with the repo, ref, commit, path and tree hash, and records the commit in
`skill.json`. Every member shares a `group`, and `sync --check` resolves the repository/ref once for
the whole group. `sync --update` refreshes the vendored copies and reseals them. Local edits are
replaced by `--update`; fork deliberately, not by accident.

A source does not have to be a person. The official shadcn/ui skill is one directory in a framework
monorepo, pinned the same way:

```sh
./bin/skillz hire https://github.com/shadcn-ui/ui \
  --path skills/shadcn --license MIT --group shadcn-ui/ui
```

The alarm watches the pin. The MCP server advertises the `sync` capability only while every source
is current, and the optional `skillz-sync` target requires `sync/current`. A new upstream commit
removes the capability and turns that light yellow until the pin is updated.

## The MCP surface

`./bin/skillz serve` exposes a **read-only** JSON-RPC surface on loopback:

| Method | Answers |
| --- | --- |
| `initialize` | the MCP handshake; advertises the `skills` capability |
| `skills/status` | counts, cache size and readiness |
| `skills/list` | active or archived skills with descriptions and hashes |
| `skills/read` | one skill's `SKILL.md`, file list and provenance |
| `skills/search` | a substring search across the active and archived tiers |
| `sync/status` | pinned sources and whether any has drifted |
| `tools/list`, `tools/call` | the same operations as MCP tools |

Default bind: `127.0.0.1:8090`. The server refuses a non-loopback bind unless
`--allow-non-loopback` is passed explicitly. There are no write methods: the CLI owns mutation, the
wire is read-only.

## Lab integration (optional)

The author's lab wires the surface to a smoke-alarm, a dedicated adhd dashboard and a `wan-ingress`
front. That integration lives under [`ops/`](ops/README.md) and is **optional**: the core CLI and
MCP server do not import it. If you do not run those binaries, skip the directory.

## Documentation

The long-form pages are a le.gume seed:

- [The skill repository](https://james-gibson.github.io/le.gume/seeds/skillz/) — the seed
- [One owner for every skill](https://james-gibson.github.io/le.gume/docs/skillz/) — the model
- [A read-only surface behind an alarm](https://james-gibson.github.io/le.gume/docs/skillz-ingress/) — the boundary
- [Adopt a skill collection](https://james-gibson.github.io/le.gume/guides/skillz-adoption/) — the task

## Security posture

- **Loopback by default.** The MCP server and the lab integration bind `127.0.0.1`.
- **Fail closed.** A missing border key disables the border; a missing token disables ingress
  admission; a missing agreement refuses the name.
- **Read-only wire.** There is no MCP method that writes, deletes or archives.
- **Secrets stay in `state/`.** `state/` is gitignored; generated configs carry the secrets, not the
  templates.
- **Cache is not canon.** `cache/` can be deleted at any time without losing an active or archived
  skill.

## What it is not

A registry, a version resolver, a multi-user permission system, or a firewall. It is custody for one
owner on one machine, with a read-only surface for the processes that need to look. The costs are
listed on the [seed page](https://james-gibson.github.io/le.gume/seeds/skillz/).

## Layout

```
skillz/
├── bin/skillz                the CLI
├── server/skillz_mcp.py      read-only MCP server (stdlib only)
├── skills/                   active canon, including one example
├── archive/                  retired skills, append-only
├── external/                 owned external payloads
├── external.lock.json        citation ledger
├── sources.lock.json         hired-repository pins
├── cache/                    disposable (gitignored)
├── state/                    runtime, logs and secrets (gitignored)
├── ops/                      optional lab integration
├── docs/LORE.md              canon / apocrypha / ephemera / sources
├── CONVENTIONS.md            naming, manifests, hashing, archive rules
├── AGENTS.md                 the agent contract
├── INSTALL.md                install and first-skill walkthrough
└── tests/smoke.sh            isolated lifecycle test
```

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
