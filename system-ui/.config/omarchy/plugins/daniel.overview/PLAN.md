# Workspace Overview — Implementation Plan (v1)

> **STATUS: v1 COMPLETE — 2026-09-07.** All 6 tasks built and verified in a live session
> (single monitor). `mode: full`. Deferred verification: focused-monitor targeting when
> docked (no external available at build time). v2 backlog: render on both screens with
> the non-active monitor dimmed; live window thumbnails (screencopy).
>
> **For workers:** Build task-by-task. Steps are `- [ ]` checkboxes. This is a
> QML Quickshell plugin in `~/.config` (no git repo, no unit-test harness):
> "verify" = reload the shell and observe, not pytest/commit. Visual/behavioural
> checks are performed by the user (Daniel) in their live Hyprland session — each
> task ends with a concrete thing for them to confirm before proceeding.

**Goal:** A Quickshell overview on the active monitor showing every monitor's
workspaces as one boxed row each, with a spatial icon mini-map of windows, toggled
by SUPER+P, to jump between workspaces.

**Architecture:** An Omarchy-shell `overlay` plugin (`manifest.json` + `Overview.qml`)
in `~/.config/omarchy/plugins/daniel.overview/`. Root `Item` with `toggle()/open()/close()`
(the shell calls `toggle()` for `omarchy-shell shell toggle daniel.overview`), a
`Quickshell.Wayland` overlay surface shown when `opened`, and a focusable key-catcher
for keyboard selection. Data from `Quickshell.Hyprland` (`Hyprland.workspaces`,
`.toplevels`, `.focusedWorkspace/Monitor`); jump via Hyprland dispatch.

**Tech stack:** Quickshell (QML/QtQuick), Quickshell.Hyprland, Omarchy shell singletons
`Color`/`Style`/`Border`/`Util` (from `qs.Commons`/`qs.Ui`), Hyprland 0.56.2.

**Reference templates (read before each task):**
- `/usr/share/omarchy/shell/plugins/clipboard/{manifest.json,Clipboard.qml}` — overlay plugin + toggle contract + theme token usage + keyCatcher pattern.
- `/usr/share/omarchy/shell/Ui/Panel.qml` — shared overlay surface (window/layer/scrim).
- `/usr/share/omarchy/shell/plugins/bar/widgets/Workspaces.qml` — `Hyprland.workspaces` model, occupied/focused derivation, workspace-focus dispatch.

**Global verify helpers:**
- Reload after any plugin edit: saving under `~/.config/omarchy/plugins/` auto-reloads; force with `omarchy-shell shell rescanPlugins` (or `omarchy restart shell`).
- **Loading edited QML requires `omarchy restart shell`** (learned the hard way):
  `omarchy-shell shell rescanPlugins` reloads the plugin *registry/manifest* but NOT the
  live QML component, and the "save auto-reloads" behavior did not fire reliably here — so
  after editing `Overview.qml`, run `omarchy restart shell` and re-open to see the change.
  (`keepLoaded: false` in the manifest is still correct — no cross-summon state — but it
  does not by itself make source edits hot-reload.) Note the shell drives `open()`/`close()`
  on the item via its per-plugin Loader (summon/hide); it does **not** call the plugin's own
  `toggle()` (that fn is effectively unused via IPC).
- If the overlay doesn't appear / shell misbehaves, check load errors: `journalctl --user -o cat -n 60 $(systemctl --user list-units 'omarchy-shell*' -q >/dev/null 2>&1 && echo -u omarchy-shell*)` — or run the shell in a terminal to see stderr. (Confirm the shell's real unit/log path in Task 1.)

---

## Task 1 — Scaffold plugin + toggle/close contract (highest-stakes)

This task locks in the overlay+toggle mechanism everything else hangs off. Mirror
`clipboard/Clipboard.qml`'s root structure exactly; only the contents differ.

**Files:**
- Create: `~/.config/omarchy/plugins/daniel.overview/manifest.json`
- Create: `~/.config/omarchy/plugins/daniel.overview/Overview.qml`
- (Reference: `clipboard/manifest.json`, `clipboard/Clipboard.qml:1-60`, `Ui/Panel.qml`)

- [ ] **Step 1 — Confirm the shell's log/unit** so later verify steps are real.
  Run: `systemctl --user list-units '*omarchy*shell*'; pgrep -a -f 'quickshell|omarchy-shell' | head`
  Record where the shell logs (systemd user unit vs a bare process) into this file's
  "Global verify helpers" line. Property: subsequent tasks must point at the log path
  that actually receives QML errors, not a guessed one.

- [ ] **Step 2 — Write `manifest.json`** (mirror clipboard's, new id):
```json
{
  "schemaVersion": 1,
  "id": "daniel.overview",
  "name": "Workspace Overview",
  "version": "0.1.0",
  "author": "daniel",
  "description": "Visual overview of all workspaces, grouped by monitor",
  "kinds": ["overlay"],
  "keepLoaded": true,
  "entryPoints": { "overlay": "Overview.qml" }
}
```

- [ ] **Step 3 — Write a minimal `Overview.qml`.** Root `Item` with `opened` +
  `open()/close()/toggle()` (shape from `Clipboard.qml:42-60`) and the theme property
  block from `Clipboard.qml:26-40` (`scrim`/`background`/`cornerRadius` from
  `Color.menu.*` + `Style.*`). The surface is a **`PanelWindow`** mirroring
  `Clipboard.qml:314-332` — **do NOT use `Ui/Panel.qml`** (it is only the IPC lifecycle
  base: an `Item` + `IpcHandler`, no window/layer/scrim):
```qml
PanelWindow {
  id: panel
  visible: root.opened
  screen: root.targetScreen                 // focused monitor — Step 3a
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "daniel-overview"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore
  Rectangle { anchors.fill: parent; color: root.scrim }          // scrim
  MouseArea { anchors.fill: parent; onClicked: root.close() }     // scrim dismiss
  Rectangle {                                                     // placeholder card
    anchors.centerIn: parent; width: 400; height: 200
    radius: root.cornerRadius; color: root.background
    MouseArea { anchors.fill: parent; onClicked: {} }            // swallow inside-card clicks
    Item { id: keyCatcher; anchors.fill: parent; focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: e => { if (e.key === Qt.Key_Escape) { root.close(); e.accepted = true } }
    }
    Text { anchors.centerIn: parent; text: "overview"; color: root.foreground }
  }
}
```
  In `open()`: set `opened=true`, resolve `targetScreen` (Step 3a), then
  `Qt.callLater(() => keyCatcher.forceActiveFocus())` (as `Clipboard.qml:49`).

- [ ] **Step 3a — Target the focused monitor** (Clipboard sets no `screen:`, so a bare
  PanelWindow would not reliably land on the focused output). Add
  `property var targetScreen: null` and resolve in `open()`:
```qml
function focusedScreen() {
  var mon = Hyprland.focusedMonitor
  var screens = Quickshell.screens || []
  for (var i = 0; i < screens.length; i++)
    if (mon && screens[i].name === mon.name) return screens[i]
  return screens.length ? screens[0] : null
}
```
  Property this task must achieve: **`toggle()`/`open()` shows a scrim+card overlay
  with exclusive keyboard focus on the monitor that currently has focus (put focus on
  the external and it opens there, not the laptop); Esc and a scrim click both close it;
  nothing is disturbed while closed.**

- [ ] **Step 3b — Enable the plugin** (new plugins default to `disabled`; enablement is
  stored in `~/.config/omarchy/shell.json` under `plugins[]`, NOT auto-on on discovery).
  Run: `omarchy plugin validate ~/.config/omarchy/plugins/daniel.overview` (expect no
  errors), then `omarchy plugin enable daniel.overview` (expect `Enabled daniel.overview`).
  Confirm: `omarchy plugin list` shows it `enabled`. Property: **without this, the shell
  discovers/loads the QML but `toggle` logs `summon: plugin not enabled` and shows nothing.**

- [ ] **Step 4 — Reload + user verify.**
  Run: `omarchy-shell shell rescanPlugins`
  Then Daniel, with focus on the **external** monitor, runs
  `omarchy-shell shell toggle daniel.overview` → the overlay must appear **on the
  external**; run it again → it hides (the IPC command flips both ways — unlike the
  keybind in Task 2). Repeat with focus on the laptop → it appears on the laptop.
  While open: press **Esc** → closes; reopen and **click the scrim** (outside the card)
  → closes. **Distinguishes:** broken manifest/entrypoint (nothing appears / shell logs
  a load error), a wrong-monitor surface (always lands on the primary), and a
  non-closing Esc/scrim. If nothing appears, check the log from Step 1.

---

## Task 2 — Bind SUPER+P

**Files:** Modify `~/.config/hypr/bindings.lua` (the `SUPER + P` block currently
pointing at the removed `workspace-picker.sh`).

- [ ] **Step 1 — Replace the picker bind.** Change the `o.bind("SUPER + P", ...)`
  line to:
```lua
o.bind("SUPER + P", "Workspace overview", "omarchy-shell shell toggle daniel.overview")
```
  Keep the existing `hl.unbind("SUPER + P")` above it. Leave `SUPER + U` (pseudo) as-is.

- [ ] **Step 2 — Reload + verify (incl. the focus interaction).**
  Run: `hyprctl reload && hyprctl configerrors`  → expect `ok` / empty.
  Daniel: press **SUPER+P** → opens; **SUPER+P again** → closes; **Esc** → closes.
  VERIFIED 2026-09-06: SUPER+P toggles **both** ways — Hyprland processes the keybind even
  though the overlay holds exclusive keyboard focus, and bare keys (Esc, proven in Task 1)
  still reach the overlay. Both mechanisms coexist; no on-demand-focus change needed.
  **Distinguishes:** a still-dead binding (nothing happens on first press).

---

## Task 3 — Workspace rows grouped by monitor (no window contents yet)

**Files:** Modify `Overview.qml` (replace the placeholder box with the row/grid model).

- [ ] **Step 1 — Build the grouped model.** From `Hyprland.workspaces.values`, group
  workspaces by monitor (`workspace.monitor`), ordered active-monitor-first, then the
  rest. Within a monitor: in `full` mode include its pinned ids (1-5 on eDP-1, 6-10 on
  HDMI-A-1, derived from actual monitor mapping, not hardcoded — read each ws's
  `.monitor.name`); in `occupied` mode only ws with `toplevels.values.length > 0`.
  Exclude special workspaces (`id < 0` or name starting `special:`). Reuse the
  occupied/focused derivation from `Workspaces.qml:57-59`.
  Property: **row count == number of connected monitors that own workspaces; each row
  contains exactly that monitor's workspaces; undocked collapses to one row.**

- [ ] **Step 2 — Render.** One boxed `Column` of rows; each row a labelled container
  (monitor name) with a `Row`/`GridLayout` of workspace cells. Cell = rounded
  `Rectangle` showing the number (`10`→`"0"`), `Color.menu.*` tokens, `Style.cornerRadius`;
  focused cell → accent border (`Border.surfaceSpec`), empty → `opacity 0.5`.

- [ ] **Step 3 — Reload + verify.** Daniel toggles the overlay while docked and again
  with only the laptop. Expected: two rows (Laptop eDP-1: 1-5, External HDMI-A-1: 6-10)
  when docked; one row when undocked; the current workspace is highlighted; empty ones
  dimmed. **Distinguishes:** wrong grouping (workspaces under the wrong monitor),
  hardcoded rows that don't collapse undocked, wrong focus highlight.

---

## Task 4 — Window mini-map inside each cell

**Files:** Modify `Overview.qml` (cell contents).

- [ ] **Step 1 — Refresh geometry on open.** `toplevel.lastIpcObject` can be **stale**
  (Quickshell HyprlandToplevel docs). In `open()` call `Hyprland.refreshToplevels()` and
  `Hyprland.refreshMonitors()`, and build the mini-map from property **bindings** that
  re-evaluate when those refreshes land — do NOT snapshot values once at open into
  plain vars. Property: **moving/resizing a window while the overview is closed is
  reflected the next time it opens, not the geometry from a previous open.**

- [ ] **Step 2 — Convert to monitor-local logical coords, preserving aspect ratio.**
  Window `at`/`size` (from `toplevel.lastIpcObject`) are **global logical** px; the
  monitor origin is its Hyprland `.x/.y` (logical) and its logical size is
  `physical_size / scale`. For a window on monitor `M` into cell rect `cell`:
```js
monLogicalW = M.width / M.scale          // eDP-1: 2560/1.25 = 2048
monLogicalH = M.height / M.scale         //        1600/1.25 = 1280
localX = win.at[0] - M.x                 // subtract origin (eDP-1: x=0, y=1440)
localY = win.at[1] - M.y
k = Math.min(cell.w / monLogicalW, cell.h / monLogicalH)   // uniform => keep aspect
boxX = cell.x + (cell.w - monLogicalW*k)/2 + localX*k       // letterbox-centered
boxY = cell.y + (cell.h - monLogicalH*k)/2 + localY*k
boxW = win.size[0]*k ;  boxH = win.size[1]*k
```
  v1 maps the **full monitor logical area** (reserved bar space `M.reserved` ignored —
  note as a later refinement). Draw each window as a rounded `Rectangle` at
  `(boxX,boxY,boxW,boxH)`. Property: **a maximized window fills the cell; two tiles land
  left/right; a window on eDP-1 (origin 0,1440, scale 1.25) stays inside its cell —
  origin AND scale both applied, never raw desktop coords.**

- [ ] **Step 3 — App icon.** Resolve an icon from the window `class`/app id via the
  shell's icon lookup (grep `Quickshell.iconPath` / an `AppIcon`/`DesktopEntry` usage
  under `/usr/share/omarchy/shell/` in this step and mirror it). Center the icon in the
  box; fall back to the class initial if none resolves.

- [ ] **Step 4 — Reload + verify.** Daniel opens the overlay with a couple of tiled
  windows on one workspace and a maximized window on another → boxes mirror the real
  layout; app icons show (VSCode/Chrome/terminal recognizable). Then **close it, move/
  resize a window, reopen** → the mini-map reflects the new geometry (proves Step 1's
  refresh). Confirm a window on **eDP-1** sits inside its cell (proves Step 2's
  origin+scale). **Distinguishes:** windows stacked at 0,0 (geometry not read), eDP-1
  windows pushed off-cell (origin/scale not applied), stale geometry after move/resize
  (no refresh), missing icons, or scratchpad windows leaking in.

---

## Task 5 — Selection (keyboard + mouse)

**Files:** Modify `Overview.qml` (keyCatcher handlers + cell `MouseArea`).

- [ ] **Step 1 — Selection state.** Maintain `property var cells: []` — the flattened
  visible cells in row-major order (`{ id, workspace }`), from the same model Task 3
  renders. Add `property int selectedIndex: -1`. On `open()` (after the refresh),
  initialize to the cell whose `id === Hyprland.focusedWorkspace.id` if that workspace is
  visible, else `0` if any cells exist, else `-1`. Whenever `cells` changes, **clamp**:
  `selectedIndex = cells.length ? Math.min(Math.max(selectedIndex,0), cells.length-1) : -1`.
  Property: **opening highlights the current workspace when shown; in `occupied` mode with
  zero occupied workspaces the overlay opens with no selection and does not crash; the
  highlight never points past the end after the model changes.**

- [ ] **Step 2 — Jump helper.**
  `function jump(id) { if (id === undefined || id === null) return; <dispatch>; root.close() }`.
  For `<dispatch>` use the mechanism from `Workspaces.qml:33-36` adapted for an overlay
  (no `bar`): a `Quickshell.Io.Process` running
  `hyprctl dispatch "hl.dsp.focus({ workspace = \"<id>\" })"`, OR
  `Hyprland.dispatch("workspace " + id)` — **test both, keep whichever actually switches**
  (record which in a comment). Always resolve the workspace **id** first, never a cell
  index. Property: **`jump(id)` moves focus to workspace `id` and closes; `jump()` with no
  arg is a safe no-op.**

- [ ] **Step 3 — Keys.** In `keyCatcher`: number keys `1`-`9` → `jump(n)`, `0` →
  `jump(10)`; arrow keys move `selectedIndex` across `cells` (clamped, no wrap past the
  ends); `Return` → `if (selectedIndex >= 0) jump(cells[selectedIndex].id)` (Enter with no
  selection does nothing); `Escape` → `close()` (already present).

- [ ] **Step 4 — Mouse.** Each cell gets a `MouseArea { onClicked: root.jump(id) }`
  (the cell's workspace id, resolved in QML, not an index).

- [ ] **Step 5 — Reload + verify.** Daniel: press SUPER+P, then (a) press `3` → lands on
  ws 3, overlay closed; (b) SUPER+P, arrow to a cell, Enter → lands there; (c) SUPER+P,
  click a cell → lands there; (d) set `mode:"occupied"`, close every window, SUPER+P →
  overlay opens with no crash and Enter does nothing. **Distinguishes:** keys not routed
  (no focus grab), off-by-one on `0`→10, click not switching, and an empty-model crash /
  Enter-on-nothing.

---

## Task 6 — `mode` setting, theming polish, scrim-dismiss

**Files:** Modify `Overview.qml`.

- [ ] **Step 1 — `mode` property.** `property string mode: "full"` at the root; Task 3's
  model already branches on it. Document at the top of the file how to flip it
  (`"full"` ↔ `"occupied"`). Property: **setting `mode: "occupied"` and reloading shows
  only non-empty workspaces; `"full"` shows all pinned per monitor.**

- [ ] **Step 2 — Polish.** Rounded row containers, consistent `Style.spacing`, a hint
  line (`1-0 jump · click · Esc close`); click on the scrim (outside the rows) closes;
  ensure all colors come from `Color.*`/`Style.*` (no literals) so theme changes
  re-style it.

- [ ] **Step 3 — Verify.** Daniel switches Omarchy theme with the overlay open (or
  reopen after): colors follow the theme. Flip `mode` to `occupied`, reload: empty
  cells gone. Click outside rows: closes. **Distinguishes:** hardcoded colors that
  don't re-theme, `mode` not honored, scrim-dismiss missing.

---

## Self-review notes

- **Spec coverage:** trigger+toggle (T1,T2), per-monitor rows (T3), spatial mini-map
  (T4), selection all inputs (T5), full/occupied + theming + special exclusion
  (T3 exclude, T6) — all `DESIGN.md` v1 items mapped. Deferred (both-screens/dimming,
  live thumbnails) intentionally absent.
- **Highest-stakes task:** Task 1 (overlay+toggle contract) — everything inherits it;
  its verify must actually show/hide on the right monitor, not just "no error".
- **Overlay surface API is now resolved** (a `PanelWindow` mirroring
  `Clipboard.qml:314-332` with exclusive keyboard focus + explicit focused-monitor
  `screen:` — Task 1), not the earlier guessed `Ui/Panel.qml`.
- **Unpinned unknowns, each with a concrete settling step (not hand-waved):** app-icon
  lookup helper (T4 Step 3) and which dispatch form switches workspace (T5 Step 2).
- **Post-review fixes (from Astra's plan review):** exclusive-focus surface + monitor→
  screen mapping (T1); the SUPER+P-can't-close-while-open contract + its test (DESIGN +
  T2); `refreshToplevels()` on open + stale-geometry test (T4 S1/S4); explicit
  monitor-local logical coordinate conversion with aspect ratio (T4 S2); selection
  init/clamp/empty-model guard (T5 S1/S3/S5).
- No per-step git commits: `~/.config` is not a repo here. If Daniel later versions
  his dotfiles, revisit.
