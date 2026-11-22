# Contributing

The store is small on purpose. Keep changes to one logical act, and keep the
checks green.

## Before you push

```sh
./bin/skillz verify
./tests/smoke.sh
```

`verify` checks the canon: frontmatter, tree hashes, relative links and external
citations. `tests/smoke.sh` runs an isolated adopt/archive/restore cycle in a
temporary copy, so it does not touch your canon.

## Adding a skill

1. Create `skills/<name>/SKILL.md` with `name` and `description` frontmatter.
2. Add supporting files under `references/` or `assets/` if the skill needs them.
3. Seal it: `./bin/skillz seal <name>`.
4. Regenerate the index: `./bin/skillz catalog`.
5. Run `./bin/skillz verify`.

The `skill.json` manifest is generated; do not hand-edit the hashes. If the skill
comes from another repository, record the source and license in the manifest
(`adopt --source ... --license ...`) and leave the upstream copy in place.

## Rules

- No secrets, tokens or private keys in `skills/`, `external/` or
  `external.lock.json`. Use `state/` for runtime secrets.
- Record non-trivial external files with `./bin/skillz external add`.
- `archive/` is append-only. Restore, edit, seal and archive again rather than
  editing a retired copy.
- The MCP surface is read-only. Do not add a write method to the wire; add a CLI
  command and test it.
- The license is AGPL-3.0-only. Contributions are accepted under it.

## Reporting a problem

Include the output of `./bin/skillz status --json` and `./bin/skillz verify`.
If the problem is in the optional `ops/` integration, name the binary and the
`doctor` check that failed.
