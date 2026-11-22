# Install

`skillz` is a Python 3 CLI and a stdlib MCP server. There is no package to install, no daemon to
run, and no service to sign up for.

## Requirements

- Python 3.9 or newer.
- Git.
- macOS or Linux. The CLI is plain Python; the optional `ops/` integration assumes a POSIX shell and
  the author's lab binaries.

## Clone and verify

```sh
git clone https://github.com/james-gibson/skillz.git
cd skillz
./bin/skillz init
./bin/skillz verify
```

`init` creates the tier directories if they are missing. `verify` should report one active skill
(`example-skill`) and no errors.

## Put the CLI on your PATH

The repository is self-contained; `./bin/skillz` works from any shell. If you want the bare command:

```sh
./install.sh                    # symlink into ~/.local/bin
# or choose a prefix
./install.sh --prefix /usr/local
```

Make sure the target directory is on your `PATH`. `install.sh` refuses to replace a non-symlink.

## Your first skill

Create a source directory outside the store. A skill is one `SKILL.md`:

```sh
mkdir -p /tmp/my-skill
cat > /tmp/my-skill/SKILL.md <<'EOF'
---
name: my-skill
description: Use when doing the one thing this skill is for.
---

# My skill

Say what to do, when to do it, and what to check before calling it done.
EOF

./bin/skillz adopt /tmp/my-skill --move --link
./bin/skillz verify
./bin/skillz list
```

`--move --link` copies the skill into `skills/my-skill/`, records provenance in `skill.json`,
removes the source, and replaces it with a symlink to the canon. Without `--move`, the source stays
where it is and you have two copies.

## Install the canon into an agent surface

```sh
./bin/skillz link                          # all active skills -> ~/.agents/skills
./bin/skillz link my-skill --into ~/.agents/skills
./bin/skillz unlink my-skill
```

A link is a view. The canon remains in this repository; deleting the link does not delete the skill.
If an upstream installer later recreates the directory, `./bin/skillz inventory` reports the drift;
`link --force` re-asserts the view after you confirm the installer's copy is not newer.

## Run the MCP server

```sh
./bin/skillz serve --port 8090
```

In another shell:

```sh
curl -s -X POST http://127.0.0.1:8090/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"skills/status","params":{}}'
```

The server binds loopback and has no write methods. See the
[read-only surface page](https://james-gibson.github.io/le.gume/docs/skillz-ingress/) for the
boundary and the checks.

## Optional: the lab integration

`ops/` wires the surface to a smoke-alarm, a dedicated adhd instance and a `wan-ingress` front. It
requires those binaries and is not needed for the core install. If you have them:

```sh
ops/install.sh up
ops/install.sh doctor
ops/install.sh down
```

The public repository keeps the `wan-ingress` path generic: set `WAN_INGRESS_BIN=/path/to/wan-ingress`
or install it on `PATH`.

## Uninstall

```sh
rm "$HOME/.local/bin/skillz"     # if installed with ./install.sh
rm -rf cache state               # disposable runtime
```

The repository itself is the store; removing it removes the canon. Archive or copy the skills you
want to keep first.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `env: python3: No such file` | Python is not installed or not on `PATH` | install Python 3.9+ |
| `Permission denied` running `bin/skillz` | the execute bit was lost in a copy | `chmod +x bin/skillz` |
| `verify`: missing `skill.json` | a skill was added by hand | `bin/skillz seal <name>` |
| `verify`: tree hash mismatch | the skill changed after sealing | `bin/skillz seal <name>` |
| `link` refuses a directory | the destination is not a symlink | inspect it, then use `--force` if the canon should win |
| MCP server refuses to bind | the host is not loopback | use `127.0.0.1`; `--allow-non-loopback` is an explicit exception |
