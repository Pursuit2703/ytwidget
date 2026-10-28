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
  // The playlist page: a saved playlist, or one resolved from a pasted link
  // ({ id: "" while it is not saved }). While set it replaces the tab body.
  property var page: null                 // { id, name, items, fromLink }
  property bool pageBusy: false
  property string pageError: ""
  property string newPlaylistName: ""
  property bool eqExpanded: false
  readonly property var history: service ? service.playHistory : []

  // The payload is how the mini player hands its search over (see
  // BarWidget.openFullPlayer). `search` prefills the field and `results` are
  // the rows the card was already showing, so the panel opens on the same
  // list instead of an empty Search tab with the query lost. The panel asks
  // for far more results than the card does, so the same query is re-run
  // behind those rows and the list fills out when it lands.
  function open(payloadJson) {
    opened = true
    if (service) service.ensureRunning()

    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") || ({}) } catch (e) { payload = ({}) }

    var handed = typeof payload.search === "string" ? payload.search : ""
    if (handed.trim() !== "") {
      root.activeTab = "search"
      root.searchError = ""
      root.searchText = handed
      if (Array.isArray(payload.results) && payload.results.length > 0)
        root.searchResults = payload.results
      // Assigning searchText runs the field's onTextChanged, which arms the
      // as-you-type timer; stop it and run the search directly so the refresh
      // starts now rather than 300ms after a keystroke nobody typed.
      liveSearchTimer.stop()
      if (!root.searchIsLink) runSearch()
      else if (root.searchIsPlaylist) previewLink()
    }

    Qt.callLater(function() {
      if (searchField) searchField.forceActiveFocus()
    })
  }
  function close() { opened = false }

  readonly property bool searchIsLink: Api.isYouTubeLink(root.searchText)
  readonly property bool searchIsPlaylist: searchIsLink && /[?&]list=/.test(root.searchText)

  // Resolve a pasted playlist link into the playlist page. Nothing is saved
  // or played until a button on the page is pressed.
  function previewLink() {
    var link = root.searchText.trim()
    if (!link || !service) return
    pageBusy = true
    pageError = ""
    service.previewPlaylist(link, function(ok, result, message) {
      pageBusy = false
      if (!ok || !result || !result.items || result.items.length === 0) {
        pageError = message || "Could not read that playlist"
        return
      }
      root.page = { id: "", name: result.title || "Playlist", items: result.items, fromLink: true }
    })
  }

  function pageDurationText() {
    if (!page) return ""
    var ms = 0
    for (var i = 0; i < page.items.length; i++) ms += Number(page.items[i].durationMs || 0)
    var minutes = Math.round(ms / 60000)
    var h = Math.floor(minutes / 60), m = minutes % 60
    return page.items.length + " tracks" + (minutes > 0 ? " · " + (h > 0 ? h + " h " : "") + m + " min" : "")
  }

  function playPage(shuffle) {
    if (!page || !service) return
    if (shuffle) service.setShuffle(true)
    service.playQueueFrom(page.items, 0)
  }

  function addPageToQueue() {
    if (!page || !service) return
    for (var i = 0; i < page.items.length; i++) service.addToQueue(page.items[i])
  }

  function savePage() {
    if (!page || !service || page.id !== "") return
    service.createPlaylist(page.name, page.items, function(ok) {
      if (!ok) return
      service.listPlaylists(function() {})
      root.page = null
      root.activeTab = "playlists"
    })
  }

  function saveQueueAsPlaylist() {
    if (!service || service.queue.length === 0) return
    var name = root.history.length > 0 ? "Queue · " + Qt.formatDateTime(new Date(), "d MMM HH:mm") : "Queue"
    service.createPlaylist(name, null, function(ok) { if (ok) service.listPlaylists(function() {}) })
  }

  // History grouped by day, newest first, as flat rows the list can draw:
  // { label } rows are day headers, the rest are tracks.
  function recentRows() {
    var rows = []
    var lastDay = ""
    var today = new Date(); today.setHours(0, 0, 0, 0)
    var dayMs = 86400000
    for (var i = 0; i < root.history.length; i++) {
      var t = root.history[i]
      var at = Number(t.playedAt || 0) * 1000
      var label
      if (!at) label = "EARLIER"
      else if (at >= today.getTime()) label = "TODAY"
      else if (at >= today.getTime() - dayMs) label = "YESTERDAY"
      else label = Qt.formatDate(new Date(at), "d MMMM").toUpperCase()
      if (label !== lastDay) { rows.push({ header: true, label: label }); lastDay = label }
      rows.push({ header: false, track: t, when: at ? Qt.formatTime(new Date(at), "HH:mm") : "" })
    }
    return rows
  }

  function mostPlayed() {
    var rows = []
    for (var i = 0; i < root.history.length; i++)
      if (Number(root.history[i].plays || 0) >= 2) rows.push(root.history[i])
    rows.sort(function(a, b) { return Number(b.plays) - Number(a.plays) })
    return rows.slice(0, 50)
  }

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

  // Appends the link's video (or its whole playlist) to the queue as one
  // batch, without touching playback or replacing what's already queued —
  // the deliberate alternative to openLinkNow's replace-and-play.
  property bool enqueuingLink: false

  function enqueueLinkNow() {
    var link = root.searchText.trim()
    if (!link || !service) return
    enqueuingLink = true
    searchError = ""
    service.enqueueLink(link, function(ok, result, message) {
      enqueuingLink = false
      if (!ok) { searchError = message || "Could not queue that link"; return }
      root.searchResults = []
      root.searchText = ""
      root.activeTab = "queue"
    })
  }

  function submitSearchField() {
    liveSearchTimer.stop()
    if (root.searchIsPlaylist) previewLink()
    else if (root.searchIsLink) openLinkNow()
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
      root.page = { id: playlistId, name: (result && result.name) || playlistId, items: (result && result.items) || [], fromLink: false }
    })
  }

  function openItems(title, items) {
    root.page = { id: "", name: title, items: items, fromLink: false, virtual: true }
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

    CoverBlur {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Style.space(240)
      source: root.service ? root.service.trackThumbnail : ""
      strength: 0.5
      fadeTo: Color.background
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(16)
        spacing: Style.space(12)

        // ---- Search, with a tag when the text is a playlist link ----
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
              if (root.page && root.page.fromLink) root.page = null
              root.pageError = ""
              if (root.activeTab !== "search") root.activeTab = "search"
              if (root.searchIsLink) {
                liveSearchTimer.stop()
                if (root.searchIsPlaylist) previewTimer.restart()
              } else liveSearchTimer.restart()
            }
            onAccepted: root.submitSearchField()
          }
          Rectangle {
            visible: root.searchIsPlaylist
            Layout.preferredHeight: Style.space(28)
            Layout.preferredWidth: tagText.implicitWidth + Style.space(20)
            radius: height / 2
            color: root.rowFillActive
            Text {
              id: tagText
              anchors.centerIn: parent
              text: root.pageBusy ? "Reading playlist…" : (root.page && root.page.fromLink ? "Playlist · " + root.page.items.length : "Playlist")
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
          Button {
            visible: root.searchIsLink && !root.searchIsPlaylist
            text: root.searching ? "Opening…" : "Open link"
            iconText: root.iconPlay
            onClicked: root.submitSearchField()
          }
          Button {
            visible: root.searchIsLink && !root.searchIsPlaylist
            text: root.enqueuingLink ? "Queueing…" : "Add to queue"
            iconText: root.iconQueueAdd
            enabled: !root.enqueuingLink
            onClicked: root.enqueueLinkNow()
          }
          FlatButton {
            buttonSize: Style.space(36)
            iconText: root.iconClose
            foreground: root.fg
            tooltipText: "Close"
            onClicked: root.close()
          }
        }

        Timer { id: liveSearchTimer; interval: 300; repeat: false; onTriggered: root.runSearch() }
        Timer { id: previewTimer; interval: 450; repeat: false; onTriggered: root.previewLink() }

        Segmented {
          Layout.fillWidth: true
          foreground: root.fg
          current: root.activeTab
          model: [
            { key: "search", label: "Search", glyph: root.iconSearch },
            { key: "queue", label: "Queue", glyph: root.iconNote },
            { key: "playlists", label: "Playlists", glyph: "\u{f0cb8}" },
            { key: "recent", label: "Recent", glyph: "\u{f02da}" }
          ]
          onPicked: function(key) { root.page = null; root.activeTab = key }
        }

        // ---- Body ----
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // ===== playlist page (saved playlist, pasted link, or a smart list)
          ColumnLayout {
            anchors.fill: parent
            visible: root.page !== null
            spacing: Style.space(12)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(16)

              FlatButton {
                visible: !(root.page && root.page.fromLink)
                iconText: "\u{f004d}"
                foreground: root.fg
                tooltipText: "Back"
                onClicked: root.page = null
              }
              Rectangle {
                Layout.preferredWidth: Style.space(92)
                Layout.preferredHeight: Style.space(92)
                radius: Style.space(12)
                color: root.rowFill
                clip: true
                Grid {
                  anchors.fill: parent
                  columns: 2
                  Repeater {
                    model: root.page ? root.page.items.slice(0, 4) : []
                    delegate: Image {
                      width: parent.width / 2
                      height: parent.height / 2
                      source: modelData.thumbnail || ""
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                    }
                  }
                }
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Label {
                  Layout.fillWidth: true
                  text: root.page ? root.page.name : ""
                  color: root.fg
                  font.family: Style.font.family
                  font.bold: true
                  font.pixelSize: Style.font.subtitle
                  elide: Text.ElideRight
                }
                Label {
                  text: root.pageDurationText()
                  color: root.fgDim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)
              Button { text: "Play all"; iconText: root.iconPlay; onClicked: root.playPage(false) }
              Button { text: "Shuffle"; iconText: root.iconShuffle; onClicked: root.playPage(true) }
              Button { text: "Add to queue"; iconText: root.iconQueueAdd; onClicked: root.addPageToQueue() }
              Item { Layout.fillWidth: true }
              Button {
                visible: !!root.page && root.page.id === "" && !root.page.virtual
                text: "Save"
                iconText: root.iconPlaylistAdd
                onClicked: root.savePage()
              }
              Button {
                visible: !!root.page && root.page.id !== ""
                text: "Delete"
                iconText: root.iconClose
                onClicked: {
                  if (!root.service) return
                  root.service.deletePlaylist(root.page.id)
                  root.page = null
                  root.service.listPlaylists(function() {})
                }
              }
            }

            ListView {
              Layout.fillWidth: true
              Layout.fillHeight: true
              model: root.page ? root.page.items : []
              clip: true
              spacing: Style.space(2)
              ScrollBar.vertical: ScrollBar {}
              delegate: TrackRow {
                width: ListView.view.width
                item: modelData
                service: root.service
                queueGlyph: root.iconQueueAdd
                onPlayRequested: if (root.service) root.service.playQueueFrom(root.page.items, index)
                onQueueRequested: if (root.service) root.service.addToQueue(modelData)
              }
            }
          }

          // ===== search
          ListView {
            anchors.fill: parent
            visible: root.page === null && root.activeTab === "search"
            model: root.searchResults
            clip: true
            spacing: Style.space(2)
            ScrollBar.vertical: ScrollBar {}

            Label {
              anchors.centerIn: parent
              visible: root.searchResults.length === 0
              text: root.pageError || root.searchError || (root.searching || root.pageBusy ? "Searching…" : "Search YouTube, or paste a video or playlist link")
              color: root.pageError !== "" || root.searchError !== "" ? Color.urgent : root.fgDim
              font.family: Style.font.family
            }

            delegate: TrackRow {
              width: ListView.view.width
              item: modelData
              service: root.service
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

          // ===== queue
          ColumnLayout {
            anchors.fill: parent
            visible: root.page === null && root.activeTab === "queue"
            spacing: Style.space(6)

            RowLayout {
              Layout.fillWidth: true
              Label {
                Layout.fillWidth: true
                text: root.service ? "UP NEXT · " + root.service.queue.length + " TRACKS" : ""
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.4
              }
              Button {
                visible: !!root.service && root.service.queue.length > 0
                text: "Save as playlist"
                iconText: root.iconPlaylistAdd
                onClicked: root.saveQueueAsPlaylist()
              }
            }

            ListView {
              Layout.fillWidth: true
              Layout.fillHeight: true
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
                service: root.service
                highlighted: index === (root.service ? root.service.queueIndex : -1)
                queueGlyph: root.iconClose
                onPlayRequested: if (root.service) root.service.playQueueFrom(root.service.queue, index)
                onQueueRequested: if (root.service) root.service.removeFromQueue(index)
              }
            }
          }

          // ===== playlists
          Flickable {
            anchors.fill: parent
            visible: root.page === null && root.activeTab === "playlists"
            contentHeight: playlistsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            ColumnLayout {
              id: playlistsColumn
              width: parent.width
              spacing: Style.space(10)

              RowLayout {
                Layout.fillWidth: true
                visible: root.history.length > 0
                Label {
                  Layout.fillWidth: true
                  text: "RECENTLY PLAYED"
                  color: root.fgDim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1.4
                }
                Button { text: "See all"; onClicked: root.activeTab = "recent" }
              }

              RowLayout {
                Layout.fillWidth: true
                visible: root.history.length > 0
                spacing: Style.space(10)
                Repeater {
                  model: root.history.slice(0, 3)
                  delegate: Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    implicitHeight: recentCard.implicitHeight + Style.space(20)
                    radius: Style.space(14)
                    color: root.cardFill

                    ColumnLayout {
                      id: recentCard
                      anchors.fill: parent
                      anchors.margins: Style.space(10)
                      spacing: Style.space(8)
                      Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Style.space(96)
                        radius: Style.space(10)
                        color: root.rowFill
                        clip: true
                        Image {
                          anchors.fill: parent
                          source: modelData.thumbnail || ""
                          fillMode: Image.PreserveAspectCrop
                          asynchronous: true
                        }
                        FlatButton {
                          anchors.right: parent.right
                          anchors.bottom: parent.bottom
                          anchors.margins: Style.space(6)
                          primary: true
                          buttonSize: Style.space(30)
                          iconText: root.iconPlay
                          onClicked: if (root.service) root.service.playNow(modelData)
                        }
                      }
                      Label {
                        Layout.fillWidth: true
                        text: modelData.name || ""
                        color: root.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                  }
                }
              }

              Label {
                text: "PLAYLISTS"
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.4
              }

              // Most played: computed from the history's play counts.
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(54)
                radius: Style.space(12)
                visible: root.mostPlayed().length > 0
                color: mpHover.containsMouse ? root.rowFill : "transparent"
                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(14)
                  Rectangle {
                    Layout.preferredWidth: Style.space(40)
                    Layout.preferredHeight: Style.space(40)
                    radius: Style.space(10)
                    color: root.rowFillActive
                    Text {
                      anchors.fill: parent
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter
                      text: "\u{f04ce}"
                      color: root.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.iconLarge
                    }
                  }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)
                    Label { text: "Most played"; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.body }
                    Label { text: "Smart · from your play counts"; color: root.fgDim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                  }
                  Label { text: root.mostPlayed().length + ""; color: root.fgDim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                }
                MouseArea {
                  id: mpHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openItems("Most played", root.mostPlayed())
                }
              }

              Repeater {
                model: root.service ? root.service.playlists : []
                delegate: Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(54)
                  radius: Style.space(12)
                  color: plHover.containsMouse ? root.rowFill : "transparent"
                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(14)
                    Rectangle {
                      Layout.preferredWidth: Style.space(40)
                      Layout.preferredHeight: Style.space(40)
                      radius: Style.space(9)
                      color: root.rowFill
                      clip: true
                      Grid {
                        anchors.fill: parent
                        columns: 2
                        Repeater {
                          model: modelData.covers || []
                          delegate: Image {
                            width: parent.width / 2
                            height: parent.height / 2
                            source: modelData
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                          }
                        }
                      }
                    }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(2)
                      Label { Layout.fillWidth: true; text: modelData.name; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.body; elide: Text.ElideRight }
                      Label { text: modelData.count + " tracks"; color: root.fgDim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    }
                    FlatButton {
                      iconText: root.iconPlay
                      tooltipText: "Play"
                      foreground: root.accent
                      onClicked: {
                        if (!root.service) return
                        root.service.getPlaylist(modelData.id, function(ok, result) {
                          if (ok && result && result.items && result.items.length > 0)
                            root.service.playQueueFrom(result.items, 0)
                        })
                      }
                    }
                  }
                  MouseArea {
                    id: plHover
                    anchors.fill: parent
                    z: -1
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openPlaylist(modelData.id)
                  }
                }
              }

              Label {
                visible: !root.service || root.service.playlists.length === 0
                text: "No saved playlists yet. Paste a playlist link above, or save the queue."
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ===== recent
          ColumnLayout {
            anchors.fill: parent
            visible: root.page === null && root.activeTab === "recent"
            spacing: Style.space(6)

            RowLayout {
              Layout.fillWidth: true
              Item { Layout.fillWidth: true }
              Button {
                visible: root.history.length > 0
                text: "Play all"
                iconText: root.iconPlay
                onClicked: if (root.service) root.service.playQueueFrom(root.history, 0)
              }
              Button {
                visible: root.history.length > 0
                text: "Clear history"
                iconText: root.iconClose
                onClicked: if (root.service) root.service.clearHistory(function() {})
              }
            }

            ListView {
              Layout.fillWidth: true
              Layout.fillHeight: true
              model: root.recentRows()
              clip: true
              spacing: Style.space(2)
              ScrollBar.vertical: ScrollBar {}

              Label {
                anchors.centerIn: parent
                visible: root.history.length === 0
                text: "Nothing played yet"
                color: root.fgDim
                font.family: Style.font.family
              }

              delegate: Loader {
                width: ListView.view.width
                property var rowData: modelData
                sourceComponent: modelData.header ? headerRow : trackRow
              }
            }

            Component {
              id: headerRow
              Label {
                height: Style.space(30)
                verticalAlignment: Text.AlignVCenter
                text: rowData.label
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.4
              }
            }
            Component {
              id: trackRow
              TrackRow {
                item: rowData.track
                service: root.service
                queueGlyph: root.iconQueueAdd
                onPlayRequested: if (root.service) root.service.playNow(rowData.track)
                onQueueRequested: if (root.service) root.service.addToQueue(rowData.track)
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

        // ---- Now playing: one row that never overflows ----
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(78)
          radius: Style.space(16)
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(12)

            Rectangle {
              Layout.preferredWidth: Style.space(54)
              Layout.preferredHeight: Style.space(54)
              radius: Style.space(10)
              color: root.rowFill
              clip: true
              Image {
                anchors.fill: parent
                source: root.service ? root.service.trackThumbnail : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
              }
            }

            ColumnLayout {
              Layout.preferredWidth: Style.space(190)
              Layout.maximumWidth: Style.space(190)
              spacing: Style.space(2)
              Label {
                Layout.fillWidth: true
                text: root.service && root.service.hasTrack ? root.service.trackTitle : "Nothing playing"
                color: root.fg
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Label {
                Layout.fillWidth: true
                text: root.service ? root.service.trackArtist : ""
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            RowLayout {
              spacing: Style.space(2)
              FlatButton {
                iconText: root.iconShuffle
                selected: !!(root.service && root.service.shuffle)
                foreground: root.fg
                tooltipText: "Shuffle"
                onClicked: root.service && root.service.setShuffle(!root.service.shuffle)
              }
              FlatButton {
                iconText: root.iconPrev
                foreground: root.fg
                tooltipText: "Previous"
                onClicked: root.service && root.service.previous()
              }
              FlatButton {
                primary: true
                buttonSize: Style.space(44)
                iconSize: Style.font.iconLarge
                iconText: root.service && root.service.playing ? root.iconPause : root.iconPlay
                tooltipText: "Play / pause"
                onClicked: root.service && root.service.togglePlayback()
              }
              FlatButton {
                iconText: root.iconNext
                foreground: root.fg
                tooltipText: "Next"
                onClicked: root.service && root.service.next()
              }
              FlatButton {
                iconText: root.service && root.service.repeat === "track" ? root.iconRepeatOne : root.iconRepeat
                selected: !!(root.service && root.service.repeat !== "off")
                foreground: root.fg
                tooltipText: "Repeat"
                onClicked: root.service && root.service.cycleRepeat()
              }
            }

            Label {
              text: Api.formatTime(root.service ? root.service.positionMs : 0)
              color: root.fgDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            PanelSlider {
              Layout.fillWidth: true
              Layout.minimumWidth: Style.space(80)
              minimum: 0
              maximum: Math.max(1, root.service ? root.service.durationMs : 1)
              value: root.service ? root.service.positionMs : 0
              onMoved: function(v) { if (root.service) root.service.seek(v) }
            }
            Label {
              text: Api.formatTime(root.service ? root.service.durationMs : 0)
              color: root.fgDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Label {
              text: "\u{f057e}"
              color: root.fgDim
              font.family: Style.font.family
              font.pixelSize: Style.font.icon
            }
            PanelSlider {
              Layout.preferredWidth: Style.space(70)
              Layout.maximumWidth: Style.space(70)
              minimum: 0
              maximum: 100
              value: root.service ? root.service.volume : 80
              onMoved: function(v) { if (root.service) root.service.setVolume(v) }
            }

            FlatButton {
              iconText: "\u{f0567}"
              selected: !!(root.service && root.service.videoActive)
              enabled: !!(root.service && root.service.hasTrack)
              foreground: root.fg
              tooltipText: root.service && root.service.videoActive ? "Close the video window" : "Watch the video"
              onClicked: root.toggleVideo()
            }
            FlatButton {
              iconText: "\u{f04c3}"
              selected: root.eqExpanded
              foreground: root.fg
              tooltipText: root.eqExpanded ? "Hide equaliser" : "Show equaliser"
              onClicked: root.eqExpanded = !root.eqExpanded
            }
          }
        }
      }
    }
  }
}
