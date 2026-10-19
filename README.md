# LogiKeyPad Dev Pad

A native Swift macOS app that turns the **Logitech MX Creative Keypad** into a
code-development control surface — 36 keys on 4 pages for **Muse, Codex, and
Claude Code**, build/test, Git, and GitHub. It drives the keypad **directly over
USB HID from Swift/IOKit — Logi Options+ is not required** (and must not be
running; see Conflicts). Private, on-device use: no accounts, no telemetry.

## Morning quick-start

The app was left running with the **Agents** page painted on the keypad.

1. In the LogiKeyPad window, **Choose Repo…** and pick a git repo.
2. Press the keypad's **page ◀ ▶** buttons — the LCD pages and the app window
   follow each other (Agents → Build → Git → GitHub).
3. On the **Git** page, press **Status** — the app log shows branch/dirty
   counts, and stateful keys (branch, ↑ahead, CI PASS/FAIL) repaint live.
4. Install permanently and enable **Launch at login** in the window footer:
   ```sh
   cp -R build/LogiKeyPad.app /Applications/
   ```

## How it works (direct HID)

The keypad is one 480×480 LCD under nine caps, spoken to in HID++ 4.5 —
reverse-engineered openly by
[julusian/node-logitech-mx-creative-console](https://github.com/julusian/node-logitech-mx-creative-console)
and verified byte-for-byte on this unit with `scripts/hid-probe.swift`:

| Report | Purpose |
|---|---|
| `0x13` in | LCD key presses: `FF 02 00 <seq> 01 <key ids 1…9>` |
| `0x11` in/out | HID++ requests; page buttons via reprogrammable-controls (feature `0x0B`, divert `0x01A1/0x01A2`) |
| `0x14` out | LCD paint: JPEG tiles, chunked 4095 B, keys are 118×118 @ `x=23+c·158, y=6+r·158` |

`MXKeypadHID` hot-plugs via `IOHIDManager`, diverts the page buttons on
connect, and paints **full-panel JPEGs** rendered by `KeyArt` (SF Symbols +
labels at exact pixel size — Retina points will span four keys; see
`IMG_0635.DNG` for the cautionary tale). Paints are hash-gated: the panel only
repaints when page, theme, layout, or a live badge actually changes; the focus
timer repaints just its own tile once per second. Git state is event-driven
(kernel `.git` watchers, no polling).

Two macOS facts that cost an evening, recorded so they cost nobody else one:
`IOHIDDeviceSetReport` buffers must **include** the report-ID byte, and there
must be exactly **one** input-report callback registration (per-ID buffers
replace each other and silently truncate).

The Logi Actions SDK plugin under `plugin/` still builds and works as an
alternative transport (that path *does* require Options+), but the app neither
needs nor prefers it. `Sources/LogiKeyPad/Resources/catalog.json` remains the
single source of truth for all 36 keys in both paths.

## The keys

| Page | Keys |
|---|---|
| **Agents** | Muse app · Codex app · Claude Code (Terminal) · Claude app · Muse CLI · *Review my diff* · *Explain my diff* · *Write tests* · *Commit message* (prompts copy to clipboard with live diff context) |
| **Build** | Build · Test · Run · Format · Lint · Dev server (start/stop) · Clean (confirms in app) · Terminal here · Editor — commands auto-detected (SwiftPM / npm / Xcode / Make) |
| **Git** | Status *(branch badge)* · Stage all *(dirty count)* · Commit *(staged count; message field in app)* · Push *(↑n)* · Pull ff-only *(↓n)* · Fetch · Stash push/pop · Diff in editor · Copy branch |
| **GitHub** | PR open/create · CI checks *(PASS/FAIL badge)* · Re-run failed CI · Reviews for me · Repo web · Copy PR link · Standup → clipboard · Focus 25-min *(countdown on key + menu bar)* · Quick note → `NOTES.md` |

## Personalize

- **Theme**: Midnight (black/white) or Blueprint (blue/white) — repaints instantly.
- **Reassign**: right-click any key in the window grid; the device repaints.
- **Editor/Terminal**: VS Code / Cursor / Xcode; Terminal.app (scriptable —
  first key press asks Automation permission once) or Ghostty (command lands
  on the clipboard).
- Config: `~/Library/Application Support/LogiKeyPad/config.json`.

## Conflicts

- **Logi Options+**: don't run it alongside — it owns the keypad and will
  steal/repaint keys. If you ever install it, quit one or the other.
- **OpenLogi**: lovely project, doesn't support this keypad; also HID++-greedy.

## Develop

```sh
swift test                    # 10 tests: catalog, git parsing, HID framing, image packets, renders
swift scripts/hid-probe.swift info|listen|hidpp|paint   # hardware probe used to verify the protocol
./scripts/build-app.sh        # release .app in ./build (ad-hoc signed)
cd plugin && npm run build:pack   # optional Actions SDK transport (.lplug4)
```
