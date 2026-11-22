# ops — optional lab integration

> **Optional.** The core CLI and MCP server do not import this directory. It is
> the author's lab wiring: a smoke-alarm, a dedicated adhd dashboard and a
> `wan-ingress` front. Skip it if you do not run those binaries.

The collection is not a service, but it has a **read-only service face** so the
author's lab can see whether it is answering.

| File | Rendered to | Purpose |
| --- | --- | --- |
| `smoke-alarm.yaml.tmpl` | `state/ops/smoke-alarm.yaml` | Watches `skillz-mcp` (requires `skills/read`), `skillz-sync` (requires `sync/current`) and, when enabled, the WAN ingress. |
| `adhd.yaml.tmpl` | `state/ops/adhd.yaml` | A loopback adhd instance that polls the alarm and renders the light. |
| `ingress-agreement.json.tmpl` | `state/ops/agreements.json` | The name `skillz` resolves to the local MCP border. |
| `wan-ingress.json.tmpl` | `state/ops/wan-ingress.json` | Fail-closed ingress config: loopback bind, bearer token, signed border. |

## Commands

```sh
ops/install.sh up                  # MCP + alarm + adhd
ops/install.sh up --with-ingress   # also start wan-ingress and watch it
ops/install.sh ingress             # start the ingress and watch it now
ops/install.sh status
ops/install.sh doctor
ops/install.sh logs -f
ops/install.sh down
```

`doctor` runs five checks:

1. `skillz verify` — the canon is internally consistent.
2. `skillz probe` — the MCP surface answers `initialize`, `skills/status` and
   `sync/status`.
3. `skillz ingress-probe` — a request signed with the border key is accepted,
   and an unsigned request is refused.
4. `skillz sync --check --strict` — every hired source still matches its pin.
5. The alarm reports every enabled target `healthy`.

The `skillz-sync` target is the reason an upstream change is visible without
looking for it: the server advertises the `sync` capability only while every pin
is current, and the alarm requires `sync/current`. A new upstream commit removes
the capability and turns that light yellow. `skillz sync --update` refreshes the
vendored copy, reseals it, and restores the capability.

## Secrets

`state/ops/secrets.env` is generated on first render with mode `600` and holds
the ingress bearer token and border key. `state/ops/border.key` is the server's
copy of the border key. Delete `secrets.env` (and restart) to rotate both; the
MCP server and ingress are rendered from the same values, so they stay in step.

The tracked templates contain **no secrets**. `state/` is gitignored.

## Ports

| Service | Default | Override |
| --- | --- | --- |
| skillz MCP | `127.0.0.1:8090` | `SKILLZ_MCP_PORT` |
| smoke-alarm health | `127.0.0.1:18098` | `SKILLZ_ALARM_PORT` |
| adhd instance | `127.0.0.1:9091` | `SKILLZ_ADHD_PORT` |
| wan-ingress | `127.0.0.1:8443` | `SKILLZ_INGRESS_PORT` |

All four are loopback. The ingress is the only process intended to face a WAN,
and only behind its own token admission and signed border.

## Why not a launchd plist?

This is a development surface, not a boot-time service. `up`/`down` keep it
honest and easy to inspect. If it becomes permanent, install it under your host's
service manager — the unit belongs to the new service, and the generated config
stays in `state/ops/`.
