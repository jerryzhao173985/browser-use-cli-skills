---
name: browser-use
description: "Direct browser control via CDP for web interaction: automation, scraping, testing, screenshots, and site/app work."
---

# Browser Use CLI

Pipe Python into a live Chrome over CDP and read the result. Helpers are pre-injected and a daemon attaches to the browser *before* your code runs — nothing to import, no connection to manage.

```bash
browser-use <<'PY'
new_tab("https://example.com")     # first navigation is new_tab, not goto_url
print(page_info())                 # {url, title, w, h, sx, sy, pw, ph}
PY
```

## Mental model — the whole tool in 4 lines

- **`exec(your_python, helpers)` against one Chrome.** 37 helpers are already in scope; a daemon holds one CDP WebSocket to the browser.
- **Coordinate-first.** Interact by pixel: screenshot → find `(x, y)` → `click_at_xy(x, y)` → screenshot to confirm. CDP input passes through iframes / shadow-DOM / cross-origin; CSS selectors need not.
- **`js(...)` reads the DOM; `cdp("Domain.method", …)` is the raw escape hatch** (PDF, network, cookies, device emulation — the entire DevTools protocol).
- **Act → wait → verify.** Never assume: `wait_for_load` / `wait_for_element` / `wait_for_network_idle`, then read `page_info()` / DOM / server echo.

`http_get(url)` fetches **without** a browser — use it for static pages and APIs.

## Read next

- **[CHEATSHEET.md](./CHEATSHEET.md)** — core patterns, rules, and recovery. Start here for real work.
- **[REFERENCE.md](./REFERENCE.md)** — the full verified surface (37 helpers, env vars, connection modes, per-mechanic recipes).
- **[RECIPES.md](./RECIPES.md)** — complete end-to-end workflows (scrape, form, PDF, network capture, multi-tab, CI).

## Connect

- **Local (default):** attaches to your running Chrome. If it can't, open `chrome://inspect/#remote-debugging` → tick **"Allow remote debugging for this browser instance"** → Allow. (This is a native consent click; no process can do it for you.)
- **Dedicated / headless:** launch Chrome on a **non-default** `--user-data-dir` with `--remote-debugging-port=9222`, then `BU_CDP_URL=http://127.0.0.1:9222 browser-use <<'PY' … PY`. Chrome 136+ blocks the port flag on the *default* profile, which is why the real logged-in session needs the toggle above.
- **Recover** a wedged daemon: `browser-use --reload`. **Diagnose:** `browser-use --doctor`.
