# HANDOVER — LogiKeyPad Dev Pad

Purpose: **educational demonstration** of coding capabilities (native
Swift, direct HID device control, local-first tooling) for learning and
personal experimentation — not a commercial product. Built with
**Muse Code powered by muse-wonder-full-1.0** (Meta).

State as of **2026-10-20**, commit line: `96ad6b8` (initial) → `1505454`
(repo picker) → `06830d3` (visible terminal) → *this commit* (handover).
Repo: <https://github.com/neuroccm/LogiKeyPadMacOSSwift> — **public,
locked down** (issues/wiki/projects/Actions off, interactions
collaborators-only until 2027-04-20, `main` ruleset vs delete/force-push,
no license = all rights reserved; forking can't be disabled on GitHub
public repos, but only the owner can write).

## What works (all verified live on the owner's keypad + Mac)

- Direct-HID driver: hot-plug, 9 keys (down/up/holds/chords), page buttons
  (HID++ divert), full-panel JPEG painting with live badges, ACK pacing.
- Quit restores pre-app device state (blank panel + un-divert); relaunch
  retakes control cleanly (quit→relaunch cycle verified; the blank moment
  itself wasn't visually witnessed by the agent — glance once to confirm).
- Visible-in-terminal execution (default **Run: Visible**): tty+cwd match,
  foreground-idle guard (`tpgid == pgid`), busy → headless fallback,
  Ghostty → clipboard. Verified end-to-end by the owner ("each step worked").
- GitHub repo picker: 42 repos synced, 11 clones resolved incl. renamed and
  nested folders; Recent 5/10; one-click clone.
- 20 unit tests green, including from a fresh public clone.
- DMG: universal (arm64+x86_64), ad-hoc signed only, produced by
  `scripts/build-dmg.sh` → timestamped file on `~/Desktop` every rebuild.

## Run it on a fresh machine

```sh
git clone https://github.com/neuroccm/LogiKeyPadMacOSSwift.git
cd LogiKeyPadMacOSSwift
swift test                     # 20 tests, no hardware needed
./scripts/build-dmg.sh         # app + Desktop DMG
open ~/Desktop/LogiKeyPad-*.dmg  # newest; drag to Applications, right-click → Open once
gh auth login                  # only for repo picker / PR / CI keys
```

Needs: macOS 14+, Xcode/Swift 6, MX Creative Keypad on USB-C. Config self-
creates in `~/Library/Application Support/LogiKeyPad/` (never in the repo).
Firsts to expect: Automation prompt (app → Terminal) on first visible-mode
key; **Downloads-folder TCC** if a repo lives under `~/Downloads` and state
shows "Not a git repo" — grant Files & Folders → Downloads, or re-pick via
*Choose Folder…*. Don't run Logi Options+ simultaneously.

## Standing rules (owner's, keep them)

1. **Every rebuild ships a NEW timestamped DMG** (`scripts/build-dmg.sh`).
2. Private-use posture: no Marketplace submission; the SDK `plugin/` is an
   optional transport only.
3. `catalog.json` is the single source of truth for keys; destructive
   actions carry `"confirm": true`.
4. Resource discipline: event-driven refresh, hash-gated paints, capped
   output/log/scan — no polling loops.

## Gotchas that already cost an evening (don't re-learn)

- macOS `IOHIDDeviceSetReport` buffers must **include the report-ID byte**.
- Exactly **one** `IOHIDDeviceRegisterInputReportCallback` registration,
  buffer ≥ largest report (per-ID registrations replace & truncate).
- Key art must be **exact pixels** (118 / 480), not points — Retina 2×
  spans four keys (see `IMG_0635.DNG`, untracked, owner's photo).
- SwiftUI: child `ObservableObject`s don't forward — AppState re-sends
  `objectWillChange` (monitor/HID/bridge) or the UI silently goes stale.
- Swift synthesized `Codable` ignores property defaults — config and the
  bridge codec use explicit `decodeIfPresent` decoders. Follow that pattern.
- `ps` parsing: fields past `maxSplits` keep padding spaces.

## Next cycle candidates (rough priority)

1. **Brightness** — HID++ feature identified in upstream (`0x0F` idx,
   fn2); needs index discovery on this unit before wiring a slider.
2. **Per-repo page sets / frontmost-editor repo auto-switch.**
3. **Long-press key variants** (down/up already distinct events).
4. Cosmetic: controls row truncates ("Termi…") at restored window widths.
5. Bridge/plugin: keep or delete? Direct HID made it redundant; deleting
   `plugin/` + `BridgeServer` simplifies, but it's the only Options+ path.

## Pointers

`README.md` (user-facing) · `scripts/hid-probe.swift` (protocol probe:
`info|listen|hidpp|pingx|paint`) · protocol upstream:
<https://github.com/julusian/node-logitech-mx-creative-console> ·
SDK docs: <https://logitech.github.io/actions-sdk-docs/>
