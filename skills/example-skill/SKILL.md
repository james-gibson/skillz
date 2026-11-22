---
name: example-skill
description: A minimal skill used to verify a skillz installation. Use when testing adopt, seal, verify, link, archive or the MCP read path before adding a real skill.
---

# Example skill

This is the smallest useful skill in the repository. It exists so a fresh
installation has something to list, verify and read before you add your own.

## Try the loop

```sh
./bin/skillz list
./bin/skillz verify
./bin/skillz search example
```

## What to expect

- `list` shows `example-skill`.
- `verify` reports one active skill and no errors.
- `search example` returns this file.

Replace this skill with your own when you are ready. The manifest is written by
`./bin/skillz seal <name>`; do not hand-write the hashes.
