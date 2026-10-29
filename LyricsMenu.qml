import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons

// Where the lyrics come from and which language they show in. Opened from
// the source chip in the full player and the language chip on the mini card.
// Source: every match the backend found, best first. Language: the song's
// own, or a translation that replaces the lines and keeps their timing.
Popup {
  id: root

  property var service: null
  property real maxHeight: Style.space(440)

  readonly property var lyrics: service ? service.lyrics : null
  readonly property var choices: lyrics && lyrics.choices ? lyrics.choices : []
  readonly property string current: lyrics ? String(lyrics.choice || "") : ""
  readonly property string songLang: lyrics ? String(lyrics.lang || "") : ""
  readonly property string target: lyrics ? String(lyrics.translateTo || "") : ""
  readonly property bool showingOriginal: target === "" || target === songLang
  readonly property color fg: Color.popups.text
  readonly property color fgDim: Qt.darker(Color.popups.text, 1.6)

  // The viewer's own language first, the song's own left out.
  readonly property var languages: {
    var names = { en: "English", es: "Spanish", fr: "French", de: "German", pt: "Portuguese",
                  it: "Italian", ru: "Russian", tr: "Turkish", ja: "Japanese", ko: "Korean",
                  zh: "Chinese", ar: "Arabic" }
    var order = ["en", "es", "fr", "de", "pt", "it", "ru", "tr", "ja", "ko", "zh", "ar"]
    var mine = String(Qt.locale().name || "").split("_")[0]
    if (names[mine]) { order.splice(order.indexOf(mine), 1); order.unshift(mine) }
    var out = []
    for (var i = 0; i < order.length; i++)
      if (order[i] !== root.songLang) out.push({ code: order[i], name: names[order[i]] })
    return out
  }

  width: Style.space(280)
  height: Math.min(body.implicitHeight + topPadding + bottomPadding, maxHeight)
  padding: Style.space(6)
  focus: true

  background: Rectangle {
    color: Color.popups.background
    radius: Style.space(12)
    border.width: Math.max(1, Style.normalBorderWidth)
    border.color: Color.popups.border
  }

  component Heading: Text {
    Layout.fillWidth: true
    Layout.topMargin: Style.space(6)
    Layout.leftMargin: Style.space(10)
    Layout.bottomMargin: Style.space(2)
    color: root.fgDim
    font.family: Style.font.family
    font.pixelSize: Style.font.caption - 1
    font.bold: true
    font.letterSpacing: 1
    font.capitalization: Font.AllUppercase
  }

  component PickRow: Rectangle {
    id: pickRow
    property string label: ""
    property string detail: ""
    property bool picked: false
    signal chosen()
    Layout.fillWidth: true
    implicitHeight: detail !== "" ? Style.space(44) : Style.space(32)
    radius: Style.space(8)
    color: pickArea.containsMouse
      ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
      : "transparent"
    Text {
      id: tick
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(16)
      horizontalAlignment: Text.AlignHCenter
      text: pickRow.picked ? "\u{f012c}" : ""
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Column {
      anchors.left: tick.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)
      Text {
        width: parent.width
        text: pickRow.label
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.caption + 1
      }
      Text {
        visible: pickRow.detail !== ""
        width: parent.width
        text: pickRow.detail
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.fgDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption - 1
      }
    }
    MouseArea {
      id: pickArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pickRow.chosen()
    }
  }

  contentItem: Flickable {
    clip: true
    contentWidth: width
    contentHeight: body.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    ColumnLayout {
      id: body
      width: parent.width
      spacing: Style.space(2)

      Heading { text: "Source" }
      Repeater {
        model: root.choices
        delegate: PickRow {
          required property var modelData
          label: String(modelData.label || "")
          detail: String(modelData.detail || "")
          picked: String(modelData.id) === root.current
          onChosen: {
            root.close()
            if (root.service && !picked) root.service.lyricsSelect(String(modelData.id))
          }
        }
      }
      Text {
        visible: root.choices.length === 0
        Layout.fillWidth: true
        Layout.leftMargin: Style.space(10)
        text: "Nothing else found for this track"
        color: root.fgDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        Layout.bottomMargin: Style.space(2)
        implicitHeight: 1
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1)
      }

      Heading { text: "Language" }
      PickRow {
        label: root.lyrics && root.lyrics.langName ? "Original · " + root.lyrics.langName : "Original"
        detail: root.songLang !== "" ? "the song’s own language" : ""
        picked: root.showingOriginal
        onChosen: {
          root.close()
          if (root.service && root.target !== "") root.service.lyricsLanguage("")
        }
      }
      Flow {
        Layout.fillWidth: true
        Layout.leftMargin: Style.space(6)
        Layout.rightMargin: Style.space(6)
        Layout.topMargin: Style.space(4)
        Layout.bottomMargin: Style.space(4)
        spacing: Style.space(4)
        Repeater {
          model: root.languages
          delegate: Rectangle {
            required property var modelData
            readonly property bool picked: root.target === modelData.code
            width: chipText.implicitWidth + Style.space(18)
            height: Style.space(26)
            radius: height / 2
            color: picked ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.28)
              : (chipArea.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1)
                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05))
            Text {
              id: chipText
              anchors.centerIn: parent
              text: modelData.name
              color: picked ? Color.accent : root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: chipArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.close()
                if (root.service && !parent.picked) root.service.lyricsLanguage(modelData.code)
              }
            }
          }
        }
      }
      Text {
        visible: !!(root.lyrics && root.lyrics.translateError)
        Layout.fillWidth: true
        Layout.leftMargin: Style.space(10)
        Layout.bottomMargin: Style.space(4)
        text: root.lyrics ? String(root.lyrics.translateError || "") + ". Showing the original." : ""
        wrapMode: Text.WordWrap
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption - 1
      }
    }
  }
}
