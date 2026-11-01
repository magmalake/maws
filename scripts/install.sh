#!/usr/bin/env bash
# Symlinks build/maws into ~/.local/bin (or $MAWS_BIN_DIR).
#
# A symlink, not a copy: the binary finds the Mojo runtime and libcurl through
# an rpath into this checkout's .pixi environment, so it has to keep living
# here. Run through `pixi run install`, which builds first.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="${MAWS_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$dir"
ln -sf "$root/build/maws" "$dir/maws"
echo "installed $dir/maws -> $root/build/maws"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "note: $dir is not on your PATH; add it, e.g. export PATH=\"$dir:\$PATH\"" ;;
esac
