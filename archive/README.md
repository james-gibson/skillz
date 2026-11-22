# Apocrypha — retired skills

Retired skills are kept, not deleted. Each entry is
`archive/<name>/<YYYY-MM-DD>/` and carries an `ARCHIVE.json` manifest with the
retirement reason, date, source and tree hash.

Treat this tier as append-only:

```sh
bin/skillz archive <name> --reason "..."
bin/skillz restore <name>
```

To change a retired skill, restore it, edit the canon copy, seal it, and archive
it again. Editing here in place destroys the record of what was retired.
