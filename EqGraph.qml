import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// The equaliser as one control. Each of the ten bands is a column: the live
// level of that part of the sound fills it softly from the bottom, a thin
// track runs through it, and a round handle sits at the band's gain. A smooth
// curve joins the handles so the shape of the sound is visible at a glance.
// Presets are chips above; dragging any handle turns the preset into Custom.
//
// Drag a handle for ±12 dB (half-dB steps); double-click resets that band.
Item {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  // Colour under the chips' right edge, so the scrolling row fades out into
  // whatever the control sits on.
  property color fadeTo: Color.background
  // compact: one scrolling row of chips, no dB scale (mini card).
  property bool compact: false

  readonly property var bands: root.service ? root.service.eqBands : []
  readonly property string presetName: root.service ? root.service.eqPreset : "Flat"
  readonly property var presets: root.service ? root.service.eqPresets : []
  readonly property var labels: root.service ? root.service.eqLabels : []
  readonly property var levels: root.service ? root.service.spectrumBands : []
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property real handleSize: compact ? Style.space(14) : Style.space(20)

  property var previewBands: []
  property int activeBand: -1
  property int pendingIndex: -1
  property real pendingGain: 0

  function gainAt(i) {
    if (previewBands.length === 10) return Number(previewBands[i]) || 0
    if (!bands || i >= bands.length) return 0
    return Number(bands[i]) || 0
  }

  // The visualiser has more bands than the equaliser; sample it evenly so
  // each column shows the part of the sound that band works on.
  function levelAt(i) {
    var n = levels ? levels.length : 0
    if (n === 0) return 0
    var pos = i * (n - 1) / 9
    var lo = Math.floor(pos), hi = Math.min(n - 1, lo + 1), t = pos - lo
    var v = (Number(levels[lo]) || 0) * (1 - t) + (Number(levels[hi]) || 0) * t
    return Math.max(0, Math.min(1, v))
  }

  function formatGain(g) {
    if (Math.abs(g) < 0.05) return "0 dB"
    return (g > 0 ? "+" : "") + (Math.round(g * 2) / 2) + " dB"
  }

  function applyBand(index, gain) {
    var next = []
    for (var i = 0; i < 10; i++) next.push(gainAt(i))
    next[index] = gain
    previewBands = next
    pendingIndex = index
    pendingGain = gain
    if (!applyTimer.running) applyTimer.start()
  }

  function flushBand() {
    applyTimer.stop()
    if (service && pendingIndex >= 0) service.setEqBand(pendingIndex, pendingGain)
    pendingIndex = -1
  }

  // mpv rebuilds its filter on every change; ~12 updates a second while
  // dragging is smooth to the ear without hammering it.
  Timer {
    id: applyTimer
    interval: 80
    onTriggered: root.flushBand()
  }
  // Keep the dragged shape until the backend reports it back, so the handle
  // does not jump to the old value in between.
  onBandsChanged: if (activeBand < 0 && pendingIndex < 0) previewBands = []

  implicitHeight: compact ? Style.space(190) : Style.space(300)

  // ---- preset chips
  Item {
    id: chipArea
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: root.compact ? Style.space(28) : chipFlow.implicitHeight

    Flickable {
      id: chipScroll
      anchors.fill: parent
      visible: root.compact
      contentWidth: chipRow.implicitWidth
      flickableDirection: Flickable.HorizontalFlick
      boundsBehavior: Flickable.StopAtBounds
      clip: true
      Row {
        id: chipRow
        spacing: Style.space(6)
        Repeater { model: root.compact ? root.presets.concat(root.presetName === "Custom" ? ["Custom"] : []) : []; delegate: chip }
      }
      // Wheel scrolls the row sideways.
      WheelHandler {
        onWheel: function(event) {
          var d = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
          chipScroll.contentX = Math.max(0, Math.min(chipScroll.contentWidth - chipScroll.width,
            chipScroll.contentX - d))
        }
      }
    }
    Rectangle {
      visible: root.compact && chipScroll.contentX + chipScroll.width < chipScroll.contentWidth - 1
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: Style.space(36)
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: Qt.rgba(root.fadeTo.r, root.fadeTo.g, root.fadeTo.b, 0) }
        GradientStop { position: 1; color: root.fadeTo }
      }
    }

    Flow {
      id: chipFlow
      anchors.left: parent.left
      anchors.right: parent.right
      visible: !root.compact
      spacing: Style.space(8)
      Repeater { model: root.compact ? [] : root.presets.concat(root.presetName === "Custom" ? ["Custom"] : []); delegate: chip }
    }
  }

  Component {
    id: chip
    Rectangle {
      required property var modelData
      readonly property bool active: modelData === root.presetName
      readonly property bool custom: modelData === "Custom"
      width: chipLabel.implicitWidth + Style.space(root.compact ? 24 : 28)
      height: Style.space(root.compact ? 28 : 30)
      radius: height / 2
      color: active
        ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.20)
        : (chipMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                                   : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07))
      Text {
        id: chipLabel
        anchors.centerIn: parent
        text: modelData
        color: active ? root.accent : Qt.darker(root.foreground, 1.15)
        font.family: Style.font.family
        font.bold: active
        font.pixelSize: Style.font.caption
      }
      MouseArea {
        id: chipMouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: !custom
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.previewBands = []
          if (root.service) root.service.setEqPreset(modelData)
        }
      }
    }
  }

  // ---- the graph
  Item {
    id: graphArea
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: chipArea.bottom
    anchors.topMargin: Style.space(root.compact ? 10 : 18)
    anchors.bottom: parent.bottom

    readonly property real labelHeight: Style.space(root.compact ? 16 : 22)
    readonly property real scaleWidth: root.compact ? 0 : Style.space(34)

    // dB scale (full player only)
    Column {
      visible: !root.compact
      anchors.left: parent.left
      anchors.top: parent.top
      width: graphArea.scaleWidth - Style.space(8)
      height: plot.height
      Repeater {
        model: ["+12", "+6", "0", "−6", "−12"]
        Text {
          required property var modelData
          required property int index
          width: parent.width
          height: index === 4 ? implicitHeight : (plot.height - implicitHeight) / 4
          horizontalAlignment: Text.AlignRight
          text: modelData
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    Item {
      id: plot
      anchors.left: parent.left
      anchors.leftMargin: graphArea.scaleWidth
      anchors.right: parent.right
      anchors.top: parent.top
      height: parent.height - graphArea.labelHeight

      readonly property real colWidth: width / 10
      readonly property real usable: height / 2 - root.handleSize / 2 - 2

      function yFor(gain) { return height / 2 - (gain / 12) * usable }

      Row {
        anchors.fill: parent
        Repeater {
          model: 10
          delegate: Item {
            id: col
            required property int index
            width: plot.colWidth
            height: plot.height

            readonly property real gain: root.gainAt(index)
            readonly property real level: root.levelAt(index)
            readonly property bool hot: root.activeBand === index || colMouse.containsMouse
            property real peak: 0
            onLevelChanged: if (level > peak) peak = level

            // Peaks fall back slowly, like a meter.
            Timer {
              interval: 60
              repeat: true
              running: col.peak > 0
              onTriggered: col.peak = Math.max(col.level, col.peak - 0.02)
            }

            // live level
            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              width: Math.max(Style.space(6), parent.width - Style.space(root.compact ? 12 : 28))
              height: parent.height * col.level
              radius: Style.space(root.compact ? 6 : 10)
              gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.10) }
                GradientStop { position: 1; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.34) }
              }
              Behavior on height { NumberAnimation { duration: 90 } }
            }
            // peak
            Rectangle {
              visible: col.peak > 0.02
              anchors.horizontalCenter: parent.horizontalCenter
              y: parent.height * (1 - col.peak)
              width: Math.max(Style.space(6), parent.width - Style.space(root.compact ? 12 : 28))
              height: 2
              radius: 1
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.5)
            }
            // track
            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: 2
              radius: 1
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, col.hot ? 0.22 : 0.10)
            }
            // handle
            Rectangle {
              id: handle
              x: (parent.width - width) / 2
              y: plot.yFor(col.gain) - height / 2
              width: root.handleSize * (col.hot ? 1.15 : 1)
              height: width
              radius: width / 2
              color: col.hot ? root.accent : root.foreground
              border.width: Style.space(3)
              border.color: Qt.rgba(root.fadeTo.r, root.fadeTo.g, root.fadeTo.b, 0.9)
              Behavior on y { enabled: root.activeBand !== col.index; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            }
            // value while pointing or dragging
            Text {
              visible: col.hot
              anchors.horizontalCenter: parent.horizontalCenter
              y: Math.max(0, handle.y - height - Style.space(4))
              text: root.formatGain(col.gain)
              color: root.accent
              font.family: Style.font.family
              font.bold: true
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: colMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.SizeVerCursor
              preventStealing: true
              function gainFor(y) {
                var g = (plot.height / 2 - y) / plot.usable * 12
                return Math.round(Math.max(-12, Math.min(12, g)) * 2) / 2
              }
              onPressed: function(mouse) {
                root.activeBand = col.index
                root.applyBand(col.index, gainFor(mouse.y))
              }
              onPositionChanged: function(mouse) {
                if (pressed) root.applyBand(col.index, gainFor(mouse.y))
              }
              onReleased: {
                root.flushBand()
                root.activeBand = -1
              }
              onDoubleClicked: {
                root.applyBand(col.index, 0)
                root.flushBand()
              }
            }
          }
        }
      }

      // 0 dB line and the curve through the handles.
      Canvas {
        id: curve
        anchors.fill: parent
        z: -1
        Connections {
          target: root
          function onBandsChanged() { curve.requestPaint() }
          function onPreviewBandsChanged() { curve.requestPaint() }
          function onAccentChanged() { curve.requestPaint() }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var mid = Math.round(height / 2) + 0.5
          ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
          ctx.lineWidth = 1
          ctx.setLineDash([4, 4])
          ctx.beginPath(); ctx.moveTo(0, mid); ctx.lineTo(width, mid); ctx.stroke()
          ctx.setLineDash([])
          var cw = width / 10
          ctx.strokeStyle = root.accent
          ctx.lineWidth = root.compact ? 2 : 2.5
          ctx.lineCap = "round"
          ctx.beginPath()
          for (var i = 0; i < 10; i++) {
            var x = cw * i + cw / 2, y = plot.yFor(root.gainAt(i))
            if (i === 0) { ctx.moveTo(x, y); continue }
            var px = cw * (i - 1) + cw / 2, py = plot.yFor(root.gainAt(i - 1)), mx = (px + x) / 2
            ctx.bezierCurveTo(mx, py, mx, y, x, y)
          }
          ctx.stroke()
        }
      }
    }

    // band labels
    Row {
      anchors.left: plot.left
      anchors.right: plot.right
      anchors.bottom: parent.bottom
      height: graphArea.labelHeight
      Repeater {
        model: 10
        Text {
          required property int index
          width: plot.colWidth
          height: parent.height
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignBottom
          text: root.labels && index < root.labels.length ? root.labels[index] : ""
          color: root.activeBand === index ? root.accent : root.dim
          font.family: Style.font.family
          font.pixelSize: root.compact ? Style.font.caption - 1 : Style.font.caption
        }
      }
    }
  }
}
