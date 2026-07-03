#!/usr/bin/env bash
# Install the browser-use skill into an agent's skills directory.
# Usage: ./scripts/install.sh [TARGET_DIR]   (default: ~/.claude/skills/browser-use)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$HOME/.claude/skills/browser-use}"

mkdir -p "$TARGET"
for f in SKILL.md CHEATSHEET.md REFERENCE.md RECIPES.md; do
	cp "$HERE/$f" "$TARGET/$f"
	echo "  + $f"
done
echo "Installed browser-use skill -> $TARGET"

command -v browser-use >/dev/null 2>&1 \
	|| echo "Note: 'browser-use' not on PATH — install it with: uv tool install --python 3.12 browser-use"
