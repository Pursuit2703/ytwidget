import QtQuick
import qs.Commons

// A section heading at reading size: "Up next  14 songs · 1 h 12 min".
// Sentence case and normal tracking, not small spaced capitals.
Item {
  id: root

  property string title: ""
  property string detail: ""
  property color foreground: Color.foreground

  implicitHeight: Math.max(titleText.implicitHeight, Style.space(28))
  implicitWidth: titleText.implicitWidth + detailText.implicitWidth + Style.space(10)

  Text {
    id: titleText
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    text: root.title
    color: root.foreground
    font.family: Style.font.family
    font.bold: true
    font.pixelSize: Style.font.body + 1
  }
  Text {
    id: detailText
    anchors.left: titleText.right
    anchors.leftMargin: Style.space(10)
    anchors.right: parent.right
    anchors.baseline: titleText.baseline
    text: root.detail
    color: Qt.darker(root.foreground, 1.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
