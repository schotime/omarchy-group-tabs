import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// Chrome-style tabs for Hyprland window groups.
//
// Hyprland's groupbar can't draw icons, so ~/.config/hypr/looknfeel.lua keeps
// it on but fully transparent, only to reserve the strip above each group.
// This service paints the tabs over that strip in a layer surface, one per
// visible group, and handles the strip's input itself, since the groupbar
// always splits the full width evenly and these tabs don't: they're capped at
// maxTabWidth and shrink evenly once they no longer fit, as in Chrome.
// Click focuses a tab, middle-click closes it, the wheel cycles tabs, and
// dragging a tab sideways reorders it.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Must match group.groupbar.height and gaps_out in looknfeel.lua.
  readonly property int stripHeight: 30
  readonly property int stripGap: 0
  // Space between the strip's edge and the highlighted tab.
  readonly property int tabInset: 4
  // Radius of the curves where the active tab flares out into the window.
  readonly property int tabFlare: 8
  readonly property int iconSize: 16
  // Widest a tab gets; past this, tabs shrink evenly to share the strip.
  readonly property int maxTabWidth: 300

  // Lua dispatch, as hyprctl dispatch takes it in Hyprland 0.56.
  function dispatch(lua) {
    Hyprland.dispatch(lua)
    debounce.restart()
  }
  function windowRef(address) {
    return "{ window = \"address:" + String(address).replace(/[^0-9a-fA-Fx]/g, "") + "\" }"
  }
  // Focusing a window warps the cursor onto it, which a click on its tab
  // shouldn't. Turn warps off just for this focus, then select the same tab
  // again as the dispatch's own (cursor-neutral) action. Assumes warps are
  // normally on (cursor:no_warps = false).
  function focusTab(address, index) {
    dispatch("(function() hl.config({ cursor = { no_warps = true } }); "
      + "hl.dispatch(hl.dsp.focus(" + windowRef(address) + ")); "
      + "hl.config({ cursor = { no_warps = false } }); "
      // group.active counts tabs from 1, Lua style.
      + "return hl.dsp.group.active({ index = " + (Math.max(0, Math.floor(Number(index) || 0)) + 1) + " }) end)()")
  }
  function closeTab(address) { dispatch("hl.dsp.window.close(" + windowRef(address) + ")") }
  function moveTab(forward) {
    dispatch("hl.dsp.group.move_window({ forward = " + (forward ? "true" : "false") + " })")
  }
  // The window corner shape, read back from Hyprland so the strip and the
  // active tab round exactly like the window below them.
  property int windowRounding: 12
  property real roundingPower: 2.0

  // Every group currently on screen, keyed by its first member's address.
  property var groups: ({})
  // Just the keys, reassigned only when the set of groups changes, so the
  // per-group windows aren't torn down and rebuilt on every refresh.
  property var groupKeys: []

  readonly property var refreshEvents: [
    "openwindow", "closewindow", "movewindowv2", "changefloatingmode", "fullscreen",
    "activewindowv2", "togglegroup", "moveintogroup", "moveoutofgroup", "lockgroups",
    "windowtitlev2", "workspacev2", "focusedmonv2", "activespecialv2", "moveworkspacev2",
    "monitoraddedv2", "monitorremovedv2", "configreloaded"
  ]

  function refresh() {
    if (snapshotProc.running) {
      snapshotProc.again = true
      return
    }
    snapshotProc.running = true
  }

  function apply(text) {
    var data
    try { data = JSON.parse(String(text || "")) } catch (e) { return }
    if (!data || !Array.isArray(data.clients) || !Array.isArray(data.monitors)) return

    // A monitor shows its special workspace over the regular one when open.
    var monitors = {}
    var shown = {}
    for (var m = 0; m < data.monitors.length; m++) {
      var mon = data.monitors[m]
      monitors[mon.id] = mon
      var special = mon.specialWorkspace && mon.specialWorkspace.id ? mon.specialWorkspace.id : 0
      shown[special !== 0 ? special : (mon.activeWorkspace ? mon.activeWorkspace.id : -1)] = mon.id
    }

    var byAddress = {}
    var fullscreenOn = {}
    for (var i = 0; i < data.clients.length; i++) {
      var c = data.clients[i]
      byAddress[c.address] = c
      if (c.fullscreen === 2 && c.workspace) fullscreenOn[c.workspace.id] = true
    }

    var next = {}
    var keys = []
    for (var j = 0; j < data.clients.length; j++) {
      var client = data.clients[j]
      var members = client.grouped || []
      // One entry per group: build it from the tab that's on screen.
      if (members.length < 2 || client.visible === false || client.hidden) continue
      var ws = client.workspace ? client.workspace.id : -1
      if (shown[ws] === undefined || fullscreenOn[ws]) continue
      var monitor = monitors[shown[ws]]
      if (!monitor) continue

      var tabs = []
      var groupFocused = false
      for (var k = 0; k < members.length; k++) {
        var member = byAddress[members[k]]
        if (!member) continue
        if (member.focusHistoryID === 0) groupFocused = true
        tabs.push({
          address: member.address,
          title: String(member.title || member.class || ""),
          appClass: String(member.class || ""),
          active: member.address === client.address
        })
      }

      var key = members[0]
      keys.push(key)
      next[key] = {
        monitor: String(monitor.name),
        x: client.at[0] - monitor.x,
        y: client.at[1] - monitor.y - root.stripGap - root.stripHeight,
        width: client.size[0],
        focused: groupFocused,
        tabs: tabs
      }
    }

    root.groups = next
    keys.sort()
    if (keys.join("|") !== root.groupKeys.join("|")) root.groupKeys = keys
    poll.running = keys.length > 0
  }

  Process {
    id: snapshotProc
    property bool again: false
    command: ["bash", "-c",
      "printf '{\"clients\":'; hyprctl -j clients; printf ',\"monitors\":'; hyprctl -j monitors; printf '}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    onExited: {
      if (!again) return
      again = false
      debounce.restart()
    }
  }

  Process {
    id: roundingProc
    command: ["bash", "-c",
      "printf '['; hyprctl -j getoption decoration:rounding; printf ','; hyprctl -j getoption decoration:rounding_power; printf ']'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var options = JSON.parse(text)
          root.windowRounding = Math.max(0, Number(options[0].int) || 0)
          root.roundingPower = Math.max(1, Number(options[1].float) || 2)
        } catch (e) {}
      }
    }
  }

  Timer {
    id: debounce
    interval: 30
    onTriggered: root.refresh()
  }

  // Resizing a split or nudging a window emits no event, so while any group
  // is on screen look again now and then to keep the strip on its window.
  Timer {
    id: poll
    interval: 1000
    repeat: true
    onTriggered: root.refresh()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event) return
      var name = String(event.name)
      if (name === "configreloaded") roundingProc.running = true
      if (root.refreshEvents.indexOf(name) !== -1) debounce.restart()
    }
  }

  Component.onCompleted: {
    roundingProc.running = true
    root.refresh()
  }

  // ------------------------------------------------------------------ icons

  function classSegments(value) {
    return String(value || "").toLowerCase().split(".").filter(function(s) { return s.length > 0 })
  }

  function segmentsContain(haystack, needle) {
    if (needle.length === 0 || needle.length > haystack.length) return false
    for (var start = 0; start <= haystack.length - needle.length; start++) {
      var match = true
      for (var j = 0; j < needle.length; j++) {
        if (haystack[start + j] !== needle[j]) { match = false; break }
      }
      if (match) return true
    }
    return false
  }

  function webappHostname(entry) {
    var exec = String(entry.execString || "")
    var execMatch = exec.match(/omarchy-launch-(?:or-focus-)?webapp\s+"?(https?:\/\/[^\s"]+)/)
    if (!execMatch) return ""
    var hostMatch = execMatch[1].match(/^https?:\/\/([^\/]+)/)
    if (!hostMatch) return ""
    return hostMatch[1].replace(/:\d+$/, "").replace(/^www\./, "").toLowerCase()
  }

  // Same matching as the workspaces-icons widget, so a tab shows the icon the
  // launcher and the bar show for that window.
  function findDesktopEntry(appId) {
    if (!appId) return null
    var lower = appId.toLowerCase()
    var appSegments = classSegments(appId)
    var values = DesktopEntries.applications.values || []
    var i, startupClass, hostname
    for (i = 0; i < values.length; i++) {
      startupClass = String(values[i].startupClass || "").toLowerCase()
      if (startupClass !== "" && startupClass === lower) return values[i]
    }
    for (i = 0; i < values.length; i++) {
      startupClass = String(values[i].startupClass || "")
      if (startupClass === "") continue
      var startupSegments = classSegments(startupClass)
      if (segmentsContain(appSegments, startupSegments) || segmentsContain(startupSegments, appSegments))
        return values[i]
    }
    for (i = 0; i < values.length; i++) {
      hostname = webappHostname(values[i])
      if (hostname !== "" && lower.indexOf(hostname) !== -1) return values[i]
    }
    return DesktopEntries.byId(appId) || DesktopEntries.heuristicLookup(appId) || null
  }

  readonly property string agentIcon: "/usr/share/omarchy/shell/plugins/agents/assets/claude.svg"

  function iconFor(appClass) {
    if (appClass === "org.omarchy.agent") return Util.fileUrl(root.agentIcon)
    var lookup = appClass.indexOf("org.omarchy.") === 0 ? appClass.substr(12) : appClass
    var entry = root.findDesktopEntry(lookup)
    var name = (entry && entry.icon) || lookup
    return Quickshell.iconPath(name, "application-x-executable")
  }

  // ----------------------------------------------------------------- shape

  // A point on one of Hyprland's window corners: |dx|^p + |dy|^p = r^p, p being
  // decoration:rounding_power. A plain Rectangle radius is only the p = 2
  // circle, which wouldn't match the windows.
  function cornerPoint(cx, cy, r, p, t) {
    var e = 2 / Math.max(1, p)
    var cos = Math.cos(t), sin = Math.sin(t)
    return Qt.point(cx + r * Math.sign(cos) * Math.pow(Math.abs(cos), e),
                    cy + r * Math.sign(sin) * Math.pow(Math.abs(sin), e))
  }

  readonly property int cornerSteps: 14
  // How far the strip and corner fills reach over the window's edge. With
  // fractional monitor scaling the edges land between pixels, and without the
  // overlap a hairline of wallpaper shows through the join.
  readonly property real seamOverlap: 1.5

  // Outline of a rectangle with corners on that curve. `radii` is
  // [topLeft, topRight, bottomRight, bottomLeft].
  function roundedOutline(x, y, w, h, radii, p) {
    var points = []
    var limit = Math.min(w / 2, h / 2)
    var r = radii.map(function(v) { return Math.max(0, Math.min(v, limit)) })
    // Corner centres, walked clockwise from the top left (screen coordinates).
    var corners = [
      { cx: x + r[0], cy: y + r[0], r: r[0], from: Math.PI },
      { cx: x + w - r[1], cy: y + r[1], r: r[1], from: 1.5 * Math.PI },
      { cx: x + w - r[2], cy: y + h - r[2], r: r[2], from: 0 },
      { cx: x + r[3], cy: y + h - r[3], r: r[3], from: 0.5 * Math.PI }
    ]
    for (var c = 0; c < corners.length; c++) {
      var steps = corners[c].r > 0 ? root.cornerSteps : 0
      for (var i = 0; i <= steps; i++) {
        var t = corners[c].from + (i / Math.max(1, steps)) * (Math.PI / 2)
        points.push(root.cornerPoint(corners[c].cx, corners[c].cy, corners[c].r, p, t))
      }
    }
    points.push(points[0])
    return points
  }

  // The sliver outside a window's rounded top corner, between the corner's
  // square and its curve. The window draws nothing there, so filling it in the
  // strip's colour joins strip and window without covering any of the window.
  // `left` picks the corner; (x, y) is the window's top-left/top-right point.
  function cornerFill(x, y, r, p, left) {
    var dir = left ? 1 : -1
    var cx = x + dir * r
    var cy = y + r
    // A slightly smaller curve on the same centre, so the fill tucks just
    // inside the window's anti-aliased edge.
    var inner = Math.max(0, r - root.seamOverlap)
    var points = [Qt.point(x, y), Qt.point(cx, y)]
    for (var i = 0; i <= root.cornerSteps; i++) {
      var f = i / root.cornerSteps
      // Left: from the top of the curve round to its side; right mirrored.
      var t = left ? 1.5 * Math.PI - f * (Math.PI / 2) : 1.5 * Math.PI + f * (Math.PI / 2)
      points.push(root.cornerPoint(cx, cy, inner, p, t))
    }
    points.push(Qt.point(x, cy))
    points.push(Qt.point(x, y))
    return points
  }

  // Outline of a Chrome-style tab spanning x0..x1, its top at `top` with
  // corners of radius `rt` on the window curve, and concave flares of radius
  // `fr` where it meets the strip's bottom edge `h`, then down to `bottom`.
  function chromeTab(x0, x1, top, h, bottom, fr, rt, p) {
    rt = Math.max(0, Math.min(rt, (x1 - x0) / 2, (h - top) / 2))
    var n = root.cornerSteps
    var points = [Qt.point(x0 - fr, bottom), Qt.point(x0 - fr, h)]
    var i, f
    // Left flare: from the strip's bottom edge up to the tab's side.
    for (i = 0; i <= n; i++) {
      f = i / n
      points.push(root.cornerPoint(x0 - fr, h - fr, fr, 2, 0.5 * Math.PI - f * 0.5 * Math.PI))
    }
    // Top corners on the window curve.
    for (i = 0; i <= n; i++) {
      f = i / n
      points.push(root.cornerPoint(x0 + rt, top + rt, rt, p, Math.PI + f * 0.5 * Math.PI))
    }
    for (i = 0; i <= n; i++) {
      f = i / n
      points.push(root.cornerPoint(x1 - rt, top + rt, rt, p, 1.5 * Math.PI + f * 0.5 * Math.PI))
    }
    // Right flare: down the side and out onto the strip's bottom edge.
    for (i = 0; i <= n; i++) {
      f = i / n
      points.push(root.cornerPoint(x1 + fr, h - fr, fr, 2, Math.PI - f * 0.5 * Math.PI))
    }
    points.push(Qt.point(x1 + fr, bottom))
    points.push(Qt.point(x0 - fr, bottom))
    return points
  }

  // ------------------------------------------------------------------ strips

  Instantiator {
    model: root.groupKeys

    delegate: PanelWindow {
      id: strip

      required property string modelData
      readonly property var group: root.groups[modelData] || null
      readonly property var tabs: group ? group.tabs : []
      readonly property real tabWidth: tabs.length > 0 ? Math.min(root.maxTabWidth, width / tabs.length) : width
      // Whether the tabs reach the strip's right edge, so the last one ends
      // in the strip's corner rather than short of it.
      readonly property bool tabsFill: tabs.length * tabWidth >= width - 0.5
      readonly property real tabsWidth: tabsFill ? width : tabs.length * tabWidth
      // Behind the inactive tabs: a see-through tint of the window colour, so
      // the wallpaper shows through but the titles stay readable.
      readonly property color frameColor: Util.alpha(Color.background, 0.5)
      readonly property real frameOpacity: group && group.focused ? 1 : 0.85
      readonly property color tabColor: Util.alpha(Color.background, 0.97)
      readonly property int activeIndex: {
        for (var i = 0; i < tabs.length; i++) if (tabs[i].active) return i
        return -1
      }

      readonly property var targetScreen: {
        var screens = Quickshell.screens
        for (var i = 0; i < screens.length; i++)
          if (group && screens[i].name === group.monitor) return screens[i]
        return null
      }
      screen: targetScreen
      visible: group !== null && targetScreen !== null

      WlrLayershell.namespace: "omarchy-group-tabs"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true; left: true }
      margins {
        left: group ? Math.round(group.x) : 0
        top: group ? Math.round(group.y) : 0
      }
      implicitWidth: group ? Math.max(1, Math.round(group.width)) : 1
      // The strip, plus a band over the window's top corners for the fills.
      implicitHeight: root.stripHeight + root.windowRounding
      color: "transparent"
      // Take input over the strip only, never over the window below it.
      mask: Region { item: inputArea }

      // The window under the strip animates into place; the strip can only
      // jump. Hide it while the window moves and fade it in once it's there.
      property string placement: group ? [group.monitor, group.x, group.y, group.width].join(":") : ""
      onPlacementChanged: {
        content.opacity = 0
        settle.restart()
      }
      Timer {
        id: settle
        interval: Style.duration(220)
        onTriggered: content.opacity = 1
      }

      Item {
        id: content
        anchors.fill: parent
        opacity: 0
        Behavior on opacity {
          enabled: content.opacity < 1
          NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
        }

        // The strip, attached to the window like a title bar: rounded on
        // top, square below, with the window's top corners filled in so the
        // two read as one piece.
        Shape {
          id: stripShape
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          opacity: strip.frameOpacity
          readonly property color fill: strip.frameColor
          ShapePath {
            strokeWidth: -1
            fillColor: stripShape.fill
            PathPolyline {
              path: root.roundedOutline(0, 0, strip.width, root.stripHeight + root.seamOverlap,
                [root.windowRounding, root.windowRounding, 0, 0], root.roundingPower)
            }
          }
        }

        // The active tab, Chrome style: filled with the window's own colour,
        // rounded on top and flaring out at the bottom into the window, so it
        // reads as part of the window rather than of the strip. Clipped so a
        // flare at either end stops at the strip's edge.
        Shape {
          id: activeTab
          visible: strip.activeIndex >= 0
          anchors.fill: parent
          clip: true
          preferredRendererType: Shape.CurveRenderer
          // Full strip height. An end tab runs right to the strip's edge so its
          // outer corner is the strip's own corner; elsewhere it's inset a
          // little to leave room for the flares.
          readonly property real x0: strip.activeIndex === 0 ? 0
            : Math.round(strip.activeIndex * strip.tabWidth) + root.tabInset
          readonly property real x1: strip.activeIndex === strip.tabs.length - 1 && strip.tabsFill ? strip.width
            : Math.round((strip.activeIndex + 1) * strip.tabWidth) - root.tabInset
          ShapePath {
            strokeWidth: -1
            fillColor: strip.tabColor
            PathPolyline {
              path: root.chromeTab(activeTab.x0, activeTab.x1, 0, root.stripHeight,
                root.stripHeight + root.seamOverlap, root.tabFlare, root.windowRounding,
                root.roundingPower)
            }
          }
        }

        // The window's top corners, filled in so strip and window read as one
        // piece. Under an end tab they take the tab's colour, or the lighter
        // frame would show as a notch below it.
        Shape {
          id: cornerFills
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          readonly property color frame: Util.alpha(strip.frameColor, strip.frameColor.a * strip.frameOpacity)
          ShapePath {
            strokeWidth: -1
            fillColor: strip.activeIndex === 0 ? strip.tabColor : cornerFills.frame
            PathPolyline {
              path: root.cornerFill(0, root.stripHeight, root.windowRounding, root.roundingPower, true)
            }
          }
          ShapePath {
            strokeWidth: -1
            fillColor: strip.activeIndex === strip.tabs.length - 1 && strip.tabsFill ? strip.tabColor : cornerFills.frame
            PathPolyline {
              path: root.cornerFill(strip.width, root.stripHeight, root.windowRounding, root.roundingPower, false)
            }
          }
        }

        Repeater {
          model: strip.tabs

          Item {
            id: tab
            required property var modelData
            required property int index

            x: Math.round(index * strip.tabWidth)
            y: 0
            width: (index === strip.tabs.length - 1 && strip.tabsFill ? strip.width
              : Math.round((index + 1) * strip.tabWidth)) - x
            height: root.stripHeight
            readonly property bool hovered: inputArea.hoverIndex === index

            // Hovering a background tab lifts it a little, as in Chrome.
            Rectangle {
              visible: tab.hovered && !tab.modelData.active
              anchors.fill: parent
              anchors.topMargin: root.tabInset
              anchors.bottomMargin: root.tabInset
              anchors.leftMargin: root.tabInset
              anchors.rightMargin: root.tabInset
              radius: 7
              color: Util.alpha(Color.foreground, 0.08)
            }

            // Thin divider between two background tabs, as in Chrome.
            Rectangle {
              visible: tab.index > 0 && !tab.modelData.active && tab.index - 1 !== strip.activeIndex
              x: 0
              anchors.verticalCenter: parent.verticalCenter
              width: 1
              height: parent.height * 0.55
              color: Util.alpha(Color.foreground, 0.18)
            }

            // Closing divider after the last tab when the tabs stop short.
            Rectangle {
              visible: tab.index === strip.tabs.length - 1 && !strip.tabsFill && !tab.modelData.active
              x: parent.width - 1
              anchors.verticalCenter: parent.verticalCenter
              width: 1
              height: parent.height * 0.55
              color: Util.alpha(Color.foreground, 0.18)
            }

            Row {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: root.tabInset + 10
              anchors.rightMargin: root.tabInset + 10
              anchors.verticalCenter: parent.verticalCenter
              spacing: 8

              Image {
                id: icon
                anchors.verticalCenter: parent.verticalCenter
                width: root.iconSize
                height: root.iconSize
                sourceSize.width: root.iconSize * 2
                sourceSize.height: root.iconSize * 2
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                asynchronous: true
                source: root.iconFor(tab.modelData.appClass)
                opacity: tab.modelData.active ? 1 : 0.75
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - icon.width - parent.spacing
                textFormat: Text.PlainText
                text: tab.modelData.title
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: Style.fontFamily
                font.pixelSize: 12
                font.weight: tab.modelData.active ? Font.DemiBold : Font.Normal
                color: tab.modelData.active ? Color.foreground : Util.alpha(Color.foreground, 0.62)
              }
            }
          }
        }

        MouseArea {
          id: inputArea
          x: 0
          y: 0
          width: strip.width
          height: root.stripHeight
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton

          readonly property int hoverIndex: containsMouse ? indexAt(mouseX) : -1
          // The tab being dragged, by where it sits now.
          property int dragIndex: -1

          function indexAt(x) {
            if (x < 0 || x >= strip.tabsWidth || strip.tabs.length === 0) return -1
            return Math.min(strip.tabs.length - 1, Math.floor(x / strip.tabWidth))
          }

          onPressed: function(mouse) {
            var i = indexAt(mouse.x)
            if (mouse.button !== Qt.LeftButton) return
            if (i < 0) {
              // Empty strip: just focus the group's current tab.
              if (strip.activeIndex >= 0) root.focusTab(strip.tabs[strip.activeIndex].address, strip.activeIndex)
              return
            }
            dragIndex = i
            root.focusTab(strip.tabs[i].address, i)
          }

          onPositionChanged: function(mouse) {
            if (!pressed || dragIndex < 0) return
            var x = Math.max(0, Math.min(mouse.x, strip.tabsWidth - 1))
            var target = indexAt(x)
            if (target < 0 || target === dragIndex) return
            var forward = target > dragIndex
            for (var n = Math.abs(target - dragIndex); n > 0; n--) root.moveTab(forward)
            dragIndex = target
          }

          onReleased: function(mouse) {
            if (mouse.button === Qt.MiddleButton) {
              var i = indexAt(mouse.x)
              if (i >= 0) root.closeTab(strip.tabs[i].address)
            }
            dragIndex = -1
          }
          onCanceled: dragIndex = -1

          onWheel: function(wheel) {
            var n = strip.tabs.length
            if (n < 2 || strip.activeIndex < 0) return
            var step = wheel.angleDelta.y < 0 || wheel.angleDelta.x < 0 ? 1 : -1
            var next = (strip.activeIndex + step + n) % n
            root.focusTab(strip.tabs[next].address, next)
          }
        }
      }
    }
  }
}
