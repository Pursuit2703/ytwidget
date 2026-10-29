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
  readonly property string iconPlaylistAdd: "\u{f0412}"
  readonly property string iconSearch: "󰍉"
  readonly property string iconNote: "󰝚"

  property string activeTab: "search"
  // Lyrics settings arrive with the open payload from the bar widget.
  property bool lyricsEnabled: true
  property string lyricsSize: "normal"
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

    if (payload.lyrics !== undefined) root.lyricsEnabled = !!payload.lyrics
    if (typeof payload.lyricsSize === "string") root.lyricsSize = payload.lyricsSize
    if (!root.lyricsEnabled && root.activeTab === "lyrics") root.activeTab = "search"
    if (payload.tab === "lyrics" && root.lyricsEnabled) { root.page = null; root.activeTab = "lyrics" }

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

  // Keys while the search box is not focused (Esc leaves it, "/" goes back
  // in). Returns true when handled.
  function playerKey(event) {
    var svc = service
    if (!svc) return false
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return false
    var seekBy = function(ms) { svc.seek(Math.max(0, Math.min(svc.durationMs, svc.positionMs + ms))) }
    var tab = function(key) { root.page = null; root.eqExpanded = false; root.activeTab = key }
    switch (event.key) {
    case Qt.Key_Space: svc.togglePlayback(); return true
    case Qt.Key_N: svc.next(); return true
    case Qt.Key_P: svc.previous(); return true
    case Qt.Key_S: svc.setShuffle(!svc.shuffle); return true
    case Qt.Key_R: svc.cycleRepeat(); return true
    case Qt.Key_Left: seekBy(-5000); return true
    case Qt.Key_Right: seekBy(5000); return true
    case Qt.Key_Up: svc.setVolume(Math.min(100, svc.volume + 5)); return true
    case Qt.Key_Down: svc.setVolume(Math.max(0, svc.volume - 5)); return true
    case Qt.Key_M: svc.setVolume(svc.volume > 0 ? 0 : 50); return true
    case Qt.Key_1: tab("search"); return true
    case Qt.Key_2: tab("queue"); return true
    case Qt.Key_3: tab("playlists"); return true
    case Qt.Key_4: tab("recent"); return true
    case Qt.Key_5:
    case Qt.Key_L: if (root.lyricsEnabled) tab("lyrics"); return true
    case Qt.Key_E: root.eqExpanded = !root.eqExpanded; return true
    case Qt.Key_V: root.toggleVideo(); return true
    case Qt.Key_Slash: tab("search"); searchField.forceActiveFocus(); return true
    }
    return false
  }

  function nudgeLyrics(deltaMs) {
    if (!service || !service.lyrics) return
    service.setLyricsOffset(Number(service.lyrics.offsetMs || 0) + deltaMs)
  }

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

  // "14 songs · 1 h 12 min" for any list of tracks.
  function lengthText(items) {
    if (!items) return ""
    var ms = 0
    for (var i = 0; i < items.length; i++) ms += Number(items[i].durationMs || 0)
    var minutes = Math.round(ms / 60000)
    var h = Math.floor(minutes / 60), m = minutes % 60
    return items.length + (items.length === 1 ? " song" : " songs")
      + (minutes > 0 ? " · " + (h > 0 ? h + " h " : "") + m + " min" : "")
  }

  function pageDurationText() { return page ? lengthText(page.items) : "" }

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
      if (!at) label = "Earlier"
      else if (at >= today.getTime()) label = "Today"
      else if (at >= today.getTime() - dayMs) label = "Yesterday"
      else label = Qt.formatDate(new Date(at), "d MMMM")
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
      id: playerScope
      anchors.fill: parent
      focus: true
      // Esc: first leaves the search box (so the keys work), then closes.
      Keys.onEscapePressed: root.close()
      Keys.onPressed: function(event) { if (root.playerKey(event)) event.accepted = true }

      // Content keeps a reading width and sits centred: on a wide or
      // maximised window the search field, tabs and player bar stay a sane
      // size instead of stretching into thin lines across the screen.
      ColumnLayout {
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.space(16)
        anchors.bottomMargin: Style.space(16)
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - Style.space(32), Style.space(900))
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
            Keys.onEscapePressed: function(event) { playerScope.forceActiveFocus(); event.accepted = true }
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
          ].concat(root.lyricsEnabled ? [{ key: "lyrics", label: "Lyrics", glyph: "\u{f0369}" }] : [])
          onPicked: function(key) { root.page = null; root.eqExpanded = false; root.activeTab = key }
        }

        // ---- Body ----
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: !root.eqExpanded

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

            Flow {
              Layout.fillWidth: true
              spacing: Style.space(8)
              Button { text: "Play all"; iconText: root.iconPlay; onClicked: root.playPage(false) }
              Button { text: "Shuffle"; iconText: root.iconShuffle; onClicked: root.playPage(true) }
              Button { text: "Add to queue"; iconText: root.iconQueueAdd; onClicked: root.addPageToQueue() }
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
            id: searchList
            visible: root.page === null && root.activeTab === "search"
            model: root.searchResults
            clip: true
            spacing: Style.space(2)
            ScrollBar.vertical: ScrollBar {}

            readonly property bool startPage: root.searchResults.length === 0
              && String(root.searchText || "").trim() === ""
              && !root.searching && !root.pageBusy
              && root.pageError === "" && root.searchError === ""

            // Before anything is typed: something useful instead of an
            // empty page repeating the placeholder.
            ColumnLayout {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.topMargin: Style.space(8)
              visible: searchList.startPage
              spacing: Style.space(12)

              SectionTitle { Layout.fillWidth: true; visible: root.history.length > 0; title: "Jump back in" }
              RowLayout {
                Layout.fillWidth: true
                visible: root.history.length > 0
                spacing: Style.space(10)
                Repeater {
                  model: root.history.slice(0, 3)
                  delegate: Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    implicitHeight: jumpCard.implicitHeight + Style.space(20)
                    radius: Style.space(14)
                    color: jumpHover.hovered ? root.rowFill : root.cardFill
                    HoverHandler { id: jumpHover }
                    ColumnLayout {
                      id: jumpCard
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
                          tooltipText: "Play"
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

              SectionTitle {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(6)
                visible: !!root.service && root.service.playlists.length > 0
                title: "Your playlists"
              }
              Flow {
                Layout.fillWidth: true
                visible: !!root.service && root.service.playlists.length > 0
                spacing: Style.space(8)
                Repeater {
                  model: root.service ? root.service.playlists : []
                  delegate: Rectangle {
                    width: chipText.implicitWidth + Style.space(28)
                    height: Style.space(32)
                    radius: height / 2
                    color: chipHover.hovered ? root.rowFillActive : root.rowFill
                    HoverHandler { id: chipHover }
                    Text {
                      id: chipText
                      anchors.centerIn: parent
                      text: modelData.name
                      color: root.fg
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openPlaylist(modelData.id)
                    }
                  }
                }
              }

              Label {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(4)
                text: root.history.length > 0
                  ? "Tip: paste a YouTube playlist link above to open it here."
                  : "Search YouTube, or paste a video or playlist link"
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Label {
              anchors.centerIn: parent
              visible: root.searchResults.length === 0 && !searchList.startPage
              text: root.pageError || root.searchError || (root.searching || root.pageBusy ? "Searching…" : "No results")
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
              SectionTitle {
                Layout.fillWidth: true
                title: "Up next"
                detail: root.service ? root.lengthText(root.service.queue) : ""
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
                SectionTitle { Layout.fillWidth: true; title: "Recently played" }
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

              SectionTitle { Layout.fillWidth: true; Layout.topMargin: Style.space(6); title: "Playlists" }

              // Smart lists first, computed from the history, then saved ones.
              // Every row has the same shape: tile, name, "N songs · length".
              ListRow {
                Layout.fillWidth: true
                visible: root.mostPlayed().length > 0
                glyph: "\u{f04ce}"
                title: "Most played"
                detail: "Your top tracks · " + root.lengthText(root.mostPlayed())
                onOpened: root.openItems("Most played", root.mostPlayed())
                onPlayed: if (root.service) root.service.playQueueFrom(root.mostPlayed(), 0)
              }
              ListRow {
                Layout.fillWidth: true
                visible: root.history.length > 0
                glyph: "\u{f02da}"
                title: "Recently played"
                detail: root.lengthText(root.history.slice(0, 25))
                onOpened: root.openItems("Recently played", root.history.slice(0, 25))
                onPlayed: if (root.service) root.service.playQueueFrom(root.history.slice(0, 25), 0)
              }

              Repeater {
                model: root.service ? root.service.playlists : []
                delegate: ListRow {
                  Layout.fillWidth: true
                  covers: modelData.covers || []
                  title: modelData.name
                  detail: modelData.count + (modelData.count === 1 ? " song" : " songs")
                  onOpened: root.openPlaylist(modelData.id)
                  onPlayed: {
                    if (!root.service) return
                    root.service.getPlaylist(modelData.id, function(ok, result) {
                      if (ok && result && result.items && result.items.length > 0)
                        root.service.playQueueFrom(result.items, 0)
                    })
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

          // ===== lyrics
          RowLayout {
            id: lyricsPage
            anchors.fill: parent
            visible: root.page === null && root.activeTab === "lyrics"
            spacing: Style.space(28)

            ColumnLayout {
              Layout.preferredWidth: Style.space(250)
              Layout.maximumWidth: Style.space(250)
              Layout.alignment: Qt.AlignTop
              visible: lyricsPage.width >= Style.space(620)
              spacing: Style.space(14)

              Rectangle {
                Layout.preferredWidth: Style.space(250)
                Layout.preferredHeight: Style.space(250)
                radius: Style.space(28)
                color: root.rowFill
                RoundedImage {
                  anchors.fill: parent
                  radius: parent.radius
                  lifted: true
                  source: root.service ? root.service.trackThumbnail : ""
                }
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Label {
                  Layout.fillWidth: true
                  text: root.service && root.service.hasTrack ? root.service.trackTitle : "Nothing playing"
                  color: root.fg
                  font.family: Style.font.family
                  font.bold: true
                  font.pixelSize: Style.font.body + 2
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
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
              // Which match the lyrics are and what they were matched to.
              Label {
                Layout.fillWidth: true
                visible: text !== ""
                text: {
                  var l = root.service ? root.service.lyrics : null
                  if (!l || !l.title || (l.status !== "synced" && l.status !== "plain")) return ""
                  var how = l.fit === "fit" ? " · lined up with the video" : (l.fit === "stretch" ? " · stretched to the video" : "")
                  return "Lyrics of " + l.artist + " – " + l.title + how
                }
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                wrapMode: Text.WordWrap
              }
              // Source and language: opens the menu to switch either.
              Rectangle {
                id: sourceChip
                visible: fullLyrics.sourceText !== ""
                Layout.preferredHeight: Style.space(26)
                Layout.preferredWidth: Math.min(sourceLabel.implicitWidth + Style.space(22), Style.space(250))
                radius: height / 2
                color: sourceArea.containsMouse || lyricsMenu.opened
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.3) : root.rowFillActive
                Text {
                  id: sourceLabel
                  anchors.centerIn: parent
                  width: Math.min(implicitWidth, Style.space(228))
                  elide: Text.ElideRight
                  text: (fullLyrics.synced ? "\u{f04e6}  " : "") + fullLyrics.sourceText + "  \u{f0140}"
                  color: root.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  id: sourceArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    lyricsMenu.y = sourceChip.height + Style.space(4)
                    lyricsMenu.open()
                  }
                }
                LyricsMenu {
                  id: lyricsMenu
                  service: root.service
                  maxHeight: Math.max(Style.space(200), lyricsPage.height - sourceChip.y - sourceChip.height - Style.space(8))
                }
              }

              // Timing, wrong match, copy
              Rectangle {
                Layout.fillWidth: true
                implicitHeight: lyricTools.implicitHeight + Style.space(20)
                radius: Style.space(14)
                color: root.cardFill
                visible: !!(root.service && root.service.hasTrack)
                ColumnLayout {
                  id: lyricTools
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  spacing: Style.space(6)

                  RowLayout {
                    Layout.fillWidth: true
                    visible: fullLyrics.synced
                    Label { Layout.fillWidth: true; text: "Timing"; color: root.fgDim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    FlatButton {
                      buttonSize: Style.space(28)
                      iconText: "\u{f0374}"
                      foreground: root.fg
                      tooltipText: "Lyrics earlier"
                      onClicked: root.nudgeLyrics(-250)
                    }
                    Label {
                      Layout.preferredWidth: Style.space(52)
                      horizontalAlignment: Text.AlignHCenter
                      text: {
                        var ms = root.service && root.service.lyrics ? Number(root.service.lyrics.offsetMs || 0) : 0
                        return (ms > 0 ? "+" : ms < 0 ? "\u2212" : "") + (Math.abs(ms) / 1000).toFixed(2).replace(/0$/, "") + "s"
                      }
                      color: root.fg
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    FlatButton {
                      buttonSize: Style.space(28)
                      iconText: "\u{f0415}"
                      foreground: root.fg
                      tooltipText: "Lyrics later"
                      onClicked: root.nudgeLyrics(250)
                    }
                  }
                  RowLayout {
                    Layout.fillWidth: true
                    Label { Layout.fillWidth: true; text: "Wrong song?"; color: root.fgDim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    Label {
                      text: "Try another match"
                      color: tryOtherArea.containsMouse ? root.accent : Qt.darker(root.accent, 1.15)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      MouseArea {
                        id: tryOtherArea
                        anchors.fill: parent
                        anchors.margins: -Style.space(4)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (root.service) root.service.lyricsTryOther()
                      }
                    }
                  }
                  RowLayout {
                    Layout.fillWidth: true
                    visible: fullLyrics.hasText
                    Label { Layout.fillWidth: true; text: "Copy lyrics"; color: root.fgDim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    FlatButton {
                      buttonSize: Style.space(28)
                      iconText: "\u{f018f}"
                      foreground: root.fg
                      tooltipText: "Copy"
                      onClicked: {
                        var out = []
                        var ls = fullLyrics.lines
                        for (var i = 0; i < ls.length; i++) out.push(String(ls[i].text || ""))
                        Quickshell.clipboardText = out.join("\n")
                      }
                    }
                  }
                }
              }
              Item { Layout.fillHeight: true }
            }

            LyricsView {
              id: fullLyrics
              Layout.fillWidth: true
              Layout.fillHeight: true
              service: root.service
              size: root.lyricsSize
              foreground: root.fg
              accent: root.accent
              fadeTo: Color.background
              active: lyricsPage.visible && root.opened
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
              SectionTitle {
                height: Style.space(36)
                title: rowData.label
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

        // ---- Equaliser: takes the body's place while it is open ----
        Rectangle {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.eqExpanded
          radius: Style.space(16)
          color: root.cardFill

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(20)
            spacing: Style.space(16)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)
              Rectangle {
                Layout.preferredWidth: Style.space(32)
                Layout.preferredHeight: Style.space(32)
                radius: Style.space(9)
                color: root.rowFillActive
                Text {
                  anchors.fill: parent
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  text: "\u{f066a}"
                  color: root.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.icon
                }
              }
              SectionTitle { Layout.fillWidth: true; title: "Equaliser" }
              Button {
                text: "Reset"
                enabled: !!root.service && root.service.eqPreset !== "Flat"
                onClicked: if (root.service) root.service.setEqPreset("Flat")
              }
              FlatButton {
                iconText: root.iconClose
                foreground: root.fg
                tooltipText: "Close"
                onClicked: root.eqExpanded = false
              }
            }

            EqGraph {
              Layout.fillWidth: true
              Layout.fillHeight: true
              service: root.service
              foreground: root.fg
              accent: root.accent
              fadeTo: Color.background
            }
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
          Layout.preferredHeight: Style.space(92)
          Layout.minimumWidth: 0
          radius: Style.space(16)
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
          // What fits depends on the window: the window is user-resizable and
          // tiling can make it narrow, and a row that does not fit pushes the
          // whole layout past the window edge.
          readonly property bool roomy: width >= Style.space(760)
          readonly property bool medium: width >= Style.space(620)
          readonly property bool tight: width < Style.space(500)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(12)

            Rectangle {
              Layout.preferredWidth: Style.space(68)
              Layout.preferredHeight: Style.space(68)
              radius: Style.space(16)
              color: root.rowFill
              RoundedImage {
                anchors.fill: parent
                radius: parent.radius
                source: root.service ? root.service.trackThumbnail : ""
              }
            }

            ColumnLayout {
              visible: parent.parent.medium
              Layout.preferredWidth: Style.space(200)
              Layout.maximumWidth: Style.space(200)
              Layout.minimumWidth: 0
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
                buttonSize: Style.space(52)
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
              visible: parent.parent.roomy
              text: Api.formatTime(root.service ? root.service.positionMs : 0)
              color: root.fgDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            PanelSlider {
              Layout.fillWidth: true
              Layout.minimumWidth: Style.space(40)
              minimum: 0
              maximum: Math.max(1, root.service ? root.service.durationMs : 1)
              value: root.service ? root.service.positionMs : 0
              onMoved: function(v) { if (root.service) root.service.seek(v) }
            }
            Label {
              visible: parent.parent.roomy
              text: Api.formatTime(root.service ? root.service.durationMs : 0)
              color: root.fgDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Label {
              visible: parent.parent.roomy
              text: "\u{f057e}"
              color: root.fgDim
              font.family: Style.font.family
              font.pixelSize: Style.font.icon
            }
            PanelSlider {
              visible: parent.parent.roomy
              Layout.preferredWidth: Style.space(70)
              Layout.maximumWidth: Style.space(70)
              minimum: 0
              maximum: 100
              value: root.service ? root.service.volume : 80
              onMoved: function(v) { if (root.service) root.service.setVolume(v) }
            }

            FlatButton {
              visible: !parent.parent.tight
              iconText: "\u{f0567}"
              selected: !!(root.service && root.service.videoActive)
              enabled: !!(root.service && root.service.hasTrack)
              foreground: root.fg
              tooltipText: root.service && root.service.videoActive ? "Close the video window" : "Watch the video"
              onClicked: root.toggleVideo()
            }
            FlatButton {
              visible: !parent.parent.tight
              iconText: "\u{f066a}"
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
