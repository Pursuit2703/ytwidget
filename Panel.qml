import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

import "Api.js" as Api

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false

  readonly property color fg: Color.foreground
  readonly property color fgDim: Qt.darker(Color.foreground, 1.6)
  readonly property color accent: Color.accent
  readonly property color rowFill: Qt.rgba(fg.r, fg.g, fg.b, 0.05)
  readonly property color rowFillActive: Qt.rgba(accent.r, accent.g, accent.b, 0.16)
  readonly property color cardFill: Qt.rgba(fg.r, fg.g, fg.b, 0.04)

  // Verified glyphs already used elsewhere in this shell/font (omarchy.media,
  // wizwam.omamusic) — reused verbatim so icons render correctly instead of tofu.
  readonly property string iconPlay: "󰐊"
  readonly property string iconPause: "󰏤"
  readonly property string iconPrev: "󰒮"
  readonly property string iconNext: "󰒭"
  readonly property string iconShuffle: "󰒟"
  readonly property string iconRepeat: "󰑖"
  readonly property string iconRepeatOne: "󰑘"
  readonly property string iconClose: "󰅖"
  readonly property string iconQueueAdd: "󰐕"
  readonly property string iconPlaylistAdd: "󱁐"
  readonly property string iconSearch: "󰍉"
  readonly property string iconNote: "󰝚"

  property string activeTab: "search"
  property string searchText: ""
  property var searchResults: []
  property bool searching: false
  property string searchError: ""
  property var activePlaylistId: ""
  property var activePlaylistItems: []
  property string activePlaylistName: ""
  property string newPlaylistName: ""
  property bool eqExpanded: false

  function open(payloadJson) {
    opened = true
    if (service) service.ensureRunning()
    Qt.callLater(function() {
      if (searchField) searchField.forceActiveFocus()
    })
  }
  function close() { opened = false }

  readonly property bool searchIsLink: Api.isYouTubeLink(root.searchText)

  function runSearch() {
    if (!root.searchText.trim()) { searchResults = []; searchError = ""; return }
    if (!service) return
    searching = true
    searchError = ""
    service.search(root.searchText.trim(), 24, function(ok, result, message) {
      searching = false
      if (ok) searchResults = (result && result.items) || []
      else searchError = message || "Search failed"
    })
  }

  // Enter on a pasted link loads it rather than searching for it. A playlist
  // link replaces the queue outright, so this only ever runs on an explicit
  // submit — never from the as-you-type timer.
  function openLinkNow() {
    var link = root.searchText.trim()
    if (!link || !service) return
    searching = true
    searchError = ""
    service.openLink(link, function(ok, result, message) {
      searching = false
      if (!ok) { searchError = message || "Could not open that link"; return }
      root.searchResults = []
      root.searchText = ""
      root.activeTab = "queue"
    })
  }

  function submitSearchField() {
    liveSearchTimer.stop()
    if (root.searchIsLink) openLinkNow()
    else { root.activeTab = "search"; runSearch() }
  }

  function toggleVideo() {
    if (!service || !service.hasTrack) return
    if (service.videoActive) service.hideVideo()
    else service.showVideo("")
  }

  function queueIndexFor(videoId) {
    if (!root.service || !videoId) return -1
    var q = root.service.queue || []
    for (var i = 0; i < q.length; i++) {
      if (q[i] && q[i].videoId === videoId) return i
    }
    return -1
  }

  function openPlaylist(playlistId) {
    if (!service) return
    service.getPlaylist(playlistId, function(ok, result) {
      if (!ok) return
      activePlaylistId = playlistId
      activePlaylistName = (result && result.name) || playlistId
      activePlaylistItems = (result && result.items) || []
    })
  }

  onOpenedChanged: {
    if (!opened || !service) return
    service.listPlaylists(function() {})
    // Warm the video ladder while the panel is open, so pressing Watch costs
    // no extraction.
    if (service.hasTrack && !service.videoReady) service.prepareVideo("")
  }

  FloatingWindow {
    id: window
    visible: root.opened
    title: "YT Widget"
    color: Color.background
    implicitWidth: 920
    implicitHeight: 660
    minimumSize: Qt.size(680, 480)
    maximumSize: Qt.size(1300, 950)

    onVisibleChanged: if (!visible && root.opened) root.close()

    FocusScope {
      anchors.fill: parent
      focus: true

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        spacing: Style.space(10)

        // ---- Header: search + tabs ----
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          TextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: "Search YouTube, or paste a video / playlist link…"
            text: root.searchText
            onTextChanged: {
              root.searchText = text
              root.activeTab = "search"
              // Never expand a link from the as-you-type timer: a playlist
              // link replaces the queue, and half a pasted URL is not a link.
              if (root.searchIsLink) liveSearchTimer.stop()
              else liveSearchTimer.restart()
            }
            onAccepted: root.submitSearchField()
          }
          Button {
            text: root.searching
                  ? (root.searchIsLink ? "Opening…" : "Searching…")
                  : (root.searchIsLink ? "Open link" : "Search")
            iconText: root.searchIsLink ? root.iconPlay : root.iconSearch
            onClicked: root.submitSearchField()
          }
        }

        // Live results as you type, debounced so we don't fire a search per
        // keystroke — same idea as an autocomplete box.
        Timer {
          id: liveSearchTimer
          interval: 300
          repeat: false
          onTriggered: root.runSearch()
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(4)

          Button { text: "Search"; selected: root.activeTab === "search"; onClicked: root.activeTab = "search" }
          Button { text: "Queue"; selected: root.activeTab === "queue"; onClicked: root.activeTab = "queue" }
          Button { text: "Playlists"; selected: root.activeTab === "playlists"; onClicked: root.activeTab = "playlists" }
          Button { text: "History"; selected: root.activeTab === "history"; onClicked: root.activeTab = "history" }
          Item { Layout.fillWidth: true }
          Chicklet { iconText: root.iconClose; tooltipText: "Close"; onClicked: root.close() }
        }

        PanelSeparator { Layout.fillWidth: true }

        // ---- Body ----
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          ListView {
            anchors.fill: parent
            visible: root.activeTab === "search"
            model: root.searchResults
            clip: true
            spacing: Style.space(2)
            ScrollBar.vertical: ScrollBar {}

            Label {
              anchors.centerIn: parent
              visible: root.searchResults.length === 0
              text: root.searchError || (root.searching ? "Searching…" : "Search YouTube, or paste a video or playlist link")
              color: root.fgDim
              font.family: Style.font.family
            }

            delegate: TrackRow {
              width: ListView.view.width
              item: modelData
              queueGlyph: root.queueIndexFor(modelData.videoId) >= 0 ? root.iconClose : root.iconQueueAdd
              onPlayRequested: if (root.service) root.service.playNow(modelData)
              onQueueRequested: {
                if (!root.service) return
                var idx = root.queueIndexFor(modelData.videoId)
                if (idx >= 0) root.service.removeFromQueue(idx)
                else root.service.addToQueue(modelData)
              }
            }
          }

          ListView {
            anchors.fill: parent
            visible: root.activeTab === "queue"
            model: root.service ? root.service.queue : []
            clip: true
            spacing: Style.space(2)
            ScrollBar.vertical: ScrollBar {}

            Label {
              anchors.centerIn: parent
              visible: !root.service || root.service.queue.length === 0
              text: "Queue is empty"
              color: root.fgDim
              font.family: Style.font.family
            }

            delegate: TrackRow {
              width: ListView.view.width
              item: modelData
              highlighted: index === (root.service ? root.service.queueIndex : -1)
              queueGlyph: root.iconClose
              onPlayRequested: if (root.service) root.service.playQueueFrom(root.service.queue, index)
              onQueueRequested: if (root.service) root.service.removeFromQueue(index)
            }
          }

          ColumnLayout {
            anchors.fill: parent
            visible: root.activeTab === "playlists"
            spacing: Style.space(8)

            RowLayout {
              Layout.fillWidth: true
              visible: root.activePlaylistId === ""
              spacing: Style.space(8)
              TextField {
                Layout.fillWidth: true
                placeholderText: "Save current queue as…"
                text: root.newPlaylistName
                onTextChanged: root.newPlaylistName = text
              }
              Button {
                text: "Save"
                iconText: root.iconPlaylistAdd
                enabled: root.newPlaylistName.trim() !== ""
                onClicked: {
                  if (!root.service) return
                  service.createPlaylist(root.newPlaylistName.trim(), null, function() {
                    root.newPlaylistName = ""
                    service.listPlaylists(function() {})
                  })
                }
              }
            }

            RowLayout {
              visible: root.activePlaylistId !== ""
              spacing: Style.space(8)
              Chicklet { iconText: root.iconPrev; tooltipText: "Back"; onClicked: root.activePlaylistId = "" }
              Label { text: root.activePlaylistName; color: root.fg; font.bold: true; font.family: Style.font.family
                font.pixelSize: Style.font.subtitle }
            }

            ListView {
              Layout.fillWidth: true
              Layout.fillHeight: true
              visible: root.activePlaylistId === ""
              model: root.service ? root.service.playlists : []
              clip: true
              spacing: Style.space(2)

              Label {
                anchors.centerIn: parent
                visible: !root.service || root.service.playlists.length === 0
                text: "No playlists yet. Save your queue above."
                color: root.fgDim
                font.family: Style.font.family
              }

              delegate: Rectangle {
                width: ListView.view.width
                height: Style.space(46)
                radius: Style.cornerRadius
                color: hoverArea.containsMouse ? root.rowFill : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(8)
                  Label {
                    text: modelData.name; color: root.fg; Layout.fillWidth: true
                    font.family: Style.font.family; elide: Text.ElideRight
                  }
                  Label {
                    text: modelData.count + " tracks"; color: root.fgDim
                    font.family: Style.font.family; font.pixelSize: Style.font.caption
                  }
                  Chicklet {
                    iconText: root.iconClose
                    tooltipText: "Delete playlist"
                    onClicked: root.service && root.service.deletePlaylist(modelData.id)
                  }
                }
                MouseArea {
                  id: hoverArea
                  anchors.fill: parent
                  anchors.rightMargin: Style.space(46)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openPlaylist(modelData.id)
                }
              }
            }

            ListView {
              Layout.fillWidth: true
              Layout.fillHeight: true
              visible: root.activePlaylistId !== ""
              model: root.activePlaylistItems
              clip: true
              spacing: Style.space(2)

              delegate: TrackRow {
                width: ListView.view.width
                item: modelData
                queueGlyph: root.iconClose
                onPlayRequested: if (root.service) root.service.playQueueFrom(root.activePlaylistItems, index)
                onQueueRequested: if (root.service) root.service.removeFromPlaylist(root.activePlaylistId, modelData.videoId)
              }
            }
          }

          ListView {
            anchors.fill: parent
            visible: root.activeTab === "history"
            model: root.service ? root.service.playHistory : []
            clip: true
            spacing: Style.space(2)
            ScrollBar.vertical: ScrollBar {}

            Label {
              anchors.centerIn: parent
              visible: !root.service || root.service.playHistory.length === 0
              text: "Nothing played yet"
              color: root.fgDim
              font.family: Style.font.family
            }

            delegate: TrackRow {
              width: ListView.view.width
              item: modelData
              queueGlyph: root.queueIndexFor(modelData.videoId) >= 0 ? root.iconClose : root.iconQueueAdd
              onPlayRequested: if (root.service) root.service.playNow(modelData)
              onQueueRequested: {
                if (!root.service) return
                var idx = root.queueIndexFor(modelData.videoId)
                if (idx >= 0) root.service.removeFromQueue(idx)
                else root.service.addToQueue(modelData)
              }
            }
          }
        }

        // ---- Spectrum + EQ (collapsible), straight from omamusic ----
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.eqExpanded
          spacing: Style.space(4)

          SpectrumBar {
            Layout.fillWidth: true
            levels: root.service ? root.service.spectrumBands : []
            foreground: root.fg
            accent: root.accent
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Label {
              text: "Mode"
              color: root.fgDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Dropdown {
              Layout.preferredWidth: Style.space(180)
              showLabel: false
              options: root.service ? root.service.eqPresets : []
              // "Custom" is what the backend reports once a band has been
              // dragged by hand; it is a state, not something you can pick.
              value: root.service ? root.service.eq.preset : "Flat"
              foreground: root.fg
              onChanged: function(value) {
                if (root.service) root.service.setEqPreset(value)
              }
            }
            Item { Layout.fillWidth: true }
          }
          EqBar {
            Layout.fillWidth: true
            service: root.service
            foreground: root.fg
            accent: root.accent
            // The preset picker above replaces the cycle-through button.
            showPreset: false
          }
        }

        // ---- Video controls (only while a video window is open) ----
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          visible: !!(root.service && root.service.videoActive)

          Label {
            text: "Quality"
            color: root.fgDim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Dropdown {
            Layout.preferredWidth: Style.space(130)
            showLabel: false
            options: {
              var out = []
              var hs = root.service ? root.service.videoHeights : []
              for (var i = 0; i < hs.length; i++)
                out.push({ value: String(hs[i]), label: hs[i] + "p" })
              return out
            }
            value: root.service ? String(root.service.videoHeight) : ""
            foreground: root.fg
            onChanged: function(value) {
              if (root.service) root.service.setVideoQuality(parseInt(value, 10))
            }
          }
          Label {
            text: "Speed"
            color: root.fgDim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Dropdown {
            Layout.preferredWidth: Style.space(130)
            showLabel: false
            options: {
              var out = []
              var sp = root.service ? root.service.videoSpeeds : []
              for (var i = 0; i < sp.length; i++)
                out.push({ value: String(sp[i]), label: (sp[i] === 1 ? "Normal" : sp[i] + "x") })
              return out
            }
            value: root.service ? String(root.service.videoSpeed) : "1"
            foreground: root.fg
            onChanged: function(value) {
              if (root.service) root.service.setVideoSpeed(parseFloat(value))
            }
          }
          Item { Layout.fillWidth: true }
        }

        // ---- Transport ----
        BorderSurface {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(74)
          radius: Style.cornerRadius
          color: root.cardFill

          RowLayout {
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(10)

            Rectangle {
              Layout.preferredWidth: Style.space(52)
              Layout.preferredHeight: Style.space(52)
              radius: Style.cornerRadius
              color: root.rowFill
              Image {
                anchors.fill: parent
                visible: root.service && root.service.trackThumbnail !== ""
                source: root.service ? root.service.trackThumbnail : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
              }
              Label {
                anchors.centerIn: parent
                visible: !root.service || root.service.trackThumbnail === ""
                text: root.iconNote
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
              }
            }

            ColumnLayout {
              Layout.preferredWidth: Style.space(200)
              spacing: Style.space(2)
              Label {
                text: root.service && root.service.hasTrack ? root.service.trackTitle : "Nothing playing"
                color: root.fg
                font.bold: true
                font.family: Style.font.family
                elide: Text.ElideRight
                Layout.fillWidth: true
              }
              Label {
                text: (root.service && root.service.lastError) || (root.service ? root.service.trackArtist : "")
                color: (root.service && root.service.lastError) ? Color.urgent : root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                Layout.fillWidth: true
              }
            }

            Chicklet { iconText: root.iconShuffle
              selected: !!(root.service && root.service.shuffle)
              tooltipText: "Shuffle"
              onClicked: root.service && root.service.setShuffle(!root.service.shuffle) }
            Chicklet { iconText: root.iconPrev; tooltipText: "Previous"
              onClicked: root.service && root.service.previous() }
            Chicklet {
              iconText: root.service && root.service.effectivePlaying ? root.iconPause : root.iconPlay
              iconSize: Style.font.iconLarge
              chickletSize: Style.space(38)
              tooltipText: root.service && root.service.effectivePlaying ? "Pause" : "Play"
              onClicked: root.service && root.service.togglePlayback()
            }
            Chicklet { iconText: root.iconNext; tooltipText: "Next"
              onClicked: root.service && root.service.next() }
            Chicklet {
              iconText: root.service && root.service.repeat === "track" ? root.iconRepeatOne : root.iconRepeat
              selected: root.service && root.service.repeat !== "off"
              tooltipText: "Repeat"
              onClicked: root.service && root.service.cycleRepeat()
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)
              PanelSlider {
                Layout.fillWidth: true
                minimum: 0
                maximum: Math.max(1, root.service ? root.service.durationMs : 1)
                value: root.service ? root.service.positionMs : 0
                onMoved: function(v) { if (root.service) root.service.seek(v) }
              }
              RowLayout {
                Layout.fillWidth: true
                Label { text: Api.formatTime(root.service ? root.service.positionMs : 0)
                  color: root.fgDim; font.pixelSize: Style.font.caption; font.family: Style.font.family }
                Item { Layout.fillWidth: true }
                Label { text: Api.formatTime(root.service ? root.service.durationMs : 0)
                  color: root.fgDim; font.pixelSize: Style.font.caption; font.family: Style.font.family }
              }
            }

            PanelSlider {
              Layout.preferredWidth: Style.space(90)
              minimum: 0; maximum: 100
              value: root.service ? root.service.volume : 80
              onMoved: function(v) { if (root.service) root.service.setVolume(v) }
            }

            Chicklet {
              iconText: "󰕧"
              selected: !!(root.service && root.service.videoActive)
              enabled: !!(root.service && root.service.hasTrack)
              tooltipText: root.service && root.service.videoActive
                           ? "Close the video window"
                           : "Watch the video"
              onClicked: root.toggleVideo()
            }
            Button {
              text: "EQ"
              selected: root.eqExpanded
              onClicked: root.eqExpanded = !root.eqExpanded
            }
          }
        }
      }
    }
  }

}
