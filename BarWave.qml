import QtQuick
import qs.Commons

// Compact waveform for the bar chip. Bars grow from the centre outwards
// (mirrored) so it reads as a waveform rather than an equalizer, and they
// keep a thin baseline when silent so the chip never looks broken.
//
// Deliberately rectangles rather than a Canvas/Shape sine: this sits on a
// bar that is on screen permanently, and animating rectangle heights is
// cheap for the scene graph, whereas repainting a canvas ~43 times a second
// forever is not.
Item {
  id: root

  property var levels: []
  property color color: Color.foreground
  // One bar per band, 1:1. The backend emits 16 logarithmically spaced bands
  // (see backend/spectrum.py), so every bar is a real measurement rather than
  // an interpolation between two of them — which is what keeps the row
  // reading as a spectrum instead of wobbling as one blob.
  property int bars: 16
  property real barWidth: Math.max(2, Style.space(3))
  property real gap: Math.max(1, Style.spaceReal(1.2))
  property real maxHeight: Style.space(18)

  implicitWidth: bars * barWidth + Math.max(0, bars - 1) * gap
  implicitHeight: maxHeight

  // Bars and bands are the same count, so this is a straight lookup. It stays
  // written as a span so a different band count still maps sensibly.
  //
  // Nothing here animates on a timer: a bar's height is its band's level and
  // nothing else. The attack, the decay and the sensitivity all live in the
  // backend's cava-style smoothing, which is driven by the audio itself.
  function levelAt(index) {
    var source = root.levels
    if (!source || source.length === 0) return 0
    var span = source.length / root.bars
    var lo = Math.floor(index * span)
    var hi = Math.max(lo + 1, Math.floor((index + 1) * span))
    var peak = 0
    for (var i = lo; i < hi && i < source.length; i++) {
      var v = Number(source[i])
      if (isFinite(v) && v > peak) peak = v
    }
    return Math.max(0, Math.min(1, peak))
  }

  Row {
    anchors.centerIn: parent
    spacing: root.gap

    Repeater {
      model: root.bars

      Item {
        required property int index
        width: root.barWidth
        height: root.maxHeight

        Rectangle {
          anchors.centerIn: parent
          width: parent.width
          radius: width / 2
          color: root.color
          // Never fully collapse — a thin centre line is the resting state.
          height: Math.max(root.barWidth, root.maxHeight * root.levelAt(index))
          opacity: 0.55 + 0.45 * root.levelAt(index)

          Behavior on height {
            NumberAnimation { duration: 70; easing.type: Easing.OutQuad }
          }
          Behavior on opacity {
            NumberAnimation { duration: 70 }
          }
        }
      }
    }
  }
}
