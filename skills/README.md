# Canon — active skills

Each directory here is one currently usable skill:

```
<name>/
├── SKILL.md        required; frontmatter name + description
├── skill.json      written by `skillz adopt` / `skillz seal`
├── references/     optional supporting text
└── assets/         optional small files
```

Names are lowercase and unique across active and archived tiers. Do not put a
downloaded archive or a scratch copy here; those belong in `cache/`.

```sh
bin/skillz list --tier active
bin/skillz verify
```
