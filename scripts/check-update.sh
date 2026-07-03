#!/usr/bin/env bash
# Detect when the browser-use CLI's helper surface or version drifts from the committed snapshot.
# The surface is defined by the `browser-harness` package; this reads it statically (no browser needed).
# Usage: ./scripts/check-update.sh [--save]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAP="$HERE/helpers.snapshot.txt"

# Locate the installed browser_harness package (import path first, uv-tool path as fallback).
# `|| true` keeps a failing lookup from aborting under `set -e` before the friendly guard below.
PKG="$(python3 - <<'PY' 2>/dev/null || true
import importlib.util, pathlib
s = importlib.util.find_spec("browser_harness")
print(pathlib.Path(s.origin).parent if s and s.origin else "")
PY
)"
if [ -z "$PKG" ] || [ ! -d "$PKG" ]; then
	PKG="$(ls -d "$HOME"/.local/share/uv/tools/browser-use/lib/python*/site-packages/browser_harness 2>/dev/null | head -1 || true)"
fi
if [ -z "$PKG" ] || [ ! -d "$PKG" ]; then
	echo "browser_harness not found. Install: uv tool install --python 3.12 browser-use" >&2
	exit 1
fi

# Emit the current surface + versions in snapshot format (3 header lines, then sorted helper names).
# AST-based so it survives import-style / async-def changes; version = newest matching .dist-info.
current() {
	python3 - "$PKG" <<'PY'
import ast, re, sys, pathlib
pkg = pathlib.Path(sys.argv[1]); sp = pkg.parent

def ver(name):
	best = None
	for cand in (name.replace('-', '_'), name):
		for d in sp.glob(cand + "-*.dist-info"):
			v = d.name[len(cand) + 1:-len(".dist-info")]
			key = tuple(int(x) for x in re.findall(r'\d+', v))
			if best is None or key > best[0]:
				best = (key, v)
	return best[1] if best else "?"

def module_defs(path):            # public module-level (async) functions
	if not path.exists():
		return set()
	tree = ast.parse(path.read_text())
	return {n.name for n in tree.body
			if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and not n.name.startswith('_')}

def admin_injected(path):         # public callables pulled into the namespace via `from .admin import ...`
	if not path.exists():
		return set()
	out = set()
	for n in ast.walk(ast.parse(path.read_text())):
		if isinstance(n, ast.ImportFrom) and (n.module or '').endswith('admin'):
			for a in n.names:
				nm = a.asname or a.name
				if nm != '*' and not nm.startswith('_') and not nm.isupper():   # drop wildcard, private, CONSTANTS
					out.add(nm)
	return out

helpers = sorted(module_defs(pkg / "helpers.py") | admin_injected(pkg / "run.py"))
print(f"browser-harness={ver('browser-harness')}")
print(f"browser-use={ver('browser-use')}")
print(f"helpers={len(helpers)}")
for h in helpers:
	print(h)
PY
}

CUR="$(current)"

if [ "${1:-}" = "--save" ]; then
	printf '%s\n' "$CUR" > "$SNAP"
	echo "Saved snapshot -> $SNAP"
	printf '%s\n' "$CUR" | head -3
	exit 0
fi

echo "== installed =="
printf '%s\n' "$CUR" | head -3

LATEST="$(curl -s -m 5 https://pypi.org/pypi/browser-use/json 2>/dev/null \
	| python3 -c "import sys,json;print(json.load(sys.stdin)['info']['version'])" 2>/dev/null || echo '?')"
INSTALLED_BU="$(printf '%s\n' "$CUR" | sed -n 's/^browser-use=//p')"
echo "PyPI latest browser-use: $LATEST (installed: ${INSTALLED_BU:-?})"
if [ "$LATEST" != "?" ] && [ -n "$INSTALLED_BU" ] && [ "$LATEST" != "$INSTALLED_BU" ]; then
	echo "  -> upgrade: uv tool install --python 3.12 --upgrade browser-use"
fi

if [ ! -f "$SNAP" ]; then
	echo "No snapshot yet. Create the baseline: ./scripts/check-update.sh --save"
	exit 0
fi

added="$(comm -13 <(sed '1,3d' "$SNAP" | sort) <(printf '%s\n' "$CUR" | sed '1,3d' | sort))"
removed="$(comm -23 <(sed '1,3d' "$SNAP" | sort) <(printf '%s\n' "$CUR" | sed '1,3d' | sort))"
if [ -z "$added" ] && [ -z "$removed" ]; then
	echo "Helper surface: unchanged vs snapshot."
else
	echo "Helper surface CHANGED — review, update the docs, then re-run with --save:"
	[ -n "$added" ]   && printf '%s\n' "$added"   | sed 's/^/  + /'
	[ -n "$removed" ] && printf '%s\n' "$removed" | sed 's/^/  - /'
fi
