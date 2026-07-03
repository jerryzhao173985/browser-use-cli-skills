#!/usr/bin/env bash
# Collect grounded state from a canvas + WebSocket web app, via the browser-use CLI.
#
# Demonstrated on the HOMM3-web games (React + Canvas + PartyKit): drives the lobby to
# start a game vs an AI, then captures the AUTHORITATIVE state the server pushes over the
# WebSocket (CDP Network.webSocketFrameReceived) turn-by-turn -> JSON + screenshots.
#
# Two clearly-marked blocks:
#   * GENERIC  — WS-frame capture + the end-turn/time-series loop. Reuse as-is.
#   * APP-SPECIFIC — the lobby flow (create room / add AI / faction / ready / start).
#     Adapt the button/input text for YOUR app.
#
# Why WS frames (not the DOM or pixels): a canvas game renders to a bitmap, so the DOM has
# no game state; the structured, authoritative state travels on the WebSocket. Pixels are
# for visual verification only. See ../RECIPES.md and ../REFERENCE.md.
#
# Prereqs: browser-use connected to a browser (see ../SKILL.md -> Connect). For unattended
# runs, launch a dedicated headless Chrome and point at it:
#   chrome --user-data-dir=/tmp/bu --remote-debugging-port=9222 --headless=new about:blank &
#   export BU_CDP_URL=http://127.0.0.1:9222
#
# Usage: GAME_URL=http://localhost:5173 OUT=./game-data TURNS=5 ./game-state-collector.sh
set -euo pipefail
: "${GAME_URL:=http://localhost:5173}"
: "${OUT:=./game-data}"
: "${TURNS:=5}"
mkdir -p "$OUT"
export GAME_URL OUT TURNS

browser-use <<'PY'
import os, json
URL = os.environ["GAME_URL"]; OUT = os.environ["OUT"]; TURNS = int(os.environ["TURNS"])

# --- tiny helpers (single-call CDP ops only; NEVER fill_input — it is fragile in headless) ---
def btn(pat):  # locate a <button> by /regex/i on its text -> click coords
	return js("(function(){var b=[].slice.call(document.querySelectorAll('button')).find(function(x){return new RegExp(%r,'i').test(x.innerText)});if(!b)return null;var q=b.getBoundingClientRect();return{x:q.left+q.width/2,y:q.top+q.height/2,dis:!!b.disabled};})()" % pat)

def click_btn(pat, w=1.0):
	b = btn(pat)
	if b: click_at_xy(b["x"], b["y"]); wait(w)
	return b

def click_el(text, w=0.6):  # click a non-button element by exact text (e.g. a faction label)
	r = js("(function(){var els=[].slice.call(document.querySelectorAll('button,[role=button],div,span,label,li,a'));var el=els.find(function(e){return e.children.length<=1&&e.innerText&&e.innerText.trim()===%r&&e.offsetParent!==null;});if(!el)return null;var q=el.getBoundingClientRect();return{x:q.left+q.width/2,y:q.top+q.height/2};})()" % text)
	if r: click_at_xy(r["x"], r["y"]); wait(w)
	return r

def set_react_input(sel, val):  # React-safe: native value setter + input event (single js call)
	js("(function(){var i=document.querySelector(%r);if(!i)return;var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');d.set.call(i,%r);i.dispatchEvent(new Event('input',{bubbles:true}));})()" % (sel, val))

def drain_states():  # pull buffered WS frames, keep the {type:'state'} payloads
	out = []
	for e in drain_events():
		if e.get("method") == "Network.webSocketFrameReceived":
			pd = e["params"]["response"]["payloadData"]
			if '"type":"state"' in pd:
				try: out.append(json.loads(pd)["state"])
				except Exception: pass
	return out

# --- GENERIC: attach and arm WS capture BEFORE the socket opens ---
new_tab("about:blank"); cdp("Network.enable")
goto_url(URL); wait_for_load(); wait(1.5)

# ===== APP-SPECIFIC (HOMM3-web): start a game vs an AI. Adapt selectors for your app. =====
set_react_input("input[placeholder=Hero]", "Collector")
click_btn("create room", 2.5)
click_btn("add ai", 1.5)
click_el("Castle")               # pick our faction
click_btn("^ready$", 1.2)
sb = btn("start game")
if not sb or sb["dis"]:
	print(json.dumps({"error": "cannot start; adapt the lobby block",
	                  "buttons": js("[].slice.call(document.querySelectorAll('button')).map(function(x){return x.innerText.trim()})")}))
	raise SystemExit
click_btn("start game", 3.5)
# =========================================================================================

# --- GENERIC: initial authoritative state + map screenshot ---
states = drain_states()
day = states[-1].get("day", 0) if states else 0
if states:
	json.dump(states[-1], open("%s/state-day%02d.json" % (OUT, day), "w"), indent=2)
	print("initial: day", day, "players", len(states[-1].get("players", [])), "objects", len(states[-1].get("objects", {})))
capture_screenshot(OUT + "/map-start.png")

# --- GENERIC: end turns, capture the state after each (poll WS until the day advances) ---
series = []
for _ in range(TURNS):
	b = btn("end turn")
	if not b:
		print("no end-turn button (battle / game over) — stopping"); break
	click_at_xy(b["x"], b["y"])
	got = []
	for _ in range(30):                       # poll up to ~15s
		wait(0.5); got += drain_states()
		if got and (got[-1].get("day", 0) > day or got[-1].get("winner")): break
	if not got:
		print("no state after end-turn — stopping"); break
	st = got[-1]; day = st.get("day", day + 1)
	json.dump(st, open("%s/state-day%02d.json" % (OUT, day), "w"), indent=2)
	row = {"day": day, "gold": [[p.get("color"), p.get("resources", {}).get("gold")] for p in st.get("players", [])],
	       "battle": bool(st.get("battle")), "winner": st.get("winner")}
	series.append(row); print("captured", json.dumps(row))
	if st.get("winner"): break

json.dump(series, open(OUT + "/series.json", "w"), indent=2)
capture_screenshot(OUT + "/map-end.png")
print("DONE ->", OUT, "(state-day*.json, series.json, map-*.png)")
PY
