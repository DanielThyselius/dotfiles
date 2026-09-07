# Workspace Overview — design (v1)

Date: 2026-09-06 · Omarchy 4.0.2 (Quattro) · Hyprland 0.56.2 · Quickshell shell

A Quickshell workspace overview for Omarchy, triggered by SUPER+P. Replaces the
dead v3 `workspace-picker.sh` (which relied on `walker`, removed in Quattro).

## Goal

Press SUPER+P to get a visual overview of all workspaces (grouped by monitor) and
jump to one — keyboard or mouse.

## Scope

**v1 (this design):**
- One overlay, on the **active monitor only**.
- Shows **every connected monitor's workspaces**, grouped into one boxed **row per
  monitor** (dynamic via Hyprland's workspace→monitor mapping). Docked → two rows
  (laptop eDP-1, external HDMI-A-1); undocked → collapses to just the laptop's row.
- **No dimming** (everything is on one screen).

**Deferred (v2, not now):**
- Rendering the overlay on *both* physical screens simultaneously, with the
  non-active monitor's section dimmed.
- Live pixel thumbnails per window (via Quickshell screencopy). Drops in per-window
  without changing the architecture. Zero idle cost (only captures while open), so
  safe to add later; kept out of v1 only to avoid the Hyprland toplevel-export
  dependency risk on the first build.

## Behavior

- **Trigger:** SUPER+P **toggles** the overlay (open *and* close), via `omarchy-shell
  shell toggle`. Esc, a scrim click (outside the rows), and selecting a workspace also
  close it. Verified 2026-09-06: the overlay uses *exclusive* keyboard focus so bare keys
  (numbers/arrows/Esc) reach it, **and** Hyprland still processes the SUPER+P keybind over
  that exclusive focus — so both coexist. (An earlier assumption that exclusive focus
  would swallow SUPER+P was disproved by testing; no on-demand-focus change needed.)
- **Cells:** one per workspace. Windows drawn as a **spatial mini-map** — each window a
  rounded box at its real relative position/size with the app icon (title if it fits).
  Focused workspace = accent border; empty = dimmed. Excludes `special:scratchpad`.
- **`mode` setting** (one property, default `full`):
  - `full` — all pinned workspaces for each monitor, empties dimmed (stable positions).
  - `occupied` — only workspaces with windows.
- **Select:** number keys jump (1-9, `0`=10) · arrow keys move highlight + Enter ·
  mouse click · Esc cancels. Jump via Hyprland dispatch `workspace <id>`.
- **Styling:** pulls the active Omarchy theme (colors/fonts) so it matches the bar and
  re-themes automatically.

## Layout

```
              ACTIVE MONITOR (overlay, centered)
┌─ Laptop · eDP-1 ─────────────────────────────────┐
│  [1★]   [2]    [3]    [4]    [5]                  │
└──────────────────────────────────────────────────┘
┌─ External · HDMI-A-1 ────────────────────────────┐
│  [6]    [7]    [8]    [9]    [10]                 │
└──────────────────────────────────────────────────┘
              1-0 jump · click · Esc close
```

## Architecture / integration

- Omarchy-shell **user plugin**: `~/.config/omarchy/plugins/daniel.overview/`
  (`manifest.json` + `Overview.qml` + any JS helpers). Lives in the user config dir →
  survives `omarchy update`; hot-reloads on save (`omarchy-shell shell rescanPlugins`
  to force).
- Toggled via `omarchy-shell shell toggle daniel.overview`, bound to **SUPER+P** in
  `~/.config/hypr/bindings.lua` (replacing the walker picker line).
- Built on the shell's shared overlay (`Ui/Panel.qml`) + Hyprland service. Data:
  `Hyprland.workspaces` (each with `.toplevels` = its windows incl. geometry + app id,
  `.monitor`), `Hyprland.focusedWorkspace`, `Hyprland.focusedMonitor`.

## Resolved architecture facts (from shell sources)

- Surface = a `PanelWindow` (Quickshell.Wayland), **not** `Ui/Panel.qml` (that is only
  the IPC open/close lifecycle base). Mirror Clipboard's `PanelWindow`: fullscreen
  anchors, `color:"transparent"`, `WlrLayershell.layer: WlrLayer.Overlay`,
  `WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive`, `exclusionMode: Ignore`,
  a scrim `Rectangle` (`Color.menu.scrim`) + a scrim `MouseArea{onClicked: close()}`,
  and a focusable `keyCatcher` `Item{ focus:true; Keys.priority: BeforeItem }`.
- Clipboard sets no `screen:`, so we must: set the `PanelWindow.screen` to the
  Quickshell screen whose `.name` matches `Hyprland.focusedMonitor.name`, resolved when
  opening.
- Window geometry (`toplevel.lastIpcObject.at/size/class`) can be **stale** — call
  `Hyprland.refreshToplevels()` on open and bind to the resulting updates.
- Coordinates: window `at`/`size` are global **logical** px; monitor origin is
  `Hyprland monitor .x/.y` (logical), monitor logical size = physical/scale. Convert to
  monitor-local logical (subtract origin) before scaling into a cell. Real numbers:
  eDP-1 origin (0,1440), 2560×1600 @ scale 1.25 → 2048×1280 logical.

## Open implementation questions (resolve in the build plan)

- App-icon resolution from app id / class (find the shell's icon-lookup helper).
- Which dispatch form actually switches workspace from an overlay (`Hyprland.dispatch`
  vs shelling `hyprctl dispatch` with the lua `hl.dsp.focus` form the bar widget uses).
