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
  property int bars: 9
  property real barWidth: Math.max(2, Style.space(2))
  property real gap: Math.max(1, Style.space(2))
  property real maxHeight: Style.space(14)

  implicitWidth: bars * barWidth + Math.max(0, bars - 1) * gap
  implicitHeight: maxHeight

  // Map our bar count across however many bands the backend sends (10),
  // weighting toward the low/mid bands where music actually lives so the
  // chip looks alive instead of mostly flat.
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
