# browser-use CLI skills

Source-verified agent skill for the **[Browser Use CLI 3.0](https://docs.browser-use.com/open-source/browser-use-cli)** (`browser-harness`) — direct browser control over CDP — **plus a headless QA harness for canvas + WebSocket web games**. Everything here is verified against the installed package source and proven with live runs.

## What this is — two things

1. **A skill** that teaches an agent (Claude Code, Codex, Cursor, …) to use the Browser Use CLI correctly and to its *full* surface — mental model, the 37 helpers, connection modes, and end-to-end recipes.
2. **A game-QA toolkit** — a headless, self-contained E2E harness that drives a real canvas+WebSocket game client and asserts functionality from the authoritative state (built and proven on the HOMM3-web games `~/homm3` and `~/heros3`).

## The one idea

Browser Use CLI runs **Python you pipe in** against a live Chrome:

```bash
browser-use <<'PY'
new_tab("https://example.com")
print(page_info())
PY
```

Mentally: `exec(your_python, helpers)` — a daemon holds **one** CDP WebSocket to the browser, and your heredoc runs in a namespace of 37 pre-injected helpers. Everything reduces to *which browser* (connection), *which helpers* (API), *what discipline* (coordinate-first; act → wait → verify).

## Contents

**The skill — how to use browser-use** (progressive disclosure: read top-down)

| File | Purpose |
|---|---|
| [`SKILL.md`](./SKILL.md) | Entry + 4-line mental model (auto-loaded by the agent) |
| [`CHEATSHEET.md`](./CHEATSHEET.md) | Core patterns, rules, recovery — start here for real work |
| [`REFERENCE.md`](./REFERENCE.md) | Full verified surface: 37 helpers, env vars, connection modes, per-mechanic recipes |
| [`RECIPES.md`](./RECIPES.md) | End-to-end workflows (scrape, form, PDF, WebSocket capture, canvas moves) |

**Game-QA toolkit** — headless E2E testing for canvas + WebSocket games (`examples/`)

| File | Purpose |
|---|---|
| [`testing-canvas-ws-games.md`](./examples/testing-canvas-ws-games.md) | The guide: mental model, scenario matrix, per-game config, a pasteable prompt |
| [`game-e2e.sh`](./examples/game-e2e.sh) | 15-check E2E gate → `report.json` + commit-keyed `e2e-history.jsonl` + `FAIL-*.png`; exit 0 = PASS |
| [`ci-run.sh`](./examples/ci-run.sh) | One-command self-contained runner (own headless Chrome + teardown) |

**Install & stay current**

| File | Purpose |
|---|---|
| [`scripts/install.sh`](./scripts/install.sh) | Copy the skill into an agent's skills dir |
| [`scripts/check-update.sh`](./scripts/check-update.sh) + [`helpers.snapshot.txt`](./helpers.snapshot.txt) | Detect when the CLI's helper surface drifts |

## Install

```bash
uv tool install --python 3.12 browser-use   # the CLI (aliases: bu, browser, browseruse)
./scripts/install.sh                          # -> ~/.claude/skills/browser-use/  (or pass ~/.codex/... etc.)
```

## Use it for game QA

```bash
GAME=heros3 TURNS=6 ./examples/ci-run.sh      # exit 0 = PASS. Full guide: examples/testing-canvas-ws-games.md
```

## Stay in sync

```bash
./scripts/check-update.sh          # helper-surface + version drift vs the snapshot
./scripts/check-update.sh --save   # accept the current surface as the new baseline
```

## Provenance

Verified against the installed `browser-harness` source — **37/37 helpers confirmed** (0 hallucinated); doc-only env vars corrected by an adversarial source review. Validated live: navigate · extract · screenshot · scroll · tabs · coordinate-click · form submit · PDF · network/WS capture · cookies · mobile emulation · **full game E2E** (homm3 14/15, heros3 13/15 PASS).
