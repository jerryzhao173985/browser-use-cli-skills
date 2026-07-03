#!/usr/bin/env bash
# Headless E2E test + data collector for canvas + WebSocket web games, via browser-use.
#
# Drives the REAL client (lobby -> start vs AI -> N turns), asserts functionality from the
# server's authoritative WebSocket state, drives one canvas hero-move (the human-input path),
# tests page-reload reconnect, and writes machine-readable results for tracking. Exit 0 iff
# all HARD checks pass (soft checks never fail the gate). Presets for the two HOMM3-web games.
#
# Tracking: OUT/report.json (full run, per-check detail + metrics) and an append-only
# e2e-history.jsonl keyed by the GAME repo's git SHA — so `jq 'select(.result=="FAIL")'` tells
# you which scenario broke on which commit. On any hard failure: OUT/FAIL-<check>.png.
#
# Determinism: neither game is reproducible today (both fold Date.now() into the seed). To pin
# a seed for replay/golden work, add the ~2-line server seam (see docs) and run under
# `partykit dev --var SEED=...`. This gate is a seed-agnostic INVARIANT check by design.
#
# Prereqs: game dev server running + browser-use connected (BU_CDP_URL). For a one-command
# self-contained run (launches its own Chrome, tears down), use examples/ci-run.sh.
#
# Usage:  GAME=heros3 OUT=./e2e TURNS=6 ./game-e2e.sh
set -euo pipefail
GAME="${GAME:-homm3}"; OUT="${OUT:-./e2e-out}"; TURNS="${TURNS:-6}"
case "$GAME" in
	homm3)  : "${URL:=http://localhost:5173}"; : "${GAME_DIR:=$HOME/homm3}";  NAME_SEL='input[placeholder=Hero]';               ADD_AI='add ai';    READY='^ready$';          START='start game'; MOVE='none';;
	heros3) : "${URL:=http://localhost:5174}"; : "${GAME_DIR:=$HOME/heros3}"; NAME_SEL='input[placeholder="Lord of the realm"]'; ADD_AI='summon ai'; READY='ready for battle'; START='start game'; MOVE='h3cam';;
	*) echo "unknown GAME=$GAME (use homm3|heros3, or set URL/GAME_DIR/selectors)"; exit 2;;
esac
FACTION="${FACTION:-Castle}"; ROOM="${ROOM:-}"
mkdir -p "$OUT"
GSHA="$(git -C "$GAME_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$GAME_DIR" diff --quiet 2>/dev/null && GDIRTY=clean || GDIRTY=dirty
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HIST="${HIST:-$OUT/e2e-history.jsonl}"
export GAME URL OUT TURNS NAME_SEL ADD_AI FACTION READY START MOVE ROOM FACTION GSHA GDIRTY TS HIST

browser-use <<'PY'
import os, json
E = os.environ
URL, OUT, TURNS, MOVE = E["URL"], E["OUT"], int(E["TURNS"]), E["MOVE"]
NAME_SEL, ADD_AI, FACTION, READY, START, ROOM = E["NAME_SEL"], E["ADD_AI"], E["FACTION"], E["READY"], E["START"], E["ROOM"]

results = []   # (name, ok, soft, detail)
metrics = {}
def check(name, ok, detail="", soft=False):
	results.append((name, bool(ok), soft, str(detail)))
	print(("PASS " if ok else ("SOFT " if soft else "FAIL ")), name, ("- %s" % (detail,)) if detail != "" else "")
	if not ok and not soft:
		try: capture_screenshot("%s/FAIL-%s.png" % (OUT, name))
		except Exception: pass

# ---------- robust element helpers (poll until present+enabled; never fill_input) ----------
def wait_js(expr, timeout=6.0):
	for _ in range(int(timeout / 0.3)):
		r = js(expr)
		if r: return r
		wait(0.3)
	return None
def _btn(pat):
	return ("(function(){var b=[].slice.call(document.querySelectorAll('button')).find(function(x){return new RegExp(%r,'i').test((x.innerText||'').trim())&&!x.disabled&&x.offsetParent!==null});"
	        "if(!b)return null;var q=b.getBoundingClientRect();return{x:q.left+q.width/2,y:q.top+q.height/2};})()") % pat
def click_btn(pat, after=1.0, timeout=6.0):
	r = wait_js(_btn(pat), timeout)
	if r: click_at_xy(r["x"], r["y"]); wait(after)
	return r
def click_el(text, after=0.8, timeout=6.0):
	expr = ("(function(){var els=[].slice.call(document.querySelectorAll('button,[role=button],div,span,label,li,a'));"
	        "var el=els.find(function(e){return e.children.length<=1&&e.innerText&&e.innerText.trim()===%r&&e.offsetParent!==null;});"
	        "if(!el)return null;var q=el.getBoundingClientRect();return{x:q.left+q.width/2,y:q.top+q.height/2};})()") % text
	r = wait_js(expr, timeout)
	if r: click_at_xy(r["x"], r["y"]); wait(after)
	return r
def set_input(sel, val):
	js("(function(){var i=document.querySelector(%r);if(!i)return;var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');d.set.call(i,%r);i.dispatchEvent(new Event('input',{bubbles:true}));})()" % (sel, val))
def set_faction(fac, w=0.8):   # homm3 <select> | heros3 <button>
	hit = js("(function(){var ss=document.querySelectorAll('select');for(var i=0;i<ss.length;i++){var s=ss[i];for(var j=0;j<s.options.length;j++){if(new RegExp(%r,'i').test(s.options[j].text||s.options[j].value)){var d=Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype,'value');d.set.call(s,s.options[j].value);s.dispatchEvent(new Event('change',{bubbles:true}));return 'select';}}}return null;})()" % fac)
	if hit: wait(w); return hit
	return click_el(fac, w)

# ---------- WS state capture ----------
def states(evs):
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
		wait(0.5); acc += states(drain_events())
		if acc and pred(acc[-1]): break
	return acc

# ---------- schema-tolerant accessors (works across homm3/heros3 shapes) ----------
def me_player(st):
	return next((p for p in st.get("players", []) if not (p.get("isAI") or p.get("isBot"))), (st.get("players") or [{}])[0])
def heroes_list(st):
	h = st.get("heroes", {}); return list(h.values()) if isinstance(h, dict) else (h or [])
def my_heroes(st, me):
	ids = me.get("heroes")
	if ids: return [h for h in heroes_list(st) if h.get("id") in ids]
	return [h for h in heroes_list(st) if h.get("owner") in (me.get("color"), me.get("id"))]
def gold(p):
	r = p.get("resources"); return (r or {}).get("gold", 0) if isinstance(r, dict) else 0
def hpos(h):
	p = h.get("pos")
	if isinstance(p, dict): return (h.get("owner"), p.get("x"), p.get("y"))
	if isinstance(p, (list, tuple)) and len(p) >= 2: return (h.get("owner"), p[0], p[1])
	return (h.get("owner"), h.get("x"), h.get("y"))
def positions(st): return sorted((hpos(h) for h in heroes_list(st)), key=lambda t: str(t))
def army(h):
	a = h.get("army", []); return sum((u or {}).get("count", 0) for u in a if u) if isinstance(a, list) else 0

def lobby_drift(step):
	check("lobby_drives", False, "LOBBY-DRIFT: step '%s' found no enabled element (selector drift?)" % step)

# ===== drive lobby -> start (with retry — lobby timing can flake) =====
def try_lobby(attempt):
	new_tab("about:blank"); cdp("Network.enable")
	goto_url(URL); wait_for_load(); wait(2.0 + attempt)
	set_input(NAME_SEL, "E2E")
	for pat, aft in [("create room", 2.5), (ADD_AI, 1.5)]:
		if not click_btn(pat, aft): return None, pat
	set_faction(FACTION); wait(0.6)
	for pat, aft in [(READY, 1.5), (START, 3.5)]:
		if not click_btn(pat, aft): return None, pat
	s = poll(lambda s: isinstance(s.get("players"), list) and len(s["players"]) >= 2 and len(heroes_list(s)) >= 2, 18)
	return (s, None) if s else (None, "no state frame")
start = None; drift_step = None
for attempt in range(3):
	start, drift_step = try_lobby(attempt)
	if start: break
	print("lobby attempt %d failed at '%s' — retrying" % (attempt + 1, drift_step))
if not start and drift_step and drift_step != "no state frame":
	lobby_drift(drift_step)
check("game_starts", bool(start), "no gameStarted/state frame" if not start else "")
if not start:
	try:
		json.dump({"body": js("document.body.innerText.slice(0,600)")}, open(OUT + "/FAIL-game_starts.json", "w"))
		capture_screenshot(OUT + "/FAIL-game_starts.png")
	except Exception: pass
	print("\nRESULT: FAIL (game did not start)")
else:
	st0 = start[-1]; json.dump(st0, open(OUT + "/state-day01.json", "w"), indent=2)
	capture_screenshot(OUT + "/map-start.png")
	players = st0.get("players", []); me = me_player(st0); mh0 = my_heroes(st0, me)

	# --- schema-drift guard: the ~10 paths this harness reads must exist ---
	missing = []
	if not isinstance(players, list) or len(players) < 1: missing.append("players[]")
	else:
		if not isinstance(players[0].get("resources"), dict) or "gold" not in (players[0].get("resources") or {}): missing.append("players[].resources.gold")
		if "faction" not in players[0]: missing.append("players[].faction")
	if not heroes_list(st0): missing.append("heroes")
	elif not mh0: missing.append("player->hero link (heroes list / owner)")
	elif "army" not in mh0[0]: missing.append("hero.army")
	for k in ("day", "objects"):
		if k not in st0: missing.append(k)
	check("schema_contract", not missing, "drift: missing %s" % missing if missing else "state paths intact")

	check("two_players", len(players) == 2, "players=%d" % len(players))
	check("starting_gold", all(gold(p) > 0 for p in players), [gold(p) for p in players])
	check("factions_assigned", all(p.get("faction") for p in players), [p.get("faction") for p in players])
	check("heroes_present", len(heroes_list(st0)) >= 2, "heroes=%d" % len(heroes_list(st0)))
	check("heroes_have_army", all(army(h) > 0 for h in heroes_list(st0)), [army(h) for h in heroes_list(st0)])
	check("no_war_machines", all(not any((u or {}).get("creature") in ("ballista", "catapult", "firstAidTent") for u in (h.get("army") or []) if u) for h in mh0), "starting army has no war machines")
	check("map_populated", len(st0.get("objects", {})) > 0, "objects=%d" % len(st0.get("objects", {})))

	# --- flagship: drive one canvas hero-move (human input path; protocol tests can't cover it).
	#     Defined here, RUN AFTER the turn loop — selecting a hero hides the End Turn button. ---
	def hero_move_check(st):
		mh = my_heroes(st, me_player(st))
		moved = None; mdetail = "skip (no canvas transform for %s)" % E["GAME"]
		if MOVE == "h3cam" and mh and not st.get("battle"):
			h = mh[0]; hx, hy = h["pos"]["x"], h["pos"]["y"]; hid = h["id"]; T = 48
			for ddx, ddy in [(0, 1), (1, 0), (-1, 0), (0, -1), (1, 1), (2, 0), (0, 2)]:
				cr = js("(function(){var c=document.querySelector('canvas');var b=c.getBoundingClientRect();return{left:b.left,top:b.top,cam:window.__h3cam||{x:0,y:0}};})()")
				cam = cr["cam"]
				def px(a, b): return (cr["left"] + a * T + T / 2 - cam["x"], cr["top"] + b * T + T / 2 - cam["y"])
				click_at_xy(*px(hx, hy)); wait(0.5)
				p = px(hx + ddx, hy + ddy); click_at_xy(*p); wait(0.9); click_at_xy(*p); wait(2.0)   # preview -> confirm
				got = states(drain_events())
				if got:
					nh = [x for x in my_heroes(got[-1], me_player(got[-1])) if x.get("id") == hid]
					if nh and (nh[0]["pos"]["x"], nh[0]["pos"]["y"]) != (hx, hy):
						moved = (nh[0]["pos"]["x"], nh[0]["pos"]["y"]); mdetail = "(%d,%d) -> %s" % (hx, hy, moved); break
			if not moved: mdetail = "hero did not move on double-click (transform / reachable / gesture)"
		hard = (MOVE == "h3cam" and not st.get("battle"))
		check("hero_moves_on_click", bool(moved) if hard else True, mdetail, soft=not hard)

	# --- play turns: day advances, income accrues, AI acts, combat engages ---
	series = [{"day": st0.get("day"), "gold": [gold(p) for p in players], "pos": positions(st0)}]
	day = st0.get("day", 1); cur = st0; saw_battle = False; income = False; ai_moved = False; turns_to_battle = None
	for t in range(TURNS):
		b = click_btn("end.?turn", 0.3, 4.0)
		if not b: print("(no End Turn — battle/game over)"); saw_battle = saw_battle or bool(series[-1].get("battle")); break
		nxt = poll(lambda s: s.get("day", 0) > day or s.get("winner") or s.get("battle"), 18)
		if not nxt: print("(no new state after End Turn)"); break
		st = nxt[-1]; cur = st; nd = st.get("day", day + 1); pg = [gold(p) for p in st.get("players", [])]
		if st.get("battle") and turns_to_battle is None: turns_to_battle = t + 1
		saw_battle = saw_battle or bool(st.get("battle"))
		if any(pg[i] > series[-1]["gold"][i] for i in range(min(len(pg), len(series[-1]["gold"])))): income = True
		if positions(st) != series[-1]["pos"]: ai_moved = True
		series.append({"day": nd, "gold": pg, "pos": positions(st), "battle": bool(st.get("battle"))})
		json.dump(st, open("%s/state-day%02d.json" % (OUT, nd), "w"), indent=2)
		print("  turn %d -> day %s  gold %s  battle=%s" % (t + 1, nd, pg, bool(st.get("battle"))))
		day = nd
		if st.get("winner"): break
	check("day_advances", series[-1]["day"] > series[0]["day"], "%s -> %s" % (series[0]["day"], series[-1]["day"]))
	check("income_accrues", income, "a player's gold rose across a turn")
	check("ai_acts", ai_moved, "a hero changed position (AI played)")
	check("battle_engaged", saw_battle, "combat triggered within %d turns" % TURNS, soft=True)

	hero_move_check(cur)   # human canvas-move AFTER turn progression (selecting a hero hides End Turn)

	# --- page-reload reconnect: client re-hydrates from the room, game persists ---
	rd = None
	try:
		url_now = page_info()["url"]; goto_url(url_now); wait_for_load(); cdp("Network.enable")
		rg = poll(lambda s: isinstance(s.get("players"), list) and len(s["players"]) >= 2, 14)
		rd = rg[-1].get("day") if rg else None
	except Exception as ex:
		rd = None
	check("reload_reconnect", rd is not None and rd >= series[-1]["day"], "day after reload=%s (was %s); soft — some games don't keep the room in the URL" % (rd, series[-1]["day"]), soft=True)

	json.dump(series, open(OUT + "/series.json", "w"), indent=2)
	capture_screenshot(OUT + "/map-end.png")
	metrics = {"final_day": series[-1]["day"], "final_gold": series[-1]["gold"],
	           "turns_to_battle": turns_to_battle, "saw_battle": saw_battle,
	           "income_delta": (series[-1]["gold"][0] - series[0]["gold"][0]) if series[-1]["gold"] and series[0]["gold"] else None}

# ===== machine-readable report + append-only history keyed by game commit =====
hard_ok = all(ok for (n, ok, soft, d) in results if not soft)
npass = sum(1 for (n, ok, soft, d) in results if ok)
report = {"game": E["GAME"], "url": URL, "turns": TURNS, "ts": E["TS"],
          "game_sha": E["GSHA"], "game_dirty": E["GDIRTY"] == "dirty",
          "result": "PASS" if hard_ok else "FAIL",
          "checks": [{"name": n, "ok": ok, "soft": soft, "detail": d} for (n, ok, soft, d) in results],
          "metrics": metrics}
json.dump(report, open(OUT + "/report.json", "w"), indent=2)
try:
	row = {"ts": E["TS"], "game": E["GAME"], "sha": E["GSHA"], "dirty": E["GDIRTY"] == "dirty",
	       "result": report["result"], "failed": [n for (n, ok, soft, d) in results if not ok and not soft], "metrics": metrics}
	open(E["HIST"], "a").write(json.dumps(row) + "\n")
except Exception: pass

print("\n=== %s E2E @ %s%s: %d/%d checks passed ===" % (E["GAME"], E["GSHA"], "*" if E["GDIRTY"] == "dirty" else "", npass, len(results)))
print("RESULT:", report["result"], "| report:", OUT + "/report.json | history:", E["HIST"])
raise SystemExit(0 if hard_ok else 1)
PY
