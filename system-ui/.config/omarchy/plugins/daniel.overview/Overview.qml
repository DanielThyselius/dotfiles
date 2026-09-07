// Workspace Overview — v1. See DESIGN.md / PLAN.md in this directory.
// T1 overlay+toggle+focus · T2 SUPER+P · T3 rows by monitor · T4 window mini-map
// · T5 selection (numbers/arrows/Enter/click) · T6 hint line + mode + theming.
//
// To try the two grid modes, change `mode` below and run `omarchy restart shell`:
//   "full"     = every (persistent) workspace per monitor, empties dimmed
//   "occupied" = only workspaces with windows (plus the focused one)
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property var targetScreen: null

  property string mode: "full"

  property var rowsModel: []
  property var cells: []           // flattened, row-major: [{ id, focused }]
  property int selectedIndex: -1
  readonly property int selectedId:
    (selectedIndex >= 0 && selectedIndex < cells.length) ? cells[selectedIndex].id : -1

  // Theme tokens (re-theme automatically with the active Omarchy theme).
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selBackground: Color.menu.selectedBackground
  property color selText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius

  function focusedScreen() {
    var mon = Hyprland.focusedMonitor
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++)
      if (mon && screens[i].name === mon.name)
        return screens[i]
    return screens.length ? screens[0] : null
  }

  // [{ name, monX, monY, monW, monH (logical), workspaces:
  //      [{ id, occupied, focused, windows:[{ cls, ax, ay, sw, sh }] }] }]
  function monitorRows() {
    var wss = Hyprland.workspaces ? Hyprland.workspaces.values : []
    var focusedWsId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    var focusedMon = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""

    var byMon = ({})
    var order = []
    for (var i = 0; i < wss.length; i++) {
      var ws = wss[i]
      if (!ws || ws.id < 0)
        continue
      var mon = ws.monitor
      var monName = mon ? mon.name : "?"
      var occupied = ws.toplevels && ws.toplevels.values.length > 0
      if (root.mode === "occupied" && !occupied && ws.id !== focusedWsId)
        continue

      if (!byMon[monName]) {
        var scale = (mon && mon.scale) ? mon.scale : 1
        byMon[monName] = {
          name: monName,
          monX: mon ? mon.x : 0,
          monY: mon ? mon.y : 0,
          monW: mon ? mon.width / scale : 1,
          monH: mon ? mon.height / scale : 1,
          workspaces: []
        }
        order.push(monName)
      }

      var wins = []
      var tls = ws.toplevels ? ws.toplevels.values : []
      for (var j = 0; j < tls.length; j++) {
        var obj = tls[j] ? tls[j].lastIpcObject : null
        if (!obj || !obj.at || !obj.size)
          continue
        wins.push({ cls: obj["class"] || "", ax: obj.at[0], ay: obj.at[1], sw: obj.size[0], sh: obj.size[1] })
      }

      byMon[monName].workspaces.push({
        id: ws.id, occupied: occupied, focused: ws.id === focusedWsId, windows: wins
      })
    }

    order.sort(function (a, b) {
      return (a === focusedMon ? 0 : 1) - (b === focusedMon ? 0 : 1)
    })

    var rows = []
    for (var k = 0; k < order.length; k++) {
      var m = byMon[order[k]]
      m.workspaces.sort(function (x, y) { return x.id - y.id })
      if (m.workspaces.length)
        rows.push(m)
    }
    return rows
  }

  function rebuild() {
    var rows = monitorRows()
    var flat = []
    for (var r = 0; r < rows.length; r++)
      for (var w = 0; w < rows[r].workspaces.length; w++)
        flat.push({ id: rows[r].workspaces[w].id, focused: rows[r].workspaces[w].focused })

    root.rowsModel = rows
    root.cells = flat

    if (root.selectedIndex < 0) {
      var fi = -1
      for (var i = 0; i < flat.length; i++)
        if (flat[i].focused) { fi = i; break }
      root.selectedIndex = fi >= 0 ? fi : (flat.length ? 0 : -1)
    } else {
      root.selectedIndex = flat.length ? Math.min(Math.max(root.selectedIndex, 0), flat.length - 1) : -1
    }
  }

  function moveSel(delta) {
    if (!cells.length) return
    var n = selectedIndex + delta
    if (n < 0) n = 0
    if (n > cells.length - 1) n = cells.length - 1
    selectedIndex = n
  }

  function jump(id) {
    if (id === undefined || id === null) return
    Hyprland.dispatch('hl.dsp.focus({ workspace = "' + id + '" })')
    root.close()
  }

  function open() {
    if (typeof Hyprland.refreshMonitors === "function") Hyprland.refreshMonitors()
    if (typeof Hyprland.refreshToplevels === "function") Hyprland.refreshToplevels()
    root.targetScreen = root.focusedScreen()
    root.selectedIndex = -1
    root.opened = true
    root.rebuild()
    refreshTimer.restart()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close(); else root.open()
  }

  Timer {
    id: refreshTimer
    interval: 80
    repeat: false
    onTriggered: if (root.opened) root.rebuild()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "daniel-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    Rectangle {
      id: card
      anchors.centerIn: parent
      radius: root.cornerRadius
      color: root.background
      border.width: 1
      border.color: root.borderColor
      readonly property int pad: 16
      implicitWidth: content.implicitWidth + pad * 2
      implicitHeight: content.implicitHeight + pad * 2

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          var k = event.key
          if (k === Qt.Key_Escape) { root.close(); event.accepted = true }
          else if (k >= Qt.Key_1 && k <= Qt.Key_9) { root.jump(k - Qt.Key_0); event.accepted = true }
          else if (k === Qt.Key_0) { root.jump(10); event.accepted = true }
          else if (k === Qt.Key_Left || k === Qt.Key_Up) { root.moveSel(-1); event.accepted = true }
          else if (k === Qt.Key_Right || k === Qt.Key_Down) { root.moveSel(1); event.accepted = true }
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (root.selectedIndex >= 0 && root.selectedIndex < root.cells.length)
              root.jump(root.cells[root.selectedIndex].id)
            event.accepted = true
          }
        }
      }

      Column {
        id: content
        anchors.centerIn: parent
        spacing: 10

        Column {
          id: rows
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 12

          Repeater {
            model: root.opened ? root.rowsModel : []

            // One boxed row per monitor.
            Rectangle {
              id: monRow
              required property var modelData
              radius: root.cornerRadius
              color: "transparent"
              border.width: 1
              border.color: root.borderColor
              readonly property int rowPad: 10
              implicitWidth: rowCol.implicitWidth + rowPad * 2
              implicitHeight: rowCol.implicitHeight + rowPad * 2

              Column {
                id: rowCol
                anchors.centerIn: parent
                spacing: 8

                Text {
                  text: monRow.modelData.name
                  color: root.foreground
                  opacity: 0.6
                  font.pixelSize: 12
                }

                Row {
                  spacing: 8

                  Repeater {
                    model: monRow.modelData.workspaces

                    // Workspace cell = mini-map of its windows.
                    Rectangle {
                      id: cell
                      required property var modelData
                      readonly property bool isSelected: modelData.id === root.selectedId
                      width: 156
                      height: 96
                      radius: 6
                      color: modelData.focused ? root.selBackground : "transparent"
                      border.width: isSelected ? 3 : (modelData.focused ? 2 : 1)
                      border.color: isSelected ? root.foreground
                                               : (modelData.focused ? root.selBackground : root.borderColor)
                      opacity: (modelData.occupied || modelData.focused) ? 1.0 : 0.45
                      clip: true

                      readonly property int inset: 6
                      readonly property real mmW: width - inset * 2
                      readonly property real mmH: height - inset * 2
                      readonly property real monW: monRow.modelData.monW
                      readonly property real monH: monRow.modelData.monH
                      readonly property real k: Math.min(mmW / monW, mmH / monH)
                      readonly property real offX: inset + (mmW - monW * k) / 2
                      readonly property real offY: inset + (mmH - monH * k) / 2

                      Text {
                        anchors.centerIn: parent
                        text: cell.modelData.id === 10 ? "0" : String(cell.modelData.id)
                        color: cell.modelData.focused ? root.selText : root.foreground
                        opacity: cell.modelData.windows.length > 0 ? 0.22 : 0.85
                        font.pixelSize: 22
                      }

                      Repeater {
                        model: cell.modelData.windows

                        Rectangle {
                          required property var modelData
                          readonly property string iconUrl:
                            Quickshell.iconPath(String(modelData.cls).toLowerCase(), true)
                          x: cell.offX + (modelData.ax - monRow.modelData.monX) * cell.k
                          y: cell.offY + (modelData.ay - monRow.modelData.monY) * cell.k
                          width: Math.max(10, modelData.sw * cell.k)
                          height: Math.max(8, modelData.sh * cell.k)
                          radius: 3
                          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                          border.width: 1
                          border.color: root.borderColor

                          Image {
                            anchors.centerIn: parent
                            width: Math.min(22, parent.width * 0.6)
                            height: width
                            fillMode: Image.PreserveAspectFit
                            visible: parent.iconUrl.length > 0 && status === Image.Ready
                            source: parent.iconUrl
                            sourceSize.width: width * Screen.devicePixelRatio
                            sourceSize.height: height * Screen.devicePixelRatio
                          }
                          Text {
                            anchors.centerIn: parent
                            visible: parent.iconUrl.length === 0
                            text: String(parent.modelData.cls).substring(0, 1).toUpperCase()
                            color: root.foreground
                            font.pixelSize: Math.min(16, parent.height * 0.6)
                          }
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                          for (var i = 0; i < root.cells.length; i++)
                            if (root.cells[i].id === cell.modelData.id) { root.selectedIndex = i; break }
                        }
                        onClicked: root.jump(cell.modelData.id)
                      }
                    }
                  }
                }
              }
            }
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "1–0 jump · arrows move · Enter select · Esc close"
          color: root.foreground
          opacity: 0.5
          font.pixelSize: 11
        }
      }
    }
  }
}
