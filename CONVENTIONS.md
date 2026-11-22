# Conventions

## Skill names

- Lowercase, `a-z0-9`, then `a-z0-9._-`; 1–64 characters.
- The directory name is the skill name. `SKILL.md` frontmatter `name:` must match.
- A name is unique across active and archived tiers. Restoring a name that is
  already active is refused; archive under a new name or resolve the collision.

## `SKILL.md`

```yaml
---
name: shieldcn-badges
description: >-
  Use when creating README badges...
---
```

`name` and `description` are required. The description says **when** to use the
skill, not only what it is. Body content is free-form.

## `skill.json`

Every active skill has one, written by `skillz adopt` or `skillz seal`:

```json
{
  "schema": 1,
  "name": "pouf",
  "description": "...",
  "tier": "active",
  "adopted_at": "2026-11-21T21:00:00Z",
  "sealed_at": "2026-11-21T21:00:00Z",
  "source": {
    "type": "path | git | url | authored",
    "location": "~/.agents/skills/pouf",
    "ref": null,
    "license": null
  },
  "tags": [],
  "tree_hash": "sha256:...",
  "files": { "SKILL.md": "sha256:...", "references/x.md": "sha256:..." },
  "external": []
}
```

- `tree_hash` is canonical: SHA-256 over `relpath NUL filedigest LF` for every
  regular file, sorted by path, excluding `skill.json` and junk (`.git`,
  `__pycache__`, `.DS_Store`, `*.pyc`).
- `files` is the per-file map used to explain a drift.
- `external` is a list of IDs from `external.lock.json`.
- `seal` is the only writer of `tree_hash`/`files` after adoption.

## Adoption from a tracked repository

If the source skill is tracked by another git repository, `skillz adopt` copies
it and leaves the source in place. The canonical copy is then a **fork**:
`skillz inventory` reports the repo copy as `drift` when it changes. Merge the
change deliberately, run `skillz seal <name>`, and do not silently overwrite
either side. Untracked sources may be moved and linked back, which is the
one-copy model used for the global skills.

## Hired sources

A skill may be vendored from another repository and still be canon.
`sources.lock.json` is the pin ledger:

```json
{
  "schema": 1,
  "sources": {
    "mattpocock/skills/code-review": {
      "repo": "https://github.com/mattpocock/skills",
      "ref": "main",
      "commit": "abeeaf95660ba9e8b7c753eb38f441ca707a8823",
      "path": "skills/engineering/code-review",
      "skill": "code-review",
      "license": "MIT",
      "tree_hash": "sha256:...",
      "hired_at": "2026-11-22T...",
      "updated_at": "2026-11-22T..."
    }
  }
}
```

The vendored `skill.json` carries the same repository, commit, path and license
under `source`. `verify` requires the two records to agree and the vendored tree
to match `tree_hash`.

- `hire` copies the skill and the upstream root `LICENSE`.
- `sync --check` resolves the exact branch or tag and compares the pin; it does
  not change the canon. Results are written to `state/sync.json` (ignored).
- `sync --update` replaces the vendored tree and reseals it. Local edits are
  lost; if you intend to diverge, remove the source entry and treat the skill as
  authored instead.
- The MCP server advertises `sync` only while every pin is current. The optional
  `skillz-sync` alarm target requires `sync/current`, so an upstream commit turns
  the light yellow until the pin is updated.

## Archive

`archive/<name>/<YYYY-MM-DD>/` holds the retired copy. `ARCHIVE.json` records:

```json
{
  "schema": 1,
  "name": "pouf",
  "tier": "archive",
  "archived_at": "2026-11-21T21:00:00Z",
  "date": "2026-11-21",
  "reason": "superseded",
  "tree_hash": "sha256:...",
  "files": { "...": "..." },
  "source": { "...": "..." }
}
```

The archived tree still contains its `skill.json`. `ARCHIVE.json` is the archive
tier's own manifest; `verify` recomputes both hashes. The directory is treated as
immutable: restore it to change it.

## `external.lock.json`

```json
{
  "schema": 1,
  "entries": {
    "shieldcn-readme": {
      "id": "shieldcn-readme",
      "location": "https://example.com/readme.md",
      "kind": "url",
      "retention": "referenced",
      "sha256": "...",
      "size": 1234,
      "license": "MIT",
      "used_by": ["shieldcn-badges"],
      "added_at": "2026-11-21T21:00:00Z",
      "fetched_at": "2026-11-21T21:05:00Z",
      "storage": "cache/external/shieldcn-readme/readme.md"
    }
  }
}
```

- `retention: owned` means the bytes are committed under `external/<id>/`.
- `retention: referenced` means the bytes live at `location` and may be cached
  under `cache/external/<id>/`; a cache miss is a warning, not a loss of canon.
- `used_by` lists active or archived skill names. An unknown name is a warning.
- `sha256` is recorded when known. If it is present, `verify` checks every
  materialised copy (owned and cached) against it.

## Cache and state

- `cache/` may be emptied by `skillz gc` at any time. Nothing there is canon.
- `state/` holds pids, ports, generated configs, and logs. It is gitignored and
  recreated by `ops/install.sh up`.
- Generated configs under `state/ops/` may contain secrets; the templates under
  `ops/` may not.

## Commits

One logical change per commit. `skillz verify` and `skillz catalog` before
committing. Do not commit `cache/`, `state/`, or generated secrets.
