# Browser Use CLI 3.0 (Browser Harness) — Agent Reference

> **Provenance & verification.** Distilled from the installed package source + official docs by a 10-agent workflow (0 errors), then **adversarially verified against the installed package**:
> - **Helpers: 37/37 confirmed** in `helpers.py`/`admin.py` — **0 hallucinated**.
> - **Env vars: 3 doc-only entries corrected inline** (`⚠︎`): `BROWSER_USE_DISABLE_SECURITY`, `BROWSER_USE_X402_PRIVATE_KEY`, `CODEX_HOME` are **not read** by these packages; `BH_CLIENT` is **write-only** (set for downstream attribution, never read here).
> - **`-c/--code` confirmed to NOT execute code** (telemetry-only — use the heredoc).
> - **Hands-on validated (2026-07-03)** vs a live headless Chrome via `BU_CDP_URL=http://127.0.0.1:9222`: `new_tab`·`page_info`·`js`(structured extraction)·`capture_screenshot(full=True)`·`scroll`(sy 0→401)·`wait_for_network_idle`·`list_tabs`/`switch_tab`/`current_tab`·`http_get`·`click_at_xy`(→ real navigation)·`cdp("Browser.getVersion")`·`cdp("Page.printToPDF")` → valid 35 KB PDF. The `🐴`-title marker (harness tagging its own tabs) was observed on every page.

> `browser-use` is a thin renaming front-end (`browser_use/cli.py`) over the vendored `browser_harness` package. It attaches an LLM directly to a real Chrome over one CDP WebSocket and executes Python you feed it. This reference is grounded in the actual installed source at `~/.local/share/uv/tools/browser-use/lib/python3.12/site-packages/browser_harness/` and `browser_use/`. Where the published docs disagree with source, **source wins** and the conflict is flagged `⚠︎`.

---

## 1. Mental model & CLI 3.0 philosophy

- **Un-abstracted exec namespace.** You send Python (via heredoc/stdin). `run.py:180` runs `exec(code, globals())` against `run.py`'s **own module globals**. Those globals are populated by 4 imports: `import os, sys, urllib.request` (`run.py:1`); `from .admin import (...)` (14 names); `from . import auth, telemetry`; and `from .helpers import *`. `helpers.py` has **no `__all__`**, so `import *` injects every non-underscore name (helper functions, re-exported stdlib modules, module constants). Underscore helpers (`_send`, `_runtime_evaluate`, `_KEYS`, `_KC`, …) are **not** in your namespace — you reach them only transitively through public helpers.
- **`ensure_daemon()` runs before your code.** `run.main()` calls `ensure_daemon()` (`run.py:179`) prior to `exec`, so a daemon is guaranteed alive and attached to a real page when your first line runs. You almost never call `ensure_daemon()` yourself.
- **One long-lived daemon per `BU_NAME`.** The daemon holds the single CDP WebSocket to the browser and relays CDP over a local IPC socket. Clients never speak CDP directly. Default name is `"default"`; each distinct `BU_NAME` gets its own endpoint files and coexists (e.g. a local `default` and a cloud `remote`).
- **Design bias:** coordinate clicks are the *default* interaction primitive because "CDP mouse events pass through iframes/shadow/cross-origin at the compositor level." DOM traversal (`js`, `iframe_target`) is the fallback for *reading/extraction*, not clicking. Core helpers stay short; task-specific helpers are written at runtime into `$BH_AGENT_WORKSPACE/agent_helpers.py`, whose public names are auto-injected into the namespace at import time (`_load_agent_helpers`, `helpers.py:493-508`).
- **Runtime-injected, not importable.** `page_info()`, `click_at_xy()`, `js()`, `cdp()` etc. are **not** `from browser_use import ...` symbols. They exist only inside the harness heredoc namespace.

---

## 2. Invocation

**Canonical form — heredoc over stdin (the real execution path):**
```bash
browser-use <<'PY'
ensure_real_tab()
print(page_info())
PY
```
- Quote the heredoc marker (`<<'PY'`) so the shell doesn't expand `$`/backticks in your Python.
- With no args and stdin not a TTY, the *entire stdin* is read as the code and `exec`'d (`cli.py:233-237`, `run.py:158-160`).
- Empty/whitespace stdin → prints `USAGE`, exits. Args present but not a known subcommand, or stdin is a TTY → prints `USAGE`, exits (`run.py:160-163`).

**`uvx` vs installed:**
```bash
uvx browser-use <<'PY'          # ephemeral, no install
uv tool install --python 3.12 --upgrade --force browser-use   # persistent
browser-use <<'PY'              # after install; also aliases: bu, browser, browseruse
python -m browser_use.cli <<'PY'
```
PowerShell here-string equivalent:
```powershell
@'
new_tab("https://example.com")
print(page_info())
'@ | uvx browser-use
```

**⚠︎ `-c/--code` does NOT execute your task.** `cli.py:228-232` only reads the value after `-c/--code` to populate the *telemetry* `task` field. When forwarded, `run.main()` doesn't parse `-c`; it sees "args present, not a subcommand" and hits `sys.exit(USAGE)` (`run.py:162-163`). **Real task execution is stdin/heredoc-driven.** Do not rely on `browser-use -c "code"` to run code.

**⚠︎ First navigation is `new_tab(url)`, not `goto_url(url)`.** On fresh Chrome the only CDP page targets may be `chrome://inspect` and the 1px `chrome://omnibox-popup.top-chrome/`. `new_tab(url)` creates/reuses a real tab and attaches. `goto_url(url)` just runs `Page.navigate` on whatever is currently attached (and is the entrypoint that returns domain-skill filenames when `BH_DOMAIN_SKILLS=1`). Use `new_tab` to start; use `goto_url` to navigate an already-attached real tab.

---

## 3. Complete helper API (only helpers attested in source)

Every callable below is injected into the heredoc namespace. Signatures verbatim from `helpers.py` / `admin.py`.

### 3.1 Raw CDP
| Signature | One-line usage |
|---|---|
| `cdp(method, session_id=None, **params)` → `dict` | `cdp("Page.navigate", url="https://x.com")` — the primitive every helper is built on; raises `RuntimeError` on CDP error. |
| `drain_events()` → `list[dict]` | `for e in drain_events(): print(e["method"])` — returns AND empties the daemon's buffered CDP events. |

### 3.2 Navigation / page state
| Signature | One-line usage |
|---|---|
| `goto_url(url)` → `dict` | `goto_url("https://example.com")` — `Page.navigate` on attached tab; augments result with `domain_skills` list when `BH_DOMAIN_SKILLS=1`. |
| `page_info()` → `dict` | `print(page_info())` — `{url,title,w,h,sx,sy,pw,ph}`; **if a native dialog is open returns `{"dialog":{type,message,...}}`** instead (JS thread frozen). Primary "read the page" call. |

### 3.3 Mouse / keyboard
| Signature | One-line usage |
|---|---|
| `click_at_xy(x, y, button="left", clicks=1)` → `None` | `click_at_xy(320, 210)` — real mouse press+release at CSS coords; `BH_DEBUG_CLICKS=1` also writes a crosshair PNG. |
| `type_text(text)` → `None` | `type_text("hello")` — `Input.insertText`; **bypasses framework listeners** (React/Vue submit buttons may stay disabled → use `fill_input`). |
| `fill_input(selector, text, clear_first=True, timeout=0.0)` → `None` | `fill_input("#email", "a@b.com")` — focuses, clears, types via real key events, fires synthetic `input`+`change`; use for React/Vue/Ember. Raises `RuntimeError` if not found; `timeout>0` waits for late-rendered elements. **⚠︎ Types char-by-char (N `Input` events) — this can wedge or even *crash* headless Chrome (observed). Prefer a single `js` native value-setter for React inputs: `Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,val); el.dispatchEvent(new Event('input',{bubbles:true}))`.** |
| `press_key(key, modifiers=0)` → `None` | `press_key("Enter")` — modifiers bitfield `1=Alt 2=Ctrl 4=Meta 8=Shift`; special keys carry virtual keycodes so `e.keyCode`/`e.key` listeners fire. |
| `scroll(x, y, dy=-300, dx=0)` → `None` | `scroll(640, 400, dy=600)` — wheel event at `(x,y)`; **default `dy=-300` scrolls up**, positive `dy` scrolls down. |
| `dispatch_key(selector, key="Enter", event="keypress")` → `None` | `dispatch_key("#search", "Enter")` — synthetic DOM `KeyboardEvent` on the matched element; use when a site reacts to DOM key events more reliably than raw CDP input. |

### 3.4 Screenshots
| Signature | One-line usage |
|---|---|
| `capture_screenshot(path=None, full=False, max_dim=None)` → `str` | `capture_screenshot("/tmp/shot.png", max_dim=1800)` — writes PNG (default `ipc._TMP/shot.png`); `full=True` = beyond-viewport; `max_dim` downscales only if exceeded. **Output is device pixels.** |

### 3.5 JS / DOM / files
| Signature | One-line usage |
|---|---|
| `js(expression, target_id=None)` → Python value | `title = js("document.title")` — evaluates as-is; on "Illegal return" retries wrapped in a function so `return` works; `target_id` runs it inside an iframe target. Raises `RuntimeError` on JS exception. |
| `upload_file(selector, path)` → `None` | `upload_file("input[type=file]", "/tmp/a.pdf")` — `DOM.setFileInputFiles`; `path` absolute; accepts a str or an iterable of paths. Raises `RuntimeError` if no match. |

### 3.6 Tabs
| Signature | One-line usage |
|---|---|
| `list_tabs(include_chrome=True)` → `list[dict]` | `list_tabs(include_chrome=False)` — `[{targetId,target_id,title,url}]`; skips startup placeholders; drops `chrome://`/internal when `include_chrome=False`. |
| `current_tab()` → `dict` | `print(current_tab())` — `{targetId,target_id,url,title}` for the attached tab. |
| `switch_tab(target)` → `str` (sessionId) | `switch_tab(tid)` — accepts a targetId or a tab dict; activates + attaches + updates daemon session + re-marks tab title (🐴). |
| `new_tab(url="about:blank")` → `str` (targetId) | `tid = new_tab("https://example.com")` — reuses a blank current tab or creates one, switches, navigates. |
| `close_tab(target=None)` → `None` | `close_tab()` — closes attached tab (or the given targetId/dict). |
| `ensure_real_tab()` → `dict \| None` | `ensure_real_tab()` — switch to a real user tab if current is `chrome://`/internal/stale; `None` if no real tab exists. |
| `iframe_target(url_substr)` → `str \| None` | `t = iframe_target("stripe.com")` — first iframe target whose URL contains substr; feed to `js(..., target_id=t)`. |

### 3.7 HTTP (no browser)
| Signature | One-line usage |
|---|---|
| `http_get(url, headers=None, timeout=20.0)` → `str` | `html = http_get("https://api.example.com")` — pure HTTP; routes through the fetch-use proxy when `BROWSER_USE_API_KEY` is set, else local `urllib` with a `Mozilla/5.0` UA + gzip. Wrap in `ThreadPoolExecutor` for bulk. |

### 3.8 Waiting / synchronization
| Signature | One-line usage |
|---|---|
| `wait(seconds=1.0)` → `None` | `wait(2)` — `time.sleep`. |
| `wait_for_load(timeout=15.0)` → `bool` | `wait_for_load()` — polls `document.readyState=='complete'`. **Misses SPAs** (complete before framework renders). |
| `wait_for_element(selector, timeout=10.0, visible=False)` → `bool` | `wait_for_element("#app", visible=True)` — polls `querySelector`; `visible=True` also requires in-layout/non-hidden. Use after route changes/data fetches. |
| `wait_for_network_idle(timeout=10.0, idle_ms=500)` → `bool` | `wait_for_network_idle()` — waits until no in-flight requests and no `Network.*` event for `idle_ms`; filtered to the active session. Best signal after form submits / SPA transitions. |

### 3.9 Daemon & lifecycle (from `.admin`, injected)
| Signature | Note |
|---|---|
| `daemon_alive(name=None)` → `bool` | Ping handshake (not a bare connect) — survives stale socket files. |
| `ensure_daemon(wait=60.0, name=None, env=None)` | Idempotent bring-up + self-heal; probes a real `Target.getTargets` and restarts a stale daemon whose CDP WS died. Called for you before `exec`. |
| `restart_daemon(name=None)` | **⚠︎ Misnamed — it only STOPS.** No restart; a later `browser-use` call auto-spawns fresh. |
| `start_remote_daemon(name="remote", profileName=None, **create_kwargs)` → provisions cloud browser | kwargs (camelCase): `profileId`, `proxyCountryCode`, `timeout` (1..240 min), `customProxy`, `browserScreenWidth/Height`, `allowResizing`, `enableRecording`. |
| `stop_remote_daemon(name="remote")` | Stops the daemon → PATCHes cloud browser `{"action":"stop"}` → ends billing + persists profile. |
| `run_doctor()` / `run_doctor_fix_snap()` | Diagnose install/daemon/browser / print Snap-Chromium CDP fix. |
| `run_update(yes=False)` | Self-update; recycles daemon onto new code. |
| `print_update_banner()` | Prints available-update notice. |
| `list_cloud_profiles()` → `[{id,name,userId,cookieDomains,lastUsedAt}]` | Cloud profiles under the API key. |
| `list_local_profiles()` → `[{BrowserName,ProfileName,DisplayName,ProfilePath,...}]` | Local Chrome profiles detected on this machine. |
| `sync_local_profile(profile_name, browser=None, cloud_profile_id=None, include_domains=None, exclude_domains=None)` → cloud UUID | Uploads local cookies to a cloud profile (shells out to `profile-use`); pass `cloud_profile_id=` to refresh idempotently. |

### 3.10 Pre-imported modules, objects & constants (also in namespace)
- Modules: `os`, `sys`, `urllib` (`.request`), `base64`, `json`, `math`, `time`, `importlib`, `Path` (pathlib), `urlparse`, `ipc`, `paths`, `auth`, `telemetry`.
- `ipc` surface used in recipes: `ipc.cleanup_endpoint(name)`, `ipc.pid_path(name)`, `ipc.connect`, `ipc.sock_addr`, `ipc._TMP` (screenshot dir).
- Constants: `CORE_DIR`, `REPO_ROOT`, `AGENT_WORKSPACE` (= `$BH_AGENT_WORKSPACE`), `NAME` (= `BU_NAME`), `SOCK`, `INTERNAL` (= `("chrome://","chrome-untrusted://","devtools://","chrome-extension://","about:")`), `HELP`, `USAGE`.
- **No dedicated download helper exists** in the canonical surface — use `http_get` for direct fetches or raw `cdp(...)` for browser-triggered downloads.

---

## 4. Connection & browser modes

Selection happens in `daemon.py:get_ws_url()`, precedence top-down. Mode is "local" iff **neither** `BU_CDP_WS` nor `BU_CDP_URL` is set (checked in both the passed env and `os.environ`).

- **Mode A — `BU_CDP_WS` (raw WebSocket).** Highest precedence. Returned verbatim, no discovery. This is what cloud/remote attach uses. **Wins over `BU_CDP_URL` when both set.**
- **Mode B — `BU_CDP_URL` (HTTP DevTools endpoint, e.g. `http://127.0.0.1:9333`).** Polled up to 30s via `GET {url}/json/version` → `webSocketDebuggerUrl`. `403` → permission-blocked; `404` → falls back to a port-matched `DevToolsActivePort` scan (Chrome 147+ default-profile lockdown). For a dedicated automation Chrome on a non-default profile.
- **Mode C — Default local attach.** Scans a 28-entry `PROFILES` list (macOS `Library/Application Support`, Linux `.config` + `.var/app` Flatpak, Windows `AppData/Local`; Chrome/Chromium/Edge/Brave/Comet/Arc/Dia) for a `DevToolsActivePort` file (line 1 = port, line 2 = ws path), resolves live WS via `http://127.0.0.1:{port}/json/version` (404 → uses the file's ws path), then probes fixed ports **9222/9223**. This is the path `ensure_daemon` self-heals via the chrome://inspect "Allow" flow.
- **Mode D — Named remote (`BU_NAME` + `start_remote_daemon`).** Orchestration over Mode A: `POST /browsers` provisions a cloud browser, then `ensure_daemon(name=..., env={BU_CDP_WS, BU_BROWSER_ID})` spawns a daemon under a distinct `BU_NAME`. `BU_BROWSER_ID` wires billing teardown on shutdown.

**Cloud auto-bootstrap side effect:** on a normal run, a cloud browser is auto-spawned only if ALL hold — daemon not alive, no local Chrome on 9222/9223, no explicit `BU_CDP_URL/WS`, cloud auth configured, and `BU_AUTOSPAWN` is set. Code starting with `start_remote_daemon(`/`stop_remote_daemon(` skips this.

### Environment variable table (exhaustive across `admin.py`/`daemon.py`/`_ipc.py`/`paths.py`/`cli.py`/`auth.py`/`telemetry.py`)
| Var | Default | Effect |
|---|---|---|
| `BU_NAME` | `default` | Daemon identity → IPC endpoint file stems (`bu-<NAME>.sock/.pid/.port/.log`). Validated `[A-Za-z0-9_-]{1,64}`. |
| `BU_CDP_WS` | unset | Direct CDP WebSocket; no discovery. Set by `start_remote_daemon`. |
| `BU_CDP_URL` | unset | HTTP DevTools endpoint; resolved to WS. |
| `BU_BROWSER_ID` | unset | Cloud browser UUID; daemon PATCHes `/browsers/{id} stop` on shutdown to end billing. |
| `BU_AUTOSPAWN` | unset | Gate for the cloud auto-bootstrap on a normal run. |
| `BH_RUNTIME_DIR` | `BH_TMP_DIR`→`home/runtime` | Dir for `.sock/.port/.pid` (AF_UNIX path must be short on macOS). Isolates a single daemon; skips glob discovery unless shared. |
| `BH_TMP_DIR` | `home/tmp` | Screenshots, debug overlays, daemon `.log`. |
| `BH_RUNTIME_DIR_SHARED` | `0` | `=1` forces `bu-<NAME>` stems + glob discovery even with `BH_RUNTIME_DIR` set. |
| `BH_TMP_DIR_SHARED` | `0` | `=1` forces `bu-<NAME>` log stem. |
| `BH_HOME` / `BROWSER_HARNESS_HOME` | unset | Highest-priority harness home override. |
| `XDG_CONFIG_HOME` | unset | If set (no `BH_HOME`): home = `$XDG_CONFIG_HOME/browser-harness`; else `~/.config/browser-harness`. |
| `BH_CONFIG_DIR` | `home_dir()` | Config dir (holds `version-cache.json`, `auth.json`, `telemetry.json`). |
| `BH_AGENT_WORKSPACE` | `home/agent-workspace` | Workspace; holds `agent_helpers.py`, `domain-skills/`; scanned for `.env`. |
| `BH_DOMAIN_SKILLS` | `0` | `=1` makes `goto_url` return up to 10 skill filenames for the host. |
| `BH_DEBUG_CLICKS` | unset | `=1` writes a crosshair PNG per `click_at_xy`. (`--debug-clicks` sets it.) |
| `BH_CLIENT` | unset | Set to `browser-use-cli` by the front-end for attribution. |
| `BH_CHROME_PATH` / `CHROME_PATH` | unset | Explicit Chrome binary for the doctor Snap probe. |
| `BH_AUTH_PATH` | (config dir)`/auth.json` | Override the auth file path. |
| `DISPLAY` / `WAYLAND_DISPLAY` | unset | Linux GUI presence → live URLs auto-open. |
| `BROWSER_USE_API_KEY` | unset | Highest-priority cloud key (never persisted); routes `http_get` through fetch-use proxy. |
| `BROWSER_USE_CLOUD_API_URL` | `https://api.browser-use.com` | OAuth/cloud API base. |
| `BROWSER_HARNESS_OAUTH_CLIENT_ID` | `browser-use-terminal` | OAuth client id. |
| `BH_TELEMETRY` / `BROWSER_HARNESS_TELEMETRY` | on | `0/false/no/off` disables harness telemetry. |
| `BH_POSTHOG_HOST` / `BH_TELEMETRY_TIMEOUT` | PostHog EU / — | Telemetry host / timeout override. |
| `BROWSER_USE_AGENT_CLIENT` / `_AGENT_MODEL` / `_MODEL_PROVIDER` | unset | Recorded in the CLI's own telemetry event. |
| `BROWSER_USE_LOGGING_LEVEL` / `BROWSER_USE_SETUP_LOGGING` | — | Forced to `critical`/`false` in `--mcp` mode. |
| `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | unset | Required by `--mcp` server agent tools. |
| `BROWSER_USE_HEADLESS` | — | MCP-server headless toggle (pydantic BaseSettings, `config.py`). |
| `BROWSER_USE_DISABLE_SECURITY` | — | ⚠︎ **Not an env var** (verified absent). Security is the `disable_security` `BrowserProfile` field set via config/kwargs. |
| `BROWSER_USE_X402_PRIVATE_KEY` | unset | ⚠︎ **Not read** in `browser_harness`/`browser_use` (no x402 reference at all). Cloud SDK (`browser-use-sdk`) only — unverified here. |
| `CODEX_HOME` | `~/.codex` | ⚠︎ Shell **install recipe** only (`${CODEX_HOME:-$HOME/.codex}`); **not read** by the Python packages. |

**State layout (no overrides):** `~/.config/browser-harness/` → `runtime/bu-default.sock` (POSIX AF_UNIX 0600) / `bu-default.pid` (+ `bu-default.port` JSON `{port,token}` on Windows TCP-loopback), `tmp/bu-default.log`, `auth.json` (0600), `telemetry.json` (0600), `version-cache.json`. All dirs created 0700. IPC is newline-delimited JSON, one request/response per connection; `meta:*` (ping, drain_events, session, current_tab, set_session, pending_dialog, connection_status, shutdown) handled in-daemon, everything else is a CDP passthrough.

---

## 5. CLI subcommand / flag reference

`main()` → `_dispatch(args)`, first match wins: `--mcp` → MCP; `install`; `init`; `--template/-t`; `skill`; else forward to harness (reading task from stdin).

**Console aliases** (all → `browser_use.cli:main`): `browser-use`, `bu`, `browser`, `browseruse`. (`browser-use-tui` is a deprecated shim.)

**Default run (harness passthrough) flags** (`run.py:118-157`):
- `-h` / `--help` — print HELP.
- `--version` — installed version or `unknown`.
- `--doctor` — `run_doctor()`.
- `--update [-y|--yes]` — self-update; agents pass `-y` for non-interactive.
- `--reload` — `restart_daemon()` (stops daemon; "will restart fresh on next call").
- `--debug-clicks` — sets `BH_DEBUG_CLICKS=1`, strips flag, continues.
- `-c` / `--code` — **telemetry-only**, does not execute (see §2).

**`install`** — runs `uvx playwright install chromium` (`--with-deps` on Linux, always `--no-shell`). `-h/--help` prints usage.

**`init`** (starter-script generator) — `--template/-t <name>` (interactive select if bare), `--output/-o <path>` (default `browser_use_<template>.py`), `--force/-f`, `--list/-l`. Templates: `default`, `advanced`, `tools`, plus featured `INIT_TEMPLATES`. Bare `--template`/`-t` anywhere also routes here.

**`skill`** (default subcommand `show`):
- `skill show` — print the Browser Use skill text (sourced from `browser-harness skill` if present, else packaged).
- `skill install` — `--target {agents,claude,codex,copilot,cursor,gemini,opencode,all}` (default `all`), `--path <dir|SKILL.md>`, `--force` (compat no-op — overwrites by default), `--no-install` (skip the `uv tool install --python 3.12 --upgrade --force browser-use` step). Writes `SKILL.md` to `~/.<assistant>/skills/browser-use/` (opencode → `$XDG_CONFIG_HOME/opencode/skills/...`).

**`doctor`** — `doctor` = `run_doctor()`; `doctor --fix-snap` = `run_doctor_fix_snap()`; `doctor --help` prints usage; any other arg → usage on stderr, exit 2.

**`auth`** (Browser Use Cloud):
- `auth login` — browser/PKCE OAuth (local `127.0.0.1:0` callback, up to 600s). Modes: `--device-code` (SSH/headless), `--api-key-stdin` (reads key from stdin, ≥20 chars, `source="manual"`). Flags `--json`, `--no-open`.
- `auth status` — JSON: `env` if `BROWSER_USE_API_KEY` set, else stored/missing + auth-file path.
- `auth logout` — clears the stored `browser_use` record.
- Key storage: env `BROWSER_USE_API_KEY` (never persisted) > `auth.json` (0600, atomic write) in the config dir, under `"browser_use": {api_key, api_key_id, project_id, expires_at, scopes, source}`. `⚠︎` a raised `CloudAuthRequired` message literally says "run `browser-harness auth login`" (it bypasses the rename wrapper).

**`telemetry`** — `telemetry`/`telemetry status` (JSON: enabled, disabled_by_env/config, install_id, config_path), `telemetry enable`, `telemetry disable`. Anonymous PostHog; `FORBIDDEN_KEYS` blocklist + `://` redaction strip anything sensitive. (This is *harness* telemetry; the CLI also emits its own redacted `CLITelemetryEvent`.)

**`--mcp`** (highest precedence) — MCP server mode. Forces logging off, `asyncio.run(browser_use.mcp.server.main())`. Register: `claude mcp add browser-use -- uvx --from 'browser-use[cli]' browser-use --mcp`.

---

## 6. Page workflow best-practices

1. **Screenshot-first click loop:** `capture_screenshot()` → read the target pixel off the image → **divide by `devicePixelRatio`** (`js("window.devicePixelRatio")`) because PNGs are device pixels but `click_at_xy` takes CSS pixels → `click_at_xy(x, y)` → screenshot again to confirm. On a 2× display keep `max_dim=1800` to stay under the 2000px-per-side limit some LLMs enforce.
2. **After any navigation** call `wait_for_load()`; for SPAs that report `complete` before rendering, prefer `wait_for_element(selector, visible=True)` or `wait_for_network_idle()` after actions that trigger async work.
3. **If the current tab is stale/internal**, call `ensure_real_tab()` before working; `switch_tab(tid)` both attaches AND activates (brings to front).
4. **Use `js(...)` for DOM inspection/extraction** when coordinates are the wrong tool; **use raw `cdp("Domain.method", ...)`** for anything without a helper.
5. **Framework inputs:** prefer `fill_input()` over `type_text()` for React/Vue/Ember (the latter bypasses listeners and can leave submit buttons disabled).
6. **Login walls:** stop and ask. Exception: use SSO automatically when Chrome is already signed in; still stop for passwords, MFA, consent, or ambiguous account choice.

---

## 7. Per-mechanic interaction recipes

> `⚠︎ Corpus note:` Only `SKILL.md`, `install.md`, `connection.md`, `dialogs.md`, `screenshots.md`, `tabs.md`, `profile-sync.md` are fleshed-out. The other interaction-skill files (cookies, iframes, cross-origin-iframes, shadow-dom, downloads, drag-and-drop, dropdowns, network-requests, print-as-pdf, scrolling, uploads, viewport) are **published stubs** (title + one-line scope). Recipes below for stub topics are derived from the helper surface + the coordinate-click design principle, with the stub's scope caveat.

- **Dialogs** (`alert`/`confirm`/`prompt`/`beforeunload` freeze the JS thread).
  - Detect: `page_info()` returns `{"dialog":{type,message,...}}` when one is pending.
  - Reactive (preferred, undetectable, handles `beforeunload`): `cdp("Page.handleJavaScriptDialog", accept=True)` (OK) / `accept=False` (Cancel); read text from `drain_events()` where `method=="Page.javascriptDialogOpening"`.
  - Proactive (multiple sequential dialogs): stub via `js("window.alert=…; window.confirm=…; window.prompt=…")` — but lost on navigation, `confirm` always returns `true`, detectable, does **not** cover `beforeunload`.
  - `beforeunload`: dismiss after navigating (`goto_url(...)` then `cdp("Page.handleJavaScriptDialog", accept=True)` in a try/except), or pre-empt with `js("window.onbeforeunload=null")` before navigating.
- **Cookies** (stub — scope: don't conflate browser state with page state): read/set via `cdp("Network.getCookies")` / `cdp("Network.setCookie", ...)` / `cdp("Storage.getCookies")`; for cloud "start already logged in" use profile-sync (below).
- **Iframes** (stub): same-origin traversal via `contentDocument`/`contentWindow` in `js(...)`; **coordinate clicks are lower-friction** because CDP mouse events pass through iframes at the compositor level. Keep the frame-local-vs-page-coordinate distinction explicit for clicks.
- **Cross-origin iframes** (stub): `t = iframe_target("substr")` then `js(expr, target_id=t)` to read; prefer `click_at_xy` for clicks over cross-target DOM work.
- **Shadow DOM** (stub): recursive `shadowRoot` traversal in `js(...)`; coordinate clicking is simpler than piercing deeply nested trees.
- **Downloads** (stub; **no dedicated helper**): separate direct fetches (`http_get(url)`) from browser-triggered downloads (`cdp("Page.setDownloadBehavior", ...)` / `Browser.setDownloadBehavior` + watch `drain_events()` for `Page.downloadWillBegin`).
- **Uploads:** `upload_file(selector, path)` (CDP `DOM.setFileInputFiles`; absolute path). The `uploads.md` skill is an empty placeholder.
- **Drag-and-drop** (stub): low-level `Input.dispatchMouseEvent` sequences via `cdp(...)` for simple drags; some sites really expect a file upload or a DOM-specific drag sequence.
- **Dropdowns** (stub): distinguish native `<select>` (set value via `js`/CDP) from custom overlays/comboboxes/virtualized menus — **re-measure geometry after opening**, options often render late.
- **Network requests** (stub): watch/infer via `drain_events()` + `wait_for_network_idle()`; SPA submits can succeed with **no DOM change**, so DOM-based verification is unreliable. **WebSocket frames:** `cdp("Network.enable")` *before* the socket opens, then filter `drain_events()` for `Network.webSocketFrameReceived` / `webSocketFrameSent` — the way to capture a realtime/canvas app's authoritative state (games, dashboards, chat). See RECIPES.md §7.
- **Print-as-PDF** (stub): `cdp("Page.printToPDF", ...)` for direct generation; sites that only expose a visible Print button must be clicked first, then handle the browser print flow.
- **Screenshots:** `capture_screenshot(path, full=False, max_dim=1800)`. Device pixels — divide targets by `devicePixelRatio` before `click_at_xy`. `full=True` only for below-the-fold (larger/slower).
- **Scrolling** (stub): `scroll(x, y, dy=…)` — identify which element actually consumes wheel events (page vs nested container vs virtualized list vs dropdown) before scrolling; default `dy=-300` is up.
- **Tabs:** "CDP for control, UI automation for user-visible order." `list_tabs(include_chrome=False)`, `tid=new_tab(url)`, `switch_tab(tid)` (attach), `cdp("Target.activateTarget", targetId=tid)` (show in Chrome). `switch_tab` alone doesn't change what the user sees — use `activateTarget`. macOS visible order via AppleScript (`osascript ... "set active tab index of front window to N"`); Linux via `xdotool`/`wmctrl`. `w=0 h=0` ⇒ attached to a non-window surface.
- **Viewport** (stub): size changes affect layout and coordinate clicks; re-read element rects (after opening modals/dropdowns) before coordinate-clicking anything geometry-dependent.
- **Profile-sync** (make a cloud browser start logged-in). One-time: `curl -fsSL https://browser-use.com/profile.sh | sh` (installs `profile-use`; helpers shell out to it). Flow: `list_cloud_profiles()` → optionally `sync_local_profile("MyProfile", include_domains=["stripe.com"])` (returns cloud UUID; pass `cloud_profile_id=uuid` to refresh idempotently) → `start_remote_daemon("work", profileId=uuid)` (or `profileName=`). Syncs **cookies only** (no localStorage/IndexedDB/extensions). Cookie mutations persist only on clean `stop_remote_daemon` (PATCH stop); timed-out sessions lose in-session state. `proxyCountryCode="us"` default can block some destinations — pass `None` to disable or another code. Profile names aren't unique — verify `len(matches)==1` before trusting a name→UUID lookup.

### Startup / stale-socket recovery (from `connection.md`)
```python
if not daemon_alive():
    import os, ipc
    ipc.cleanup_endpoint("default")
    pid = ipc.pid_path("default")
    if pid.exists(): pid.unlink()
    ensure_daemon()
tab = ensure_real_tab()
```

---

## 8. Remote / cloud & parallel agents

```bash
browser-use auth login
# non-interactive key import:
printf '%s' "$BROWSER_USE_API_KEY" | browser-use auth login --api-key-stdin
```
```bash
browser-use <<'PY'
start_remote_daemon("work")
PY

BU_NAME=work browser-use <<'PY'
new_tab("https://example.com")
print(page_info())
PY

BU_NAME=work browser-use <<'PY'
stop_remote_daemon("work")
PY
```

- **Unique `BU_NAME` per agent/sub-agent.** Each name maps to its own remote browser daemon and its own endpoint files. Use short made-up names (`work`, `r7k2`) for parallel sub-agents.
- **Don't mix.** Never `start_remote_daemon(...)` then keep hitting the default daemon; set `BU_NAME` to the same name for every follow-up call in that lane.
- **Billing runs until stop or timeout.** Ask before leaving a cloud browser running; stop with `stop_remote_daemon(name)` or `PATCH /browsers/{id} {"action":"stop"}`. Session cap: free ≤15 min, paid ≤240 min (`timeout` create-kwarg, in minutes). Free tier: 3 concurrent browsers.
- **Library-side parallelism** (distinct from CLI) is one `Browser(user_data_dir=...)` per agent gathered with asyncio — docs mark it experimental.

---

## 9. Gotchas

- **chrome://inspect consent (local).** If the daemon can't connect, Chrome requires the user to open `chrome://inspect/#remote-debugging`, tick "Allow remote debugging for this browser instance," and click Allow. Chrome 144+ also throws a **per-attach "Allow" popup** — a `403` from `/json/version` surfaces as `RuntimeError("permission-blocked: ...")`.
- **Chrome 136+/147+ default-profile lockdown.** Newer Chrome disables `/json/*` HTTP discovery on the default profile (`404`). Discovery falls back to the `DevToolsActivePort` file's ws path. A dedicated non-default automation profile via `BU_CDP_URL` avoids the M144 dialog / default-profile lockdown.
- **`DevToolsActivePort` discovery quirks.** File line 1 = port, line 2 = ws path. The daemon prefers resolving live WS via `/json/version` (not the file path), because a stale file from a prior `--user-data-dir` on the same port carries a dead browser UUID.
- **Omnibox popup is not a real tab.** `chrome://omnibox-popup.top-chrome/` (1px) can appear as a fake page target; ignore it. `attach_first_page()` creates an `about:blank` when no real page exists — if you still land on an invisible tab, `switch_tab(tid)`.
- **CDP target order ≠ Chrome tab-strip order.** `list_tabs()` order does not match the user-visible left-to-right strip; use `activateTarget` + OS UI automation for user-facing ordering. `list_tabs()` includes `chrome://newtab/` unless `include_chrome=False`.
- **`type_text` bypasses frameworks** → use `fill_input`. **`drain_events()` empties the buffer** → don't call it between two consumers. **`restart_daemon` only stops.** **`-c/--code` doesn't run code.**
- **`BU_CDP_WS` beats `BU_CDP_URL`** when both set. `BU_CDP_URL` is HTTP (resolved to WS); `BU_CDP_WS` is raw WS.
- **⚠︎ Docs vs source drift:** the `remote-browser` skill *page* advertises a verb API (`open/state/click/input/screenshot/close`) — the **shipped** skill uses the coordinate primitives documented here. Forward-dated model names in docs (`gpt-5.5`, `claude-opus-4.6`, etc.) are the docs' identifiers, not validated. The CLI/Harness docs are **not** in `llms.txt` (cloud-only) — they live under `/open-source/` in `sitemap.xml`.

---

## 10. Doctor & troubleshooting

- `browser-use --doctor` (or `browser-use doctor`) diagnoses install/daemon/browser. Interpret:
  - `chrome running` FAIL → ask user to open Chrome, or use a cloud/isolated browser.
  - `daemon alive` FAIL → remote-debugging permission missing, Chrome closed, or CDP endpoint unreachable.
  - `update available` → `browser-use --update -y`.
- `browser-use doctor --fix-snap` — prints how to fix Snap Chromium blocking CDP on Linux (recommends setting `BH_CHROME_PATH`).
- **Stale daemon** (answers `meta:*` but its CDP WS is dead): `ensure_daemon` probes a real `Target.getTargets` and auto-restarts. Force a clean recycle with `browser-use --reload` (stops; next call respawns).
- **Stale socket files** with a dead daemon: `ipc.cleanup_endpoint("default")` + unlink `ipc.pid_path("default")`, then `ensure_daemon()`.
- **Deeper debugging:** inspect `browser_harness/admin.py`, `daemon.py`, `_ipc.py`; daemon log at `<config>/tmp/bu-<NAME>.log`.
- **Setup verification:** if `browser-use <<'PY' … print(page_info()) … PY` prints, setup is done.