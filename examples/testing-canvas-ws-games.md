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
my_hero = next(h for h in st["heroes"].values() if h["id"] in me["heroes"])
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
GAME=heros3 OUT=./e2e  TURNS=6  ./game-e2e.sh   # functional gate: 11 checks, exit 0 = PASS
GAME=homm3  OUT=./data TURNS=10 ./game-e2e.sh   # same tool, longer run for data — writes state-day*.json + series.json + screenshots
```

## The minimal prompt to hand an agent (paste this together with the skill)

> Test `~/heros3` end-to-end with the browser-use CLI. Start its dev server, connect a headless Chrome (`BU_CDP_URL`), then drive the real client and **assert functionality from the WebSocket state** — the DOM has no game state. Follow `examples/testing-canvas-ws-games.md`: drive menus via DOM (js native-setter / `<select>` value, never `fill_input`; coordinate-click buttons), capture state via `cdp("Network.enable")` + `drain_events()` filtered to `state`/`gameStarted` frames, identify your hero via the non-bot player's `heroes` list, and move heroes by **double-clicking reachable tiles** (per RECIPES §8). Cover the scenario matrix; run `GAME=heros3 examples/game-e2e.sh` as the gate. Report PASS/FAIL per scenario with the state evidence, and save a state time-series + screenshots.
