import QtQuick
import qs.Commons

// The spectrum that fills the empty stretches of the bar.
//
// This cannot be a bar widget: the bar lays its sections out as
// leftHost/rightHost at z:10 inside one Item, so a module only ever occupies
// its own section, never the space between them. It is a separate layer-shell
// surface instead (see BarWidget.qml), on WlrLayer.Bottom — above the
// wallpaper, below the bar. The bar reserves exclusive space, so no ordinary
// window is ever in that strip, and the bar is transparent, so this shows
// through wherever the bar itself draws nothing.
Item {
  id: root

  property var levels: []
  property color color: Color.foreground
  property real heightFraction: 0.40

  // Screen-space [start, end] ranges the bar leaves empty, measured by
  // BarWidget from the bar's own scene graph. A bar outside every range is
  // simply not drawn, so the spectrum fills the gaps and stops at the text
  // rather than running underneath it.
  property var gaps: []

  function inGap(centre) {
    var g = root.gaps
    if (!g || g.length === 0) return false
    for (var i = 0; i < g.length; i++) {
      if (centre >= g[i][0] && centre <= g[i][1]) return true
    }
    return false
  }

  // Fixed count, deliberately. Deriving it from width means the Repeater
  // regenerates its whole delegate set the moment the surface is resized —
  // and regenerating a Repeater from inside a visibility change is what
  // segfaulted the shell. Bars are positioned as a fraction of the width
  // instead, so a resize moves them and never rebuilds them.
  readonly property int bars: 160
  readonly property real pitch: width / bars
  readonly property real barWidth: Math.max(1, pitch * 0.45)
  readonly property real maxBarHeight: Math.max(1, height * heightFraction)

  // Below 1 lifts the quiet bands without touching the loud ones. The chip
  // does not need this — it has 17px of height and only 16 bars — but this
  // strip is shorter still, and typical band values sit between 0.08 and 0.4,
  // which lands almost every bar on the 1px floor if taken literally.
  property real curve: 0.6

  function bandAt(i) {
    var source = root.levels
    if (!source || i < 0 || i >= source.length) return 0
    var v = Number(source[i])
    if (!isFinite(v) || v <= 0) return 0
    return Math.pow(Math.max(0, Math.min(1, v)), root.curve)
  }

  // The spectrum is tiled across the width rather than stretched over it.
  // Stretching 16 bands over a whole screen puts neighbouring bars a fraction
  // of a band apart, so the row slides around as a single smooth line instead
  // of reading as bars. Tiling keeps every bar a full band away from the next,
  // which is what makes it look like a spectrum.
  //
  // Alternate tiles run backwards, so the pattern turns around at each repeat
  // instead of snapping back to the low end and leaving a visible seam.
  function bandFor(index) {
    var n = root.levels ? root.levels.length : 0
    if (n <= 1) return 0
    var cycle = n * 2 - 2
    var k = index % cycle
    return k < n ? k : cycle - k
  }

  Item {
    anchors.fill: parent

    Repeater {
      model: root.bars

      Rectangle {
        required property int index
        readonly property real centre: index * root.pitch + root.barWidth / 2
        // Hidden, not resized: the Repeater keeps the same delegates either
        // way, which is what keeps it away from the regenerate path that
        // crashed the shell.
        visible: root.inGap(centre)
        x: index * root.pitch
        // Grows up from the bottom edge, away from the bar's own text.
        y: parent.height - height
        width: root.barWidth
        height: Math.max(1, root.maxBarHeight * root.bandAt(root.bandFor(index)))
        radius: width / 2
        color: root.color

        Behavior on height {
          NumberAnimation { duration: 70; easing.type: Easing.OutQuad }
        }
      }
    }
  }
}
