#!/usr/bin/env bash
# Headless E2E test + data collector for canvas + WebSocket web games, via browser-use.
#
# Drives the REAL client (lobby -> start vs an AI -> play N turns), asserts functionality
# from the server's authoritative WebSocket state, and saves a JSON time-series + screenshots.
# This validates the whole stack the way a human runs it — client render + WS + server —
# not just the wire protocol. Exit 0 iff all HARD checks pass (battle_engaged is soft).
#
# Presets for the two HOMM3-web games (React + Canvas + PartyKit). Select with GAME=homm3|heros3.
# The assertions are shape-tolerant (hero pos as {x,y} or top-level x/y; hex or named colors),
# so they generalize; adapt the LOBBY preset (button/input text) for a different app.
#
# Prereqs: the game's dev server is running, and browser-use is connected to a browser
# (see ../SKILL.md -> Connect; e.g. a dedicated headless Chrome + BU_CDP_URL).
#
# Usage:  GAME=heros3 OUT=./e2e-heros3 TURNS=6 ./game-e2e.sh
set -euo pipefail
GAME="${GAME:-homm3}"; OUT="${OUT:-./e2e-out}"; TURNS="${TURNS:-6}"
case "$GAME" in
	homm3)  : "${URL:=http://localhost:5173}"; NAME_SEL='input[placeholder=Hero]';               ADD_AI='add ai';    READY='^ready$';          START='start game';;
	heros3) : "${URL:=http://localhost:5174}"; NAME_SEL='input[placeholder="Lord of the realm"]'; ADD_AI='summon ai'; READY='ready for battle'; START='start game';;
	*) echo "unknown GAME=$GAME (use homm3|heros3, or set URL + selectors)"; exit 2;;
esac
FACTION="${FACTION:-Castle}"
mkdir -p "$OUT"
export GAME URL OUT TURNS NAME_SEL ADD_AI FACTION READY START

browser-use <<'PY'
import os, json
E = os.environ
URL, OUT, TURNS = E["URL"], E["OUT"], int(E["TURNS"])
NAME_SEL, ADD_AI, FACTION, READY, START = E["NAME_SEL"], E["ADD_AI"], E["FACTION"], E["READY"], E["START"]

results = []
def check(name, ok, detail=""):
	results.append((name, bool(ok)))
	print(("PASS " if ok else "FAIL "), name, ("- %s" % (detail,)) if detail != "" else "")

# --- robust interaction (single-call CDP only; never fill_input) ---
def click_btn(pat, w=1.0):
	b = js("(function(){var b=[].slice.call(document.querySelectorAll('button')).find(function(x){return new RegExp(%r,'i').test((x.innerText||'').trim())});if(!b)return null;var q=b.getBoundingClientRect();return{x:q.left+q.width/2,y:q.top+q.height/2,dis:!!b.disabled};})()" % pat)
	if b and not b["dis"]: click_at_xy(b["x"], b["y"]); wait(w)
	return b
def click_el(text, w=0.8):     # any leaf element by exact text (faction is a button OR a span)
	r = js("(function(){var els=[].slice.call(document.querySelectorAll('button,[role=button],div,span,label,li,a'));var el=els.find(function(e){return e.children.length<=1&&e.innerText&&e.innerText.trim()===%r&&e.offsetParent!==null;});if(!el)return null;var q=el.getBoundingClientRect();return{x:q.left+q.width/2,y:q.top+q.height/2};})()" % text)
	if r: click_at_xy(r["x"], r["y"]); wait(w)
	return r
def set_input(sel, val):
	js("(function(){var i=document.querySelector(%r);if(!i)return;var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');d.set.call(i,%r);i.dispatchEvent(new Event('input',{bubbles:true}));})()" % (sel, val))
def set_faction(fac, w=0.8):   # homm3 uses a <select>, heros3 a <button>: try the select, else click the element
	hit = js("(function(){var ss=document.querySelectorAll('select');for(var i=0;i<ss.length;i++){var s=ss[i];for(var j=0;j<s.options.length;j++){if(new RegExp(%r,'i').test(s.options[j].text||s.options[j].value)){var d=Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype,'value');d.set.call(s,s.options[j].value);s.dispatchEvent(new Event('change',{bubbles:true}));return 'select';}}}return null;})()" % fac)
	if hit: wait(w); return hit
	return click_el(fac, w)

# --- WS state capture (handles both {type:'state'} and {type:'gameStarted'} frames) ---
def states_from(evs):
	out = []
	for e in evs:
		if e.get("method") == "Network.webSocketFrameReceived":
			pd = e["params"]["response"]["payloadData"]
			if '"type":"state"' in pd or '"type":"gameStarted"' in pd:
				try:
					m = json.loads(pd)
					if isinstance(m.get("state"), dict): out.append(m["state"])
				except Exception: pass
	return out
def poll(pred, timeout=18):
	acc = []
	for _ in range(int(timeout / 0.5)):
		wait(0.5); acc += states_from(drain_events())
		if acc and pred(acc[-1]): break
	return acc

def gold(p):
	r = p.get("resources"); return (r or {}).get("gold", 0) if isinstance(r, dict) else 0
def heroes_of(st):
	h = st.get("heroes", {}); return list(h.values()) if isinstance(h, dict) else (h or [])
def hpos(h):                    # normalize pos across shapes: {x,y} | [x,y] | top-level x/y
	p = h.get("pos")
	if isinstance(p, dict): return (h.get("owner"), p.get("x"), p.get("y"))
	if isinstance(p, (list, tuple)) and len(p) >= 2: return (h.get("owner"), p[0], p[1])
	return (h.get("owner"), h.get("x"), h.get("y"))
def positions(st): return sorted((hpos(h) for h in heroes_of(st)), key=lambda t: str(t))
def army(h):
	a = h.get("army", []); return sum((u or {}).get("count", 0) for u in a if u) if isinstance(a, list) else 0

# ===== drive lobby -> start (arm WS capture BEFORE the socket opens) =====
new_tab("about:blank"); cdp("Network.enable")
goto_url(URL); wait_for_load(); wait(1.5)
set_input(NAME_SEL, "E2E")
click_btn("create room", 2.5)
click_btn(ADD_AI, 1.5)
set_faction(FACTION)
click_btn(READY, 1.2)
click_btn(START, 3.5)

start = poll(lambda s: isinstance(s.get("players"), list) and len(s["players"]) >= 2, 18)
check("game_starts", bool(start), "no gameStarted/state frame — adapt the lobby preset" if not start else "")
if not start:
	print("\nRESULT: FAIL (game did not start)"); raise SystemExit(1)
st0 = start[-1]; json.dump(st0, open(OUT + "/state-day01.json", "w"), indent=2)
capture_screenshot(OUT + "/map-start.png")

players = st0.get("players", [])
h0 = heroes_of(st0)
check("two_players", len(players) == 2, "players=%d" % len(players))
check("starting_gold", all(gold(p) > 0 for p in players), [gold(p) for p in players])
check("factions_assigned", all(p.get("faction") for p in players), [p.get("faction") for p in players])
check("heroes_present", len(h0) >= 2, "heroes=%d" % len(h0))
check("heroes_have_army", all(army(h) > 0 for h in h0), [army(h) for h in h0])
check("map_populated", len(st0.get("objects", {})) > 0, "objects=%d" % len(st0.get("objects", {})))

# ===== play turns: assert day advances, income accrues, AI acts, combat engages =====
series = [{"day": st0.get("day"), "gold": [gold(p) for p in players], "pos": positions(st0)}]
day = st0.get("day", 1); saw_battle = False; income = False; moved = False
for t in range(TURNS):
	b = click_btn("end.?turn", 0.3)
	if not b:
		print("(no End Turn button — battle in progress or game over)"); saw_battle = saw_battle or bool(series[-1].get("battle")); break
	nxt = poll(lambda s: s.get("day", 0) > day or s.get("winner") or s.get("battle"), 18)
	if not nxt: print("(no new state after End Turn)"); break
	st = nxt[-1]; nd = st.get("day", day + 1); pg = [gold(p) for p in st.get("players", [])]
	if st.get("battle"): saw_battle = True
	if any(pg[i] > series[-1]["gold"][i] for i in range(min(len(pg), len(series[-1]["gold"])))): income = True
	if positions(st) != series[-1]["pos"]: moved = True
	series.append({"day": nd, "gold": pg, "pos": positions(st), "battle": bool(st.get("battle"))})
	json.dump(st, open(OUT + "/state-day%02d.json" % nd, "w"), indent=2)
	print("  turn %d -> day %s  gold %s  battle=%s" % (t + 1, nd, pg, bool(st.get("battle"))))
	day = nd
	if st.get("winner"): break

check("day_advances", series[-1]["day"] > series[0]["day"], "%s -> %s" % (series[0]["day"], series[-1]["day"]))
check("income_accrues", income, "a player's gold rose across a turn")
check("ai_acts", moved, "a hero changed position (AI played)")
check("battle_engaged", saw_battle, "combat triggered within %d turns [soft]" % TURNS)
json.dump(series, open(OUT + "/series.json", "w"), indent=2)
capture_screenshot(OUT + "/map-end.png")

npass = sum(1 for _, ok in results if ok)
hard_ok = all(ok for name, ok in results if name != "battle_engaged")
print("\n=== %s E2E: %d/%d checks passed (battle_engaged is soft) ===" % (E["GAME"], npass, len(results)))
print("RESULT:", "PASS" if hard_ok else "FAIL")
raise SystemExit(0 if hard_ok else 1)
PY
