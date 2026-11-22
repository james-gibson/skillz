# The collection as lore

A skill is not a package. It is a **claim about how to act**, written down so a
later agent can act the same way. That makes a skill collection a small canon:
some texts are authoritative, some are retired but preserved, some are sources
cited by the texts, and some are working notes that can be swept away.

## Canon — `skills/`

The active tier. These are the texts an agent should follow. Each one is sealed:
its bytes are hashed into `skill.json`, so a change is visible rather than
silent. The canon is edited deliberately and re-sealed.

A skill enters the canon by **adoption**:

1. Its source is recorded (path, git URL, license).
2. Its bytes are copied, not moved, unless the caller asks for a move.
3. Its tree is hashed and its `SKILL.md` frontmatter is checked.
4. A symlink can make the old location a **view** of the canon, so there is one
   copy and not two.

## Apocrypha — `archive/`

Retired skills. Not deleted, not silently resurrected. Each archive entry carries
`ARCHIVE.json`: when it was retired, why, and the hash of what was retired. The
archive is append-only by convention. To change a retired skill, restore it,
edit the canon copy, seal it, and archive it again.

The point is not sentiment. It is that "why did we stop using this?" is exactly
the question a future agent will ask, and a deleted directory cannot answer it.

## Sources — `external/` and `external.lock.json`

A skill often depends on something it did not write: a component catalogue, a
font, a screenshot, a vendor's specification. The lock records the citation —
origin, hash, license, size, and which skills use it. Small owned payloads live
in `external/`; re-fetchable or large ones are materialised in the cache.

A source is **not** canon. It is evidence the canon cites. If it drifts, that is
a fact to check, not a reason to rewrite the skill silently.

A **hired skill** is the exception that proves the rule: the skill itself is
canon, and its repository, commit and license travel with it in
`sources.lock.json`. The alarm watches the pin, so an upstream change is visible
without a silent edit.

## Ephemera — `cache/`

Downloads, fetched sources, previews, indexes, adoption backups. Disposable by
design. `skillz gc` empties it. If losing a file would lose knowledge, the file
is in the wrong tier.

## Rites

| Rite | Command | Effect |
| --- | --- | --- |
| Adopt | `skillz adopt` | Bring a skill into the canon, with provenance. |
| Seal | `skillz seal` | Re-hash after a deliberate edit. |
| Verify | `skillz verify` | Check frontmatter, hashes, links, and citations. |
| Link | `skillz link` | Make an agent surface a view of the canon. |
| Archive | `skillz archive` | Move canon to apocrypha with a reason. |
| Restore | `skillz restore` | Bring apocrypha back to canon. |
| Sweep | `skillz gc` | Empty ephemera. |

## The living index

[`CATALOG.md`](../CATALOG.md) is generated, not hand-maintained. It is the
collection's table of contents: active skills, archived skills, and the source
ledger. Regenerate it after any tier change with `skillz catalog`.

## Why the tiers matter

Without the split, "skills" becomes an undifferentiated folder where a downloaded
zip, a retired experiment, a vendored font, and the text an agent must follow all
look the same. The split makes three questions answerable at a glance:

- **What should an agent read?** `skills/`.
- **What did we stop using, and why?** `archive/`.
- **What is merely a copy?** `cache/`.
