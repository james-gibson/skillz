#!/bin/bash
# Isolated lifecycle smoke test. Runs in a temporary copy, so the canon is untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp -R "$ROOT/bin" "$ROOT/skills" "$ROOT/archive" "$ROOT/external" "$ROOT/cache" "$ROOT/state" "$TMP/"
cp "$ROOT/external.lock.json" "$TMP/"

mkdir -p "$TMP/fixture-skill"
cat > "$TMP/fixture-skill/SKILL.md" <<'EOF'
---
name: fixture-skill
description: A disposable skill created by tests/smoke.sh.
---

# Fixture skill

This file exists only for the lifecycle test.
EOF

cd "$TMP"

echo "== adopt =="
./bin/skillz adopt "$TMP/fixture-skill" --name fixture-skill
./bin/skillz verify

echo "== archive =="
./bin/skillz archive fixture-skill --reason "smoke test"
./bin/skillz verify

echo "== restore =="
./bin/skillz restore fixture-skill
./bin/skillz verify

echo "== cleanup =="
./bin/skillz archive fixture-skill --reason "smoke cleanup"
./bin/skillz verify

echo "smoke: ok"
