# scrollwm

[English](README.md) | [简体中文](README.zh-CN.md)

A niri-style **scrollable tiling window manager** for macOS (PaperWM paradigm).

Windows are laid out on an infinitely wide horizontal "paper strip", one column per window. New windows open beside the focused column (right by default, configurable); moving focus scrolls the viewport just enough to reveal the focused column; columns that scroll out of view dock at the screen edge, leaving a thin "paper edge" visible. Keyboard-driven, TOML-configured.

- Pure public Accessibility API (one harmless private function, `_AXUIElementGetWindow`, used to fetch window IDs)
- **No SIP disabling required** — nothing is injected into other processes
- Swift: the layout engine is a pure-function library, `ScrollCore` (53 unit tests); the daemon is `scrollwm`

## MVP scope

Single display (main screen), single workspace (current Space), no trackpad gestures, one window per column.
Column stacking (consume/expel), multiple workspaces, multiple displays, and smooth gesture scrolling are on the roadmap.

## Building & running

Requirements: macOS 14+, Xcode Command Line Tools (Swift 5.10+).

### Option 1: App bundle (recommended for daily use)

```bash
cd scrollwm
./scripts/make-app.sh           # build + assemble + sign dist/ScrollWM.app
mv dist/ScrollWM.app /Applications/
open /Applications/ScrollWM.app
```

A menu bar app (no Dock icon) with its own app icon; the menu includes a **launch at login** toggle (SMAppService, visible in System Settings → Login Items). Permission follows the bundle, so after repackaging you usually don't need to grant again.

### Option 2: Bare binary (for development)

```bash
./scripts/build.sh              # build release and ad-hoc sign
# prints BINARY=<binary path>

<binary path> --check           # check Accessibility permission status
<binary path>                   # run in foreground (logs to stderr)
```

### Accessibility permission

- Launched from a terminal, the process inherits the terminal's Accessibility permission: if your terminal app is already authorized, it just works (great for development).
- Running standalone: on first launch an authorization prompt guides you to System Settings → Privacy & Security → Accessibility, where you add and enable the binary.
- After rebuilding, macOS may ask you to grant again (a known limitation of ad-hoc signing; the scripts use a fixed identifier `com.scrollwm.daemon` to minimize this).

### Launch at login (optional)

App form: use the "Launch at Login" toggle in the menu bar.

Bare binary form: save as `~/Library/LaunchAgents/com.scrollwm.daemon.plist`, then `launchctl load ~/Library/LaunchAgents/com.scrollwm.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.scrollwm.daemon</string>
    <key>ProgramArguments</key>
    <array><string>/absolute/path/scrollwm</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
```

## Default keybindings

Alt (Option) is the default mod key; everything is rebindable in the config:

- `alt-left` / `alt-right`: move focus to the left / right column (auto-scrolls to reveal)
- `alt-h` / `alt-l`: same as above, Vim-style aliases; can be unbound in config
- `alt-shift-h` / `alt-shift-l`: move the focused column left / right
- **⌘ + drag a window** (niri's Mod+drag): hold ⌘ and drag a tiled window; on release it reorders to the drop position. Dragging without ⌘ still snaps back to the strip and absorbs width changes
- `alt-r`: cycle width presets (1/3 → 1/2 → 2/3 → wrap)
- `alt-minus` / `alt-equal`: continuously narrow / widen (step `resize_step`); floating windows scale by about `2 × resize_step` around their center
- `alt-f`: toggle full-width column (press again to restore)
- `alt-c`: center the focused column in the viewport
- `alt-t`: toggle floating exemption (float out of / back into the strip)
- `alt-q`: close window (same as clicking the red button)
- `alt-shift-r`: full rescan and retile

The menu bar icon is the escape hatch: pause/resume management, the settings window (retile-now and open-config-file live at the bottom of it), and quit. Permission helpers only appear while accessibility permission is missing.

## Configuration

`~/.config/scrollwm/config.toml`, auto-generated with a default template on first launch, hot-reloaded on save.

### Settings window

Menu bar → **Settings…** opens a settings window covering every option: layout gaps/widths, animation, focus ring, compositor, ignored apps, keybindings (press-to-record), and **language** (follows the macOS system language by default; English and Simplified Chinese are built in). Changes are written back to `config.toml` immediately and hot-reloaded — there is no Save button. Editing the file by hand remains fully supported, and external edits sync back into the open window. One note: saving from the settings window rewrites the file in canonical form; values are preserved, but custom comments may be replaced by the standard annotations.

Manual configuration:

```toml
[general]
language = "system"   # UI language: "system" (follow macOS) / "zh-hans" / "en"

[gaps]
inner = 6           # gap between columns, freely adjustable
outer = 12          # margin at the screen edges
screen_margin = 6   # docked columns show a thin paper edge, avoiding the look of overlapping windows

[layout]
width_presets = [0.33333, 0.5, 0.66667]
default_width = 0.5
resize_step = 0.05
new_window_side = "right"   # "left" to open new windows on the left of the focused column

[animation]
enabled = true
mode = "spring"
# Matches niri's horizontal-view-movement defaults: critically damped, no bounce.
# Keeps inheriting the current velocity while the target keeps changing.
damping_ratio = 1.0
stiffness = 800
epsilon = 0.0001
# For fixed curves: used when mode = "easing"
# duration_ms = 240
# curve = "ease-out-quint"

[focus_ring]
enabled = true
width = 3          # blue-purple gradient border width (1...8)
glow_radius = 9    # outer glow radius (0...24)

[compositor]
enabled = false     # compositor-level animation (SkyLight). Requires SIP off and Dock injection,
                    # see docs/COMPOSITOR-SETUP.md; falls back to AX when the payload isn't ready

[apps]
ignore = []         # bundle IDs to leave alone, e.g. ["com.apple.systempreferences"]

[bindings]
# Default bindings + user overrides; any supported combo can be bound, "none" unbinds defaults.
"alt-left" = "focus-left"
"alt-right" = "focus-right"
"alt-h" = "none"             # example: unbind the built-in Vim-style alias
"alt-w" = "cycle-width"      # example: add a custom binding
"alt-q" = "none"             # example: unbind the default close key
# Actions: focus-left/right, move-left/right, cycle-width, grow-width,
# shrink-width, toggle-full-width, center-column, toggle-float,
# close-window, retile, none
# Key name notes: equal is the plus key (plus is an alias), kpplus/kpminus are the keypad +/- keys
```

## Behavior conventions

- Only standard windows (`AXStandardWindow`) are managed; dialogs, panels, PiP, and native fullscreen are never touched.
- Windows that can't be resized are automatically floating-exempt.
- Dragging a window: on release it snaps back to the strip layout; **manual width changes are absorbed as column width** (niri's interactive-resize semantics).
- Minimized windows leave the strip; on restore they rejoin beside the focused column (same side as new windows).
- Space switches / app hides trigger a reconciliation (windows outside the current Space are not managed).
- On quit, windows keep their current positions; no restore.

## Manual QA checklist

After building, walk through this (TextEdit / Terminal / browser with 5+ windows):

1. On launch, existing windows enter the strip left-to-right and the layout applies immediately
2. New windows open beside the focused column (left or right, in Settings), gain focus, and the viewport scrolls to reveal them
3. `alt-left/right` (or `alt-h/l`) moves focus along the strip; crossing the viewport boundary triggers minimal scrolling; clicking or Cmd-Tabbing to a docked column scrolls too
4. `alt-shift-h/l` moves columns, focus follows
5. `alt-r` cycles widths; `alt-minus/equal` continuously resizes; `alt-f` full-width roundtrip; `alt-c` centers
6. Closing a window (`alt-q` or the red button): column removed, focus moves to the right neighbor
7. Dragging snaps back on release; manually widening a window → width absorbed as column width
8. Popup dialogs (e.g. save panels) are not managed
9. `alt-t` floating exemption roundtrip
10. Editing the config → auto-reload (gap changes visible immediately); menu bar pause/resume
11. Minimize → column disappears; restore from Dock → back on the strip
12. Suspending an app (`kill -STOP`): other window operations aren't blocked (1s timeout fallback)

## How the animation works

AX APIs have no native animation (true compositor animation would require disabling SIP and injecting; this project doesn't do that), so animation is driven by 60Hz easing interpolation, with a few key engineering choices for smoothness:

- Writes go through **per-app parallel serial queues**: apps animate concurrently, so the tick cost is the slowest app, not the sum
- Pure moves send only `setPosition` (1 RPC), avoiding `setFrame`'s triple calls
- Size changes snap into place at animation start, then only position is animated (continuous resizing would make apps re-layout repeatedly)
- Adaptive frame dropping: if a slow app hasn't returned the previous write, this tick is skipped for it — it degrades gracefully without dragging others down
- The final frame is forced to land exactly; bulk reconciliations (startup / Space switch) apply instantly

Apps that are slow to re-layout (browsers, Electron) naturally animate at lower frame rates than lightweight apps — expected behavior; disable animation in config `[animation]` if you don't like it.

### Compositor-level animation (optional, requires SIP off)

If you want niri-grade buttery animation, there's the SkyLight compositor path: partially disable SIP, inject a payload into `Dock.app`, and use Dock's privileged connection to move windows atomically in a single `SLSTransaction` — all windows move in the same frame, completely eliminating AX's window-by-window stutter.

Please read [docs/COMPOSITOR-SETUP.md](docs/COMPOSITOR-SETUP.md) for the costs and prerequisites first: permanently reduced system security, likely re-reverse-engineering after every macOS major update, and you must disable SIP in Recovery Mode yourself. Relevant commands: `scrollwm --check-sa`, `sudo scrollwm --load-sa [--force]`. It falls back to AX animation when the payload isn't ready; normal use is unaffected.

## Known limitations

- macOS doesn't allow windows to go fully off-screen, so docked columns leave a `screen_margin`-wide edge visible (also a visual cue — same behavior as PaperWM)
- Windows on secondary displays are not managed; strip state doesn't preserve order across native Spaces
- Some self-drawn-window apps (certain Electron/Java) have slow event handling; occasionally `alt-shift-r` is needed to retile manually

## Architecture

```
Sources/ScrollCore/        pure layout engine (no AppKit dependency, unit-testable)
  Strip.swift              strip model: columns/focus/scroll position + all transforms
  LayoutEngine.swift       geometry: column widths, scroll clamping, minimal reveal, edge docking
Sources/scrollwm/
  AXLayer.swift            AXWindow/AXApplication wrappers + screen coordinate conversion + on-screen window set
  WindowManager.swift      orchestrator: event loop, full reconciliation, diff dispatch, echo suppression, drag settlement
  Hotkeys.swift            Carbon global hotkeys (doesn't intercept the event stream)
  Config.swift             TOML parsing + write-back serialization + default template + file-watch hot reload
  SettingsUI.swift         SwiftUI settings window (immediate write-back to config.toml)
  StatusItem.swift         menu bar escape hatch
  AppDelegate.swift        permission guidance and assembly
Tests/ScrollCoreTests/     engine unit tests (53)
```

References: [AeroSpace](https://github.com/nikitabobko/AeroSpace) (AX architecture), [PaperWM.spoon](https://github.com/mogenson/PaperWM.spoon) (scroll semantics & docking tricks), [niri](https://github.com/YaLTeR/niri) (interaction paradigm).

## License

[GPL-3.0](LICENSE).
