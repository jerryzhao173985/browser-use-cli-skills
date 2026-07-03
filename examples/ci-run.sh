#!/usr/bin/env bash
# Self-contained one-command E2E runner: launches an ISOLATED headless Chrome (unique profile +
# free port + unique BU_NAME, so runs don't collide / can go parallel), runs game-e2e.sh under a
# global timeout, and tears everything down on exit. Use this in CI or for a quick local gate.
#
# Usage:  GAME=heros3 TURNS=6 ./ci-run.sh
# Prereq: the game's dev server is up (homm3 :5173 / heros3 :5174); browser-use installed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME="${GAME:-homm3}"; TURNS="${TURNS:-6}"; OUT="${OUT:-./e2e-$GAME}"
mkdir -p "$OUT"

command -v browser-use >/dev/null 2>&1 || { echo "browser-use not installed: uv tool install --python 3.12 browser-use"; exit 3; }
CHROME="${CHROME:-}"
if [ -z "$CHROME" ]; then
	for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "$(command -v google-chrome 2>/dev/null || true)" "$(command -v chromium 2>/dev/null || true)"; do
		[ -n "$c" ] && [ -x "$c" ] && CHROME="$c" && break
	done
fi
[ -z "$CHROME" ] && { echo "no Chrome binary found (set CHROME=...)"; exit 3; }

PROFILE="$(mktemp -d)"
PORT="${PORT:-$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")}"
export BU_NAME="e2e-${GAME}-$$"
LOG="$OUT/run.log"
CHROME_PID=""
cleanup() { browser-use --reload >/dev/null 2>&1 || true; [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null || true; pkill -f "$PROFILE" 2>/dev/null || true; rm -rf "$PROFILE"; }
trap cleanup EXIT

nohup "$CHROME" --user-data-dir="$PROFILE" --remote-debugging-port="$PORT" --headless=new \
	--window-size="${WINDOW:-1600,1000}" --no-first-run --no-default-browser-check --disable-gpu about:blank >/dev/null 2>&1 &
CHROME_PID=$!
r="$(curl -s --retry 25 --retry-connrefused --retry-delay 1 -m3 "http://127.0.0.1:$PORT/json/version" 2>/dev/null || true)"
[ -z "$r" ] && { echo "Chrome CDP did not come up on :$PORT"; exit 3; }
export BU_CDP_URL="http://127.0.0.1:$PORT"

BUDGET=$((60 + TURNS * 30))
TIMEOUT="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
set +e
if [ -n "$TIMEOUT" ]; then
	GAME="$GAME" OUT="$OUT" TURNS="$TURNS" "$TIMEOUT" "$BUDGET" bash "$HERE/game-e2e.sh" 2>&1 | tee "$LOG"; rc=${PIPESTATUS[0]}
else
	GAME="$GAME" OUT="$OUT" TURNS="$TURNS" bash "$HERE/game-e2e.sh" 2>&1 | tee "$LOG"; rc=${PIPESTATUS[0]}
fi
set -e
[ "$rc" = "124" ] && echo "TIMEOUT after ${BUDGET}s (exit 124)"
echo "runner exit: $rc — report: $OUT/report.json, history: $OUT/e2e-history.jsonl, log: $LOG"
exit "$rc"
