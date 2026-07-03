# Testing canvas + WebSocket games with browser-use

Pair this with the browser-use skill ([SKILL.md](../SKILL.md) · [CHEATSHEET.md](../CHEATSHEET.md) · [REFERENCE.md](../REFERENCE.md) · [RECIPES.md](../RECIPES.md)). It is the minimal, correct bridge from the generic tool to *testing a canvas+WebSocket game project*. Worked example: the HOMM3-web games `~/homm3` (`:5173`) and `~/heros3` (`:5174`) — React + Canvas + PartyKit.

## Mental model (why browser-use fits, and how)

The map is a `<canvas>` → **no game state in the DOM**. The authoritative state flows over **one WebSocket**. So:

- **Drive** via **DOM** (lobby / HUD / town buttons) **and canvas** (map).
- **Observe** via **WebSocket frames** (the truth) + **screenshots** (visual only).

## Three rules — do exactly this

1. **Inputs:** a single `js` native value-setter for text; a `<select>`: set `.value` + dispatch `change`; buttons: coordinate-click by text. **Never `fill_input`** (char-by-char can crash headless Chrome).
2. **Truth = the WebSocket.** `cdp("Network.enable")` **before** the socket opens, then filter `drain_events()` for `{type:"state"|"gameStarted"}` → the full game state. **Assert on this, never the DOM.**
3. **Map moves:** **double-click** the destination — the first click previews the path, the second confirms (both games) — onto a **reachable** tile only. Transform-inversion, re-read-after-move, and the reachable-tile rule are generic canvas mechanics → **RECIPES §8**; the per-game transform is in the table below. Verify the result from the WS state.

## Identify "me" robustly (seat vs color differ per game)

`hero.owner` is a **color string** in homm3 (`"red"`) but a **numeric seat** in heros3 (`0`). Don't key on that. Instead: pick the player with `isAI`/`isBot` false, then find your hero via that player's `heroes` id-list:
```python
me = next(p for p in st["players"] if not (p.get("isAI") or p.get("isBot")))
hs = list(st["heroes"].values()) if isinstance(st["heroes"], dict) else st["heroes"]
ids = me.get("heroes")                       # heros3: hero-id list on the player; homm3: absent
def mine(h): return (h["id"] in ids) if ids else h.get("owner") in (me.get("color"), me.get("id"))
my_hero = next(h for h in hs if mine(h))
```

## Connect

```bash
# dedicated Chrome on a NON-default profile (see SKILL → Connect; bypasses the Chrome 136+ default-profile port block)
chrome --user-data-dir=/tmp/bu --remote-debugging-port=9222 --headless=new about:blank &   # drop --headless=new to WATCH live
export BU_CDP_URL=http://127.0.0.1:9222
```

## Scenario matrix — cover all of these (drive → assert from WS state)

| Scenario | Drive | Assert (from state) |
|---|---|---|
| lobby + start vs AI | name → create → add-AI → faction → ready → start | `gameStarted`; 2 players |
| starting invariants | — | gold>0, faction set, ≥2 heroes with army, objects>0 |
| **hero movement** | double-click a reachable tile | hero pos changed |
| flag a mine | move the hero **onto** an unowned, unguarded mine's tile | that object's `owner` == my player |
| collect resource | move onto a resource pile | player resources rose |
| town build + recruit | open town (DOM) → build / recruit | town buildings grew; army grew |
| end turn + income | click End Turn; let the AI play | day advances; a player's gold rose |
| AI acts | — | AI hero moved or spent gold |
| battle triggers | move onto a weak monster (or let the AI attack) | `state.battle` present |
| battle resolves | drive battle hexes, or observe the AI's | battle clears; hero xp rises |
| win / lose | play to completion | `state.winner` set |
| reconnect | reload the tab | state re-received; same seat |

`game-e2e.sh` already covers the WS-assertable core (start, invariants, day/income, AI acts, battle-triggers). Add the rest by driving the action, then asserting the state — its helpers are the template.

## Per-game facts (this is the whole per-app config)

| | `homm3` (`:5173`) | `heros3` (`:5174`) |
|---|---|---|
| name input placeholder | `Hero` | `Lord of the realm` |
| add-AI button | `+ Add AI player` | `Summon AI Rival` |
| ready / start | `Ready` / `Start game` | `Ready for Battle` / `Start Game` |
| faction control | **`<select>`** (option `Castle`) | **`<button>`** text `Castle` |
| state frame types | `state` | `state`, `gameStarted` |
| hero position field | `x`, `y` | `pos:{x,y}` |
| AI flag on player | `isAI` | `isBot` |
| player identity | color `"red"`/`"blue"` (= `hero.owner`) | numeric seat `0`/`1` (= `hero.owner`); `color` hex is cosmetic |
| on-screen `TILE` px | 40 (+ zoom) | 48 |
| camera → pixel | derive `cam = hero*TILE − canvas/2`; read the pointer handler in `AdventureScreen.tsx` for the exact zoom | `window.__h3cam` (exposed for tests) |
| `state.battle` shape | `units` + `queue` + `turnIndex` | `stacks` + `activeStack` + `sides` |
| move gesture | double-click (preview → confirm) | double-click (preview → confirm) |

heros3 move transform: `screen_px = rect.left + tile*48 + 24 − __h3cam.x` (and `.y`). homm3: same shape with `TILE=40`; read its pointer handler for the zoom factor (no `window` camera hook — derive from the centering formula).

## Run

```bash
GAME=heros3 TURNS=6 ./ci-run.sh   # self-contained: launches its own headless Chrome + tears down; exit 0 = PASS
GAME=homm3  TURNS=6 ./ci-run.sh   # (or ./game-e2e.sh directly if a browser is already connected via BU_CDP_URL)
```

Each run writes **`OUT/report.json`** (per-check `detail` + metrics), appends **`OUT/e2e-history.jsonl`** keyed by the game's git SHA — so `jq 'select(.result=="FAIL")' e2e-history.jsonl` shows *which scenario broke on which commit* — and drops **`OUT/FAIL-<check>.png`** on any hard failure. 15 checks: 11 invariants + `schema_contract` (fails loudly if the WS state shape drifts), `no_war_machines`, `hero_moves_on_click` (the canvas human-input path; hard on heros3, soft-skipped on homm3 until its transform is wired), `reload_reconnect` (soft). Lobby drive auto-retries 3× (timing flake), and a drift names the exact failing step.

**Determinism (for replay/golden work):** *neither* game is reproducible today — both fold `Date.now()` into the seed, so every run is a fresh map. This gate is a seed-agnostic *invariant* check by design. To pin a seed, add the ~2-line server seam and run under `partykit dev --var SEED=...` (see the per-project `docs/TESTING-browser.md`).

## The minimal prompt to hand an agent (paste this together with the skill)

> Test `~/heros3` end-to-end with the browser-use CLI. Start its dev server, connect a headless Chrome (`BU_CDP_URL`), then drive the real client and **assert functionality from the WebSocket state** — the DOM has no game state. Follow `examples/testing-canvas-ws-games.md`: drive menus via DOM (js native-setter / `<select>` value, never `fill_input`; coordinate-click buttons), capture state via `cdp("Network.enable")` + `drain_events()` filtered to `state`/`gameStarted` frames, identify your hero with the schema-tolerant snippet (non-bot player; hero via its `heroes` list on heros3 or `owner`==color on homm3), and move heroes by **double-clicking reachable tiles** (per RECIPES §8). Cover the scenario matrix; run `GAME=heros3 examples/ci-run.sh` as the self-contained gate (exit 0 = PASS; it writes report.json + a commit-keyed e2e-history.jsonl and FAIL screenshots). Report PASS/FAIL per scenario with the state evidence.
