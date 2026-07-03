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

### Working in your real, logged-in session

Connect to your everyday Chrome (see [SKILL.md → Connect](./SKILL.md#connect)) instead of a throwaway profile, and the CLI acts with your existing cookies/logins — read a page behind SSO, export a signed-in dashboard to PDF, etc. **Stop at password/MFA/consent screens and hand back to the human.**
