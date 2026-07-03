# Browser Use CLI — Best-Usage Cheatsheet

Core, clear points for doing webpage work with the `browser-use` CLI. **Read this first; use [`REFERENCE.md`](./REFERENCE.md) for the full verified surface (37 helpers, all env vars, connection modes, per-mechanic recipes).**

`browser-use` runs **Python you pipe in** against a live Chrome over CDP. Helpers are pre-injected; there's no `import`. (Mental model → [`SKILL.md`](./SKILL.md).)

---

## Invoke (the one correct form)

```bash
browser-use <<'PY'
new_tab("https://example.com")      # FIRST navigation is new_tab, not goto_url
print(page_info())
PY
```
- Quote the heredoc marker `<<'PY'` so the shell doesn't touch your Python. Essential for JS-heavy code (regexes, `$`, backticks): use `<<'PY'` and pass file paths via env vars read with `os.environ` inside — an unquoted heredoc mangles backslashes/`$` in your JS.
- ⚠︎ `-c/--code` does **not** run code (telemetry only). Always use the heredoc.
- Aliases: `bu`, `browser`, `browseruse`. Ephemeral: `uvx browser-use <<'PY' …`.

---

## What it's best at  ·  what it's not for

**Best at:** reading/understanding a page (`page_info`+`js`), structured extraction/scraping, screenshots (incl. full-page), coordinate clicking through hostile DOMs (iframes/shadow/cross-origin), raw-CDP power moves (PDF, network capture, cookies, device emulation), driving your real logged-in session, and cheap browserless fetches (`http_get`).

**Not the right tool for:** static pages/JSON APIs where no rendering is needed → use `http_get()`. Deeply framework-controlled inputs at scale → see the typing note below.

---

## Core patterns (copy-paste)

**Read a page**
```python
new_tab("https://site.com"); wait_for_load()
print(page_info())                       # {url,title,w,h,sx,sy,pw,ph}
```

**Extract structured data** (the workhorse)
```python
rows = js("Array.from(document.querySelectorAll('.item')).map(e => ({t:e.innerText, href:e.querySelector('a')?.href}))")
```

**Click something** (coordinate-first)
```python
r = js("(()=>{const el=document.querySelector('button'); const q=el.getBoundingClientRect(); return {x:q.left+q.width/2, y:q.top+q.height/2};})()")
click_at_xy(r["x"], r["y"]); wait_for_load()   # then re-read/screenshot to confirm
```
On a screenshot you read yourself: PNGs are **device pixels** → divide target by `js("devicePixelRatio")` before `click_at_xy`.

**Fill a form** (prefer single-call writes)
```python
# bulk text: one js call, framework-agnostic, robust
js("(()=>{const s=(q,v)=>{const e=document.querySelector(q); e.value=v; e.dispatchEvent(new Event('input',{bubbles:true}));}; s('#name','Jerry'); s('#email','a@b.com');})()")
# single-field typing that fires real key events:
js("document.querySelector('#q').focus()"); type_text("hello")   # one Input.insertText call
# non-text controls:
js("document.querySelector('input[value=medium]').click()")
```

**Wait correctly** (pick by situation)
```python
wait_for_load()                      # document complete — MISSES SPAs
wait_for_element("#app", visible=True)  # after route changes / lazy render
wait_for_network_idle(timeout=8)     # best signal after submits / XHR
```

**Tabs**
```python
tid = new_tab("https://a.com"); list_tabs(include_chrome=False); switch_tab(tid); current_tab()
```

**Raw CDP / generate artifacts**
```python
open("/tmp/p.pdf","wb").write(base64.b64decode(cdp("Page.printToPDF", printBackground=True)["data"]))  # base64/json pre-injected
cdp("Network.enable"); ...; [e for e in drain_events() if e["method"]=="Network.requestWillBeSent"]  # HTTP; use "Network.webSocketFrameReceived" for WS frames (realtime/game state)
cdp("Network.getCookies")["cookies"]
cdp("Emulation.setDeviceMetricsOverride", width=390, height=844, deviceScaleFactor=3, mobile=True)
```

**Browserless fetch** (no render, fast)
```python
html = http_get("https://api.site.com/data")   # for static pages / APIs
```

---

## Best-practice rules

- **Coordinate-click for interaction; `js` for reading.** Don't fight the DOM to click — screenshot and click the pixel.
- **Always verify.** Read `page_info()`/DOM/server echo after acting. SPA submits can succeed with *no* DOM change → use `wait_for_network_idle`.
- **Text entry: single-call; avoid `fill_input`.** Use `js` value-set (bulk) or `type_text` (one `Input.insertText`). For React/Vue controlled inputs, one `js` call with the native setter: `Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,val); el.dispatchEvent(new Event('input',{bubbles:true}))`. `fill_input` types char-by-char (N `Input` events) and can **wedge or crash headless Chrome** — last resort only.
- **`new_tab` to start, `goto_url` to navigate an already-attached tab.** If the tab looks internal/stale, `ensure_real_tab()`.
- **Reach for `cdp(...)` freely** — PDF, network, cookies, emulation, downloads all live there; helpers only cover the common 20%.
- **Cloud/remote:** `browser-use auth login` → `start_remote_daemon("work")` → run with `BU_NAME=work` → `stop_remote_daemon("work")`. Unique `BU_NAME` per parallel agent; **billing runs until stop/timeout** — stop when done.

---

## When it breaks (recovery)

- **Everything times out (`IPC recv timed out`)** → the daemon↔browser channel wedged (often after a stalled call on a slow page). Fix: `browser-use --reload` (stops daemon; next call respawns fresh). If the browser itself died, relaunch it, then run again.
- **`DevToolsActivePort not found` / can't connect** → see [SKILL.md → Connect](./SKILL.md#connect) (enable the `chrome://inspect` toggle, or attach a dedicated `--remote-debugging-port` Chrome via `BU_CDP_URL`). If the browser itself died, relaunch it, then retry.
- **Diagnose:** `browser-use --doctor`.

---

## Beyond the basics (full potential)

- **Extend the harness.** Missing a primitive? Write it into `$BH_AGENT_WORKSPACE/agent_helpers.py` once — it's auto-injected (import-free) on every future run. This is how the tool *compounds*. (REFERENCE §3.5)
- **Domain skills.** For a known site, pull its playbook from the upstream **97-site library** first (`gh api …/domain-skills/<site>`); `BH_DOMAIN_SKILLS=1` surfaces local ones via `goto_url`.
- **Browserless + anti-bot.** `from fetch_use import fetch_sync` → POST / `json_body` / `proxy_country` / `session_id` / `.content` — no render, fewer tokens (needs `BROWSER_USE_API_KEY`). `http_get` is just its `.text`.
- **Cloud vs local.** Default **local attach** (legit fingerprint, free, your logged-in session); escalate to **cloud** only for bot-protected / geo-locked targets (stealth + residential proxy + Cloudflare/DataDome bypass + captcha).
- **Secrets.** Pass creds via env, read `os.environ[...]` **inside** the quoted heredoc (never inline — shell history/telemetry). Autonomous 2FA: `import pyotp; pyotp.TOTP(os.environ["TOTP_SECRET"]).now()`. `browser-use telemetry disable` for sensitive runs.
- **Cloud login handoff.** `start_remote_daemon` returns a `liveUrl` — share it so a human does SSO/MFA/CAPTCHA; the daemon stays authenticated for your next call.

## Depth

Full signatures, connection-mode precedence, the env-var table, and every interaction recipe → [`REFERENCE.md`](./REFERENCE.md).
