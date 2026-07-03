# browser-use CLI skills

A curated, source-verified **[agent skill](https://code.claude.com/docs/en/skills)** for the **[Browser Use CLI 3.0](https://docs.browser-use.com/open-source/browser-use-cli)** (powered by `browser-harness`) — direct browser control over CDP for web automation, scraping, testing, and screenshots, headless or headful.

## The one idea

Browser Use CLI runs **Python you pipe in** against a live Chrome:

```bash
browser-use <<'PY'
new_tab("https://example.com")
print(page_info())
PY
```

Mentally it is `exec(your_python, helpers)` — a daemon holds **one** CDP WebSocket to the browser, and your heredoc runs in a namespace of 37 pre-injected helpers. Everything else reduces to three questions: *which browser* (connection), *which helpers* (API), and *what interaction discipline* (coordinate-first; act → wait → verify).

This repo keeps that knowledge **minimal and first-principles** — verified against the installed package source and validated with live runs — so an agent (Claude Code, Codex, Cursor, …) uses the CLI correctly and to its full surface, not just the basics.

## Layout — progressive disclosure

| File | Purpose | Read when |
|---|---|---|
| [`SKILL.md`](./SKILL.md) | Entry + mental model | auto-loaded by the agent |
| [`CHEATSHEET.md`](./CHEATSHEET.md) | Core patterns, rules, recovery | doing real work |
| [`REFERENCE.md`](./REFERENCE.md) | Full verified surface — 37 helpers, env vars, connection modes, per-mechanic recipes | looking something up |
| [`RECIPES.md`](./RECIPES.md) | Complete end-to-end workflows | building a specific task |
| [`scripts/install.sh`](./scripts/install.sh) | Copy the skill into an agent's skills dir | first time / after edits |
| [`scripts/check-update.sh`](./scripts/check-update.sh) | Detect when the CLI's surface changed | periodically |
| [`helpers.snapshot.txt`](./helpers.snapshot.txt) | Recorded helper surface + versions | diff baseline |
| [`examples/`](./examples/) | Headless E2E test harness for canvas+WS games (`game-e2e.sh`) + a project-testing guide (scenario matrix, per-game config) | adapting to a real task |

## Install

```bash
uv tool install --python 3.12 browser-use   # the CLI itself (aliases: bu, browser, browseruse)
./scripts/install.sh                          # -> ~/.claude/skills/browser-use/
# other agents: ./scripts/install.sh ~/.codex/skills/browser-use
```

## Staying in sync

The skill's surface is defined by the `browser-harness` package; when it updates, helpers can be added or changed. Check drift at any time:

```bash
./scripts/check-update.sh          # report version + added/removed helpers vs the snapshot
./scripts/check-update.sh --save   # accept the current surface as the new baseline
```

It compares the **installed** helper surface and version against `helpers.snapshot.txt` and reports whether a newer `browser-use` is on PyPI. If helpers changed, update the docs and re-run with `--save`.

## Provenance

Verified against the installed `browser-harness` source — **37/37 helpers confirmed** present (0 hallucinated); 3 doc-only env vars corrected. Validated live: navigate · structured extract · screenshot (full-page) · scroll · tabs · coordinate-click → navigation · form submit (server-verified) · PDF via CDP · network capture · cookies · mobile emulation.
