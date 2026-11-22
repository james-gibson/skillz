# Sources — owned external payloads

Small files a skill needs and that must survive without the network live under
`external/<id>/`. The citation ledger is [`../external.lock.json`](../external.lock.json);
record entries with:

```sh
bin/skillz external add <id> <location> --used-by <skill> --retention owned
```

Re-fetchable or large sources use `--retention referenced` and are materialised
in `cache/external/` on demand. `bin/skillz external verify` checks every
materialised copy against the recorded SHA-256.
