#!/bin/sh
# Install the skillz CLI as a symlink in a bin directory.
#
#   ./install.sh
#   ./install.sh --prefix /usr/local
#   PREFIX="$HOME/bin" ./install.sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"

if [ "${1:-}" = "--prefix" ]; then
  [ $# -ge 2 ] || { echo "usage: $0 [--prefix DIR]" >&2; exit 2; }
  PREFIX="$2"
fi

BIN="$PREFIX/bin"
mkdir -p "$BIN"

if [ -e "$BIN/skillz" ] && [ ! -L "$BIN/skillz" ]; then
  echo "refusing to replace non-symlink: $BIN/skillz" >&2
  echo "remove it first, or choose another prefix with --prefix" >&2
  exit 1
fi

chmod +x "$ROOT/bin/skillz"
ln -sfn "$ROOT/bin/skillz" "$BIN/skillz"
echo "installed $BIN/skillz -> $ROOT/bin/skillz"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "add $BIN to PATH to run 'skillz' without the full path" ;;
esac
