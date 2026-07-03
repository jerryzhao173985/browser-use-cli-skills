# Recipes — end-to-end workflows

Complete, runnable workflows. Each is a `browser-use` heredoc; the patterns/rules behind them are in [CHEATSHEET.md](./CHEATSHEET.md), the full API in [REFERENCE.md](./REFERENCE.md).

> Assumes a connected browser (see [SKILL.md → Connect](./SKILL.md#connect)). For unattended/CI runs, prefix each command with `BU_CDP_URL=http://127.0.0.1:9222` after launching a dedicated headless Chrome on that port.

---

### 1. Scrape a list → JSON (headless)

```bash
browser-use <<'PY'
new_tab("https://news.ycombinator.com"); wait_for_load(); wait_for_network_idle(timeout=8)
rows = js("""Array.from(document.querySelectorAll('tr.athing')).slice(0,10).map(r => {
  const a = r.querySelector('.titleline > a'); const sub = r.nextElementSibling;
  return {title: a?.innerText, href: a?.href, points: sub?.querySelector('.score')?.innerText || '0'};
})""")
print(json.dumps(rows, indent=2))
PY
```

### 2. Full-page screenshot for a visual check

```bash
browser-use <<'PY'
new_tab("https://example.com"); wait_for_load()
print("saved:", capture_screenshot("/tmp/page.png", full=True, max_dim=1800))
PY
```

### 3. Fill and submit a form — then verify it landed

```bash
browser-use <<'PY'
new_tab("https://your.site/signup"); wait_for_element("#email", timeout=15)
# bulk text: one js call (robust). For React/Vue controlled inputs use fill_input(sel, val) instead.
js("(()=>{const s=(q,v)=>{const e=document.querySelector(q); e.value=v; e.dispatchEvent(new Event('input',{bubbles:true}));}; s('#email','me@example.com'); s('#name','Jerry');})()")
r = js("(()=>{const b=[...document.querySelectorAll('button,[type=submit]')].find(x=>/submit|sign/i.test(x.innerText||x.value)); const q=b.getBoundingClientRect(); return {x:q.left+q.width/2, y:q.top+q.height/2};})()")
click_at_xy(r["x"], r["y"]); wait_for_network_idle(timeout=10)
print("now at:", page_info()["url"])            # verify by outcome, not assumption
PY
```

### 4. Export a page to PDF (via raw CDP)

```bash
browser-use <<'PY'
new_tab("https://example.com"); wait_for_load()
pdf = base64.b64decode(cdp("Page.printToPDF", printBackground=True)["data"])
open("/tmp/page.pdf", "wb").write(pdf)
print("PDF bytes:", len(pdf), "ok:", pdf[:5] == b"%PDF-")
PY
```

### 5. Capture the API calls a page makes

```bash
browser-use <<'PY'
new_tab("about:blank"); cdp("Network.enable")             # enable Network on THIS tab's session first
goto_url("https://example.com"); wait_for_load(); wait(2)  # let requests fire; do NOT wait_for_network_idle here — it drains the event buffer
reqs = [e["params"]["request"] for e in drain_events() if e.get("method") == "Network.requestWillBeSent"]
for r in reqs: print(r["method"], r["url"])
PY
```

### 6. Multi-tab fan — extract the title of several pages

```bash
browser-use <<'PY'
for url in ["https://example.com", "https://news.ycombinator.com"]:
	tid = new_tab(url); wait_for_load()
	print(url, "->", page_info()["title"])
print("open tabs:", [t["url"] for t in list_tabs(include_chrome=False)])
PY
```

---

### 7. Capture a realtime app's live state over its WebSocket

Games, dashboards, chat, and trading UIs push **authoritative state over a WebSocket** — richer and more reliable than scraping the DOM (a canvas app has *no* state in the DOM). Arm `Network.enable` **before** the socket opens, then filter `drain_events()` for frames:

```bash
browser-use <<'PY'
new_tab("about:blank"); cdp("Network.enable")          # enable BEFORE the WS connects
goto_url("https://app.example.com"); wait_for_load(); wait(2)
frames = [e["params"]["response"]["payloadData"] for e in drain_events()
          if e.get("method") == "Network.webSocketFrameReceived"]     # ...FrameSent for outbound
print("captured", len(frames), "WS frames")
for f in frames:
    if '"type":"state"' in f: json.dump(json.loads(f), open("/tmp/state.json", "w"))
PY
```

For a **headless E2E test harness** that drives the real client (lobby → start vs AI → N turns), *asserts* functionality from the live state (game starts, resources/armies correct, day advances, income accrues, AI acts, combat engages), returns `PASS`/`FAIL` + exit code, and saves a JSON time-series + screenshots, see [`examples/game-e2e.sh`](./examples/game-e2e.sh) — shape-tolerant, verified green on two canvas+PartyKit games (`GAME=homm3|heros3`). It exercises the real client (render + WS + server), so it fails when the *UI* breaks, not just the protocol. Full project-testing guide + scenario matrix: [`examples/testing-canvas-ws-games.md`](./examples/testing-canvas-ws-games.md).

---

### 8. Drive a canvas game — coordinate moves

Canvas games take **clicks, not DOM events**. Invert the renderer's own click→tile transform (read it from source — e.g. `tile = floor((clientX − rect.left + camera) / TILE)`), then click the pixel. **Re-read the transform after every move** — the camera usually re-centers, shifting it.

```bash
browser-use <<'PY'
T = 64   # tile px, from the renderer
cr = js("(function(){var c=document.querySelector('canvas');var b=c.getBoundingClientRect();return{left:b.left,top:b.top,cam:window.__cam};})()")
def px(tx, ty): return (cr["left"] + tx*T + T/2 - cr["cam"]["x"], cr["top"] + ty*T + T/2 - cr["cam"]["y"])
click_at_xy(*px(hero_x, hero_y))     # select the unit
click_at_xy(*px(dest_x, dest_y))     # move; re-read cr, then verify the move landed via the WS state
PY
```

**Move semantics vary** (verified live on heros3): some games move on one click; others **preview on the first click and move on the second** — double-click the same pixel. And destinations must be **reachable** — click an empty tile *toward* a guarded objective, not the objective's own tile (a guarded mine won't accept a move onto it). Always confirm the result via the WS state, not the click.

Tip: in a dev build, expose the camera on `window` (`window.__cam = camera`) so tests convert tiles→pixels exactly — a tiny, test-only hook that makes canvas automation deterministic. heros3 does exactly this (`window.__h3cam`).

---

### Working in your real, logged-in session

Connect to your everyday Chrome (see [SKILL.md → Connect](./SKILL.md#connect)) instead of a throwaway profile, and the CLI acts with your existing cookies/logins — read a page behind SSO, export a signed-in dashboard to PDF, etc. **Stop at password/MFA/consent screens and hand back to the human.**
