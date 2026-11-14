import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

import "Api.js" as Api

// The full player. A normal app window: it tiles, floats and maximises like
// any other, and its layout follows its size.
//
//   >= 1100 px   sidebar · content · now-playing pane, player bar below
//   760-1100     sidebar · content (the pane's job moves to the player bar)
//   560-760      icon rail · content
//   < 560        content, player bar, tabs along the bottom
//
// The accent and the tinted surfaces come from the cover art (AlbumTint).
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false

  readonly property color fg: Color.foreground
  readonly property color fgDim: Qt.darker(Color.foreground, 1.6)
  readonly property color accent: tint.accentAnimated
  readonly property color onAccent: tint.onAccent
  readonly property color deep: tint.deepAnimated
  readonly property color glow: tint.glowAnimated
  readonly property color windowBg: Qt.darker(Color.background, 1.3)
  readonly property color paneBg: Color.background
  readonly property color rowFill: Qt.rgba(fg.r, fg.g, fg.b, 0.05)
  readonly property color rowFillActive: Qt.rgba(accent.r, accent.g, accent.b, 0.16)
  readonly property color cardFill: Qt.rgba(fg.r, fg.g, fg.b, 0.04)

  readonly property string iconPlay: "\u{f040a}"
  readonly property string iconShuffle: "\u{f049f}"
  readonly property string iconClose: "\u{f0156}"
  readonly property string iconQueueAdd: "\u{f0415}"
  readonly property string iconPlaylistAdd: "\u{f0412}"
  readonly property string iconSearch: "\u{f0349}"
  readonly property string iconNote: "\u{f075a}"
  readonly property string iconHome: "\u{f02dc}"
  readonly property string iconLibrary: "\u{f0cb8}"
  readonly property string iconRecent: "\u{f02da}"
  readonly property string iconLyrics: "\u{f0369}"
  readonly property string iconStar: "\u{f04ce}"
  readonly property string iconLink: "\u{f0337}"
  readonly property string iconBack: "\u{f004d}"
  readonly property string iconDelete: "\u{f01b4}"
  readonly property string iconEq: "\u{f066a}"
  readonly property string iconVideo: "\u{f0567}"

  property string activeTab: "search"     // search | queue | playlists | recent | lyrics
  property bool lyricsEnabled: true
  property string lyricsSize: "normal"
  property string searchText: ""
  property var searchResults: []
  property bool searching: false
  property string searchError: ""
  property var page: null                 // { id, name, items, fromLink, virtual }
  property bool pageBusy: false
  property string pageError: ""
  property bool eqOpen: false
  // Karaoke covers the whole window (see KaraokeView.qml).
  property bool karaoke: false
  // The now-playing pane can be put away on a wide window.
  property bool paneHidden: false
  property bool addingPlaylist: false
  property string karaokeSize: "large"
  readonly property var history: service ? service.playHistory : []

  // Everything is drawn larger on a big screen: 1080p is 1x, 1440p 1.33x,
  // 4K 2x (logical pixels, so a Hyprland output scale is already counted).
  // A small window gives the zoom back, so tiles keep room for content.
  readonly property real screenZoom: {
    var h = window.screen ? Number(window.screen.height) : 1080
    return Math.max(1, Math.min(2, (h || 1080) / 1080))
  }
  readonly property real zoom: Math.max(1, Math.min(root.screenZoom,
    window.width / 760, window.height / 560))

  // ---- layout steps, from the window's width (in zoomed pixels) ----
  readonly property real winW: window.width / root.zoom
  readonly property bool wide: winW >= Style.space(1100)
  readonly property bool sidebarFull: winW >= Style.space(760)
  readonly property bool compact: winW < Style.space(560)
  readonly property bool railOnly: !sidebarFull && !compact
  readonly property real winH: window.height / root.zoom
  // Short window: page headers shrink so the content keeps its room.
  readonly property bool shortWin: winH < Style.space(720)
  // Very small window: only the player bar.
  readonly property bool barOnly: winH < Style.space(380) || winW < Style.space(340)

  function open(payloadJson) {
    opened = true
    if (service) service.ensureRunning()

    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") || ({}) } catch (e) { payload = ({}) }

    if (payload.lyrics !== undefined) root.lyricsEnabled = !!payload.lyrics
    if (typeof payload.lyricsSize === "string") root.lyricsSize = payload.lyricsSize
    if (!root.lyricsEnabled && root.activeTab === "lyrics") root.activeTab = "search"
    if (payload.tab === "lyrics" && root.lyricsEnabled) { root.page = null; root.activeTab = "lyrics" }
    if (payload.tab === "karaoke" && root.lyricsEnabled) root.enterKaraoke()

    var handed = typeof payload.search === "string" ? payload.search : ""
    if (handed.trim() !== "") {
      root.page = null
      root.activeTab = "search"
      root.searchError = ""
      root.searchText = handed
      if (Array.isArray(payload.results) && payload.results.length > 0)
        root.searchResults = payload.results
      liveSearchTimer.stop()
      if (!root.searchIsLink) runSearch()
      else if (root.searchIsPlaylist) previewLink()
    }

    // Typing goes to search on open, except in karaoke, where the keys are
    // the karaoke's own.
    Qt.callLater(function() {
      if (root.karaoke) playerScope.forceActiveFocus()
      else if (searchField) searchField.forceActiveFocus()
    })
  }
  function close() { if (karaoke) exitKaraoke(); opened = false }

  function enterKaraoke() {
    if (!root.lyricsEnabled) return
    root.page = null
    root.activeTab = "lyrics"
    root.karaoke = true
    Qt.callLater(function() { playerScope.forceActiveFocus() })
  }
  function exitKaraoke() {
    root.karaoke = false
  }

  function showTab(key) {
    root.page = null
    if (!root.wide) root.eqOpen = false
    root.activeTab = key
  }

  function goHome() {
    root.showTab("search")
    root.searchText = ""
    root.searchResults = []
    root.searchError = ""
    root.pageError = ""
  }

  // Keys while the search box is not focused (Esc leaves it, "/" goes back
  // in). Returns true when handled.
  function playerKey(event) {
    var svc = service
    if (!svc) return false
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return false
    var seekBy = function(ms) { svc.seek(Math.max(0, Math.min(svc.durationMs, svc.positionMs + ms))) }
    if (root.karaoke) {
      switch (event.key) {
      case Qt.Key_Space: if (!karaokeView.skipAhead()) svc.togglePlayback(); return true
      case Qt.Key_Left: if (!karaokeView.stepLine(-1)) seekBy(-5000); return true
      case Qt.Key_Right: if (!karaokeView.stepLine(1)) seekBy(5000); return true
      case Qt.Key_BracketLeft: root.nudgeLyrics(-250); return true
      case Qt.Key_BracketRight: root.nudgeLyrics(250); return true
      case Qt.Key_T: svc.lyricsTryOther(); return true
      case Qt.Key_K: root.exitKaraoke(); return true
      case Qt.Key_1: case Qt.Key_2: case Qt.Key_3: case Qt.Key_4: case Qt.Key_5:
      case Qt.Key_L: case Qt.Key_E: case Qt.Key_Slash:
        return true
      }
    }
    switch (event.key) {
    case Qt.Key_K: root.enterKaraoke(); return true
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
    case Qt.Key_1: root.showTab("search"); return true
    case Qt.Key_2: root.showTab("queue"); return true
    case Qt.Key_3: root.showTab("playlists"); return true
    case Qt.Key_4: root.showTab("recent"); return true
    case Qt.Key_5:
    case Qt.Key_L: if (root.lyricsEnabled) root.showTab("lyrics"); return true
    case Qt.Key_E: root.eqOpen = !root.eqOpen; return true
    case Qt.Key_V: root.toggleVideo(); return true
    case Qt.Key_Slash: root.showTab("search"); searchField.forceActiveFocus(); return true
    }
    return false
  }

  function nudgeLyrics(deltaMs) {
    if (!service || !service.lyrics) return
    service.setLyricsOffset(Number(service.lyrics.offsetMs || 0) + deltaMs)
  }

  readonly property bool searchIsLink: Api.isYouTubeLink(root.searchText)
  readonly property bool searchIsPlaylist: searchIsLink && /[?&]list=/.test(root.searchText)

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

  function pageSource() {
    if (!page) return null
    return { kind: page.virtual ? (page.name === "Most played" ? "most" : "recent") : (page.fromLink ? "link" : "saved"),
             id: page.id || "", name: page.name }
  }

  function playPage(shuffle) {
    if (!page || !service) return
    if (shuffle) service.setShuffle(true)
    service.playQueueFrom(page.items, 0, pageSource())
  }

  // Is this library row what the queue is playing from?
  function isPlayingFrom(row) {
    var src = service ? service.queueSource : null
    if (!src || !row) return false
    if (row.kind === "saved") return src.kind === "saved" && src.id === row.id
    return src.kind === row.kind
  }

  function addPageToQueue() {
    if (!page || !service) return
    service.addAllToQueue(page.items, function() {})
  }

  function savePage() {
    if (!page || !service || page.id !== "") return
    service.createPlaylist(page.name, page.items, function(ok) {
      if (!ok) return
      service.listPlaylists(function() {})
      root.page = null
      root.searchText = ""
      root.activeTab = "playlists"
    })
  }

  function saveQueueAsPlaylist() {
    if (!service || service.queue.length === 0) return
    var name = "Queue · " + Qt.formatDateTime(new Date(), "d MMM HH:mm")
    service.createPlaylist(name, null, function(ok) { if (ok) service.listPlaylists(function() {}) })
  }

  // History grouped by day, newest first: { header, label } rows are day
  // headers, the rest are tracks.
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

  readonly property var mostPlayedItems: {
    var rows = []
    for (var i = 0; i < root.history.length; i++)
      if (Number(root.history[i].plays || 0) >= 2) rows.push(root.history[i])
    rows.sort(function(a, b) { return Number(b.plays) - Number(a.plays) })
    return rows.slice(0, 50)
  }

  // Everything the Library lists, smart lists first, all the same shape.
  readonly property var libraryRows: {
    var out = []
    if (root.mostPlayedItems.length > 0)
      out.push({ kind: "most", name: "Most played", detail: "Smart list · " + root.mostPlayedItems.length + " songs", glyph: root.iconStar, covers: [] })
    if (root.history.length > 0)
      out.push({ kind: "recent", name: "Recently played", detail: "Smart list · " + Math.min(25, root.history.length) + " songs", glyph: root.iconRecent, covers: [] })
    var pls = service ? service.playlists : []
    for (var i = 0; i < pls.length; i++)
      out.push({ kind: "saved", id: pls[i].id, name: pls[i].name, detail: "Playlist · " + pls[i].count + (pls[i].count === 1 ? " song" : " songs"), glyph: "", covers: pls[i].covers || [] })
    return out
  }

  function openLibraryRow(row) {
    if (row.kind === "most") root.openItems("Most played", root.mostPlayedItems)
    else if (row.kind === "recent") root.openItems("Recently played", root.history.slice(0, 25))
    else root.openPlaylist(row.id)
  }

  function playLibraryRow(row) {
    if (!service) return
    var src = { kind: row.kind, id: row.id || "", name: row.name }
    if (row.kind === "most") service.playQueueFrom(root.mostPlayedItems, 0, src)
    else if (row.kind === "recent") service.playQueueFrom(root.history.slice(0, 25), 0, src)
    else service.getPlaylist(row.id, function(ok, result) {
      if (ok && result && result.items && result.items.length > 0) service.playQueueFrom(result.items, 0, src)
    })
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

  // Enter on a pasted link loads it rather than searching for it.
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
    else { root.page = null; root.activeTab = "search"; runSearch() }
  }

  function toggleVideo() {
    if (!service || !service.hasTrack) return
    if (service.videoActive) service.hideVideo()
    else service.showVideo("")
  }

  function queueIndexFor(videoId) {
    if (!root.service || !videoId) return -1
    var q = root.service.queue || []
    for (var i = 0; i < q.length; i++) if (q[i] && q[i].videoId === videoId) return i
    return -1
  }

  function openPlaylist(playlistId) {
    if (!service) return
    service.getPlaylist(playlistId, function(ok, result) {
      if (!ok) return
      root.page = { id: playlistId, name: (result && result.name) || playlistId, items: (result && result.items) || [],
                    fromLink: false, createdAt: Number((result && result.createdAt) || 0) }
    })
  }

  function openItems(title, items) {
    root.page = { id: "", name: title, items: items, fromLink: false, virtual: true }
  }

  // Up next: what follows the current track.
  readonly property var upNext: {
    var q = service ? service.queue : []
    var i = service ? service.queueIndex : -1
    return q.slice(Math.max(0, i + 1), Math.max(0, i + 1) + 6)
  }

  onOpenedChanged: {
    if (!opened || !service) return
    service.listPlaylists(function() {})
    if (service.hasTrack && !service.videoReady) service.prepareVideo("")
  }

  // ---- small pieces -------------------------------------------------------

  // A sidebar / bottom-tab entry.
  component NavItem: Rectangle {
    id: nav
    property string glyph: ""
    property string label: ""
    property string badge: ""
    property bool current: false
    property bool iconOnly: false
    property color fg: Color.foreground
    property color accent: Color.accent
    signal picked()
    implicitHeight: Style.space(40)
    radius: Style.space(8)
    color: current ? Qt.rgba(fg.r, fg.g, fg.b, 0.09)
      : (navArea.containsMouse ? Qt.rgba(fg.r, fg.g, fg.b, 0.05) : "transparent")
    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: nav.iconOnly ? 0 : Style.space(12)
      anchors.rightMargin: nav.iconOnly ? 0 : Style.space(12)
      spacing: Style.space(14)
      Text {
        Layout.fillWidth: nav.iconOnly
        horizontalAlignment: Text.AlignHCenter
        text: nav.glyph
        color: nav.current ? nav.accent : Qt.darker(nav.fg, 1.25)
        font.family: Style.font.family
        font.pixelSize: Style.font.icon + 2
      }
      Text {
        visible: !nav.iconOnly
        Layout.fillWidth: true
        text: nav.label
        color: nav.current ? nav.fg : Qt.darker(nav.fg, 1.25)
        font.family: Style.font.family
        font.bold: nav.current
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        visible: !nav.iconOnly && nav.badge !== ""
        text: nav.badge
        color: Qt.darker(nav.fg, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
    MouseArea {
      id: navArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: nav.picked()
    }
    PanelToolTip {
      visible: nav.iconOnly && navArea.containsMouse
      text: nav.label
    }
  }

  // A 2x2 cover mosaic, or a glyph tile for smart lists.
  component CoverTile: Rectangle {
    id: tile
    property var covers: []
    property string glyph: ""
    property color accent: Color.accent
    radius: Style.space(8)
    clip: true
    color: glyph !== "" ? Qt.rgba(accent.r, accent.g, accent.b, 0.18) : Qt.rgba(1, 1, 1, 0.06)
    Text {
      anchors.centerIn: parent
      visible: tile.glyph !== ""
      text: tile.glyph
      color: tile.accent
      font.family: Style.font.family
      font.pixelSize: Math.max(Style.font.icon, tile.height * 0.4)
    }
    Grid {
      anchors.fill: parent
      visible: tile.glyph === ""
      columns: (tile.covers || []).length >= 4 ? 2 : 1
      Repeater {
        model: (tile.covers || []).length >= 4 ? tile.covers.slice(0, 4) : (tile.covers || []).slice(0, 1)
        delegate: Image {
          required property var modelData
          width: parent.columns === 2 ? tile.width / 2 : tile.width
          height: parent.columns === 2 ? tile.height / 2 : tile.height
          source: modelData
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }
    }
  }

  // A pill button with text, for page actions.
  component Pill: Rectangle {
    id: pill
    property string glyph: ""
    property string label: ""
    property bool filled: false
    property bool danger: false
    property color accent: Color.accent
    property color onAccent: Color.background
    property bool enabledPill: true
    signal picked()
    implicitHeight: Style.space(36)
    implicitWidth: pillRow.implicitWidth + Style.space(32)
    radius: height / 2
    opacity: enabledPill ? 1 : 0.5
    color: filled ? (pillArea.pressed ? Qt.darker(accent, 1.1) : accent)
      : (pillArea.containsMouse ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
                                : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08))
    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.space(8)
      Text {
        visible: pill.glyph !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: pill.glyph
        color: pill.filled ? pill.onAccent : (pill.danger ? Color.urgent : Color.foreground)
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: pill.label
        color: pill.filled ? pill.onAccent : (pill.danger ? Color.urgent : Color.foreground)
        font.family: Style.font.family
        font.bold: pill.filled
        font.pixelSize: Style.font.caption + 1
      }
    }
    MouseArea {
      id: pillArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: pill.enabledPill
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.picked()
    }
  }

  // A heading with an optional action on the right.
  component Heading: RowLayout {
    id: heading
    property string title: ""
    property string action: ""
    property bool big: false
    signal actionPicked()
    spacing: Style.space(10)
    Text {
      Layout.fillWidth: true
      text: heading.title
      color: Color.foreground
      font.family: Style.font.family
      font.bold: true
      font.pixelSize: heading.big ? Style.font.subtitle + 6 : Style.font.subtitle
      elide: Text.ElideRight
    }
    Text {
      visible: heading.action !== ""
      text: heading.action
      color: actionArea.containsMouse ? Color.foreground : Qt.darker(Color.foreground, 1.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      MouseArea {
        id: actionArea
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: heading.actionPicked()
      }
    }
  }

  // Video window quality / speed, while one is open.
  component VideoControls: RowLayout {
    id: vc
    property var service: null
    spacing: Style.space(8)
    Text {
      text: "\u{f0567}"
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.icon
    }
    Text {
      Layout.fillWidth: true
      text: "Video window"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption + 1
      elide: Text.ElideRight
    }
    Dropdown {
      Layout.preferredWidth: Style.space(100)
      showLabel: false
      options: {
        var out = []
        var hs = vc.service ? vc.service.videoHeights : []
        for (var i = 0; i < hs.length; i++) out.push({ value: String(hs[i]), label: hs[i] + "p" })
        return out
      }
      value: vc.service ? String(vc.service.videoHeight) : ""
      onChanged: function(value) { if (vc.service) vc.service.setVideoQuality(parseInt(value, 10)) }
    }
    Dropdown {
      Layout.preferredWidth: Style.space(100)
      showLabel: false
      options: {
        var out = []
        var sp = vc.service ? vc.service.videoSpeeds : []
        for (var i = 0; i < sp.length; i++) out.push({ value: String(sp[i]), label: (sp[i] === 1 ? "Normal" : sp[i] + "x") })
        return out
      }
      value: vc.service ? String(vc.service.videoSpeed) : "1"
      onChanged: function(value) { if (vc.service) vc.service.setVideoSpeed(parseFloat(value)) }
    }
    FlatButton {
      buttonSize: Style.space(30)
      iconText: "\u{f0156}"
      foreground: Color.foreground
      tooltipText: "Close the video window"
      onClicked: if (vc.service) vc.service.hideVideo()
    }
  }

  // ---- the window ---------------------------------------------------------

  FloatingWindow {
    id: window
    visible: root.opened
    title: "YT Widget"
    color: root.windowBg
    implicitWidth: 1240
    implicitHeight: 800
    // No maximum: tiled, maximised or fullscreen, the layout uses the space.
    minimumSize: Qt.size(380, 480)

    onVisibleChanged: if (!visible && root.opened) root.close()

    // Reads the cover's colours. Sits under everything else.
    AlbumTint {
      id: tint
      x: 0
      y: 0
      source: root.service ? root.service.trackThumbnail : ""
      base: Color.background
    }

    FocusScope {
      id: playerScope
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.karaoke ? root.exitKaraoke() : root.close()
      Keys.onPressed: function(event) { if (root.playerKey(event)) event.accepted = true }

      Rectangle { anchors.fill: parent; color: root.windowBg }

      // Clicking anywhere that is not a text field gives the keys back to
      // the player (Space, N/P, arrows…). Without this a click on a list or
      // a button left the keyboard with the search box.
      TapHandler {
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        gesturePolicy: TapHandler.DragThreshold
        grabPermissions: PointerHandler.TakeOverForbidden
        onTapped: if (!searchField.activeFocus || root.karaoke) playerScope.forceActiveFocus()
      }

      Item {
        id: zoomed
        width: parent.width / root.zoom
        height: parent.height / root.zoom
        scale: root.zoom
        transformOrigin: Item.TopLeft

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.space(8)

        RowLayout {
          visible: !root.barOnly
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(8)

          // ===================== sidebar / rail =====================
          Rectangle {
            visible: !root.compact
            Layout.fillHeight: true
            Layout.preferredWidth: root.sidebarFull ? Style.space(248) : Style.space(64)
            radius: Style.space(12)
            color: root.paneBg

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(root.sidebarFull ? 12 : 8)
              spacing: Style.space(4)

              RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: Style.space(10)
                spacing: Style.space(10)
                Rectangle {
                  Layout.preferredWidth: Style.space(30)
                  Layout.preferredHeight: Style.space(30)
                  Layout.alignment: root.sidebarFull ? Qt.AlignLeft : Qt.AlignHCenter
                  Layout.leftMargin: root.sidebarFull ? Style.space(8) : 0
                  radius: Style.space(8)
                  color: root.accent
                  Text {
                    anchors.centerIn: parent
                    text: root.iconNote
                    color: root.onAccent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.icon
                  }
                }
                Text {
                  visible: root.sidebarFull
                  Layout.fillWidth: true
                  text: "YT Widget"
                  color: root.fg
                  font.family: Style.font.family
                  font.bold: true
                  font.pixelSize: Style.font.body + 1
                }
                FlatButton {
                  visible: root.sidebarFull
                  buttonSize: Style.space(28)
                  iconText: root.iconClose
                  foreground: root.fgDim
                  accent: root.accent
                  tooltipText: "Close (Esc)"
                  onClicked: root.close()
                }
              }

              Repeater {
                model: [
                  { key: "home", label: "Home", glyph: root.iconHome },
                  { key: "search", label: "Search", glyph: root.iconSearch },
                  { key: "queue", label: "Queue", glyph: root.iconNote }
                ].concat(root.sidebarFull ? [] : [{ key: "playlists", label: "Library", glyph: root.iconLibrary }])
                 .concat([{ key: "recent", label: "Recent", glyph: root.iconRecent }])
                 .concat(root.lyricsEnabled ? [{ key: "lyrics", label: "Lyrics", glyph: root.iconLyrics }] : [])
                delegate: NavItem {
                  required property var modelData
                  Layout.fillWidth: true
                  glyph: modelData.glyph
                  label: modelData.label
                  iconOnly: !root.sidebarFull
                  accent: root.accent
                  badge: modelData.key === "queue" && root.service && root.service.queue.length > 0 ? String(root.service.queue.length) : ""
                  current: root.page === null && (
                    modelData.key === "home" ? (root.activeTab === "search" && root.searchText === "")
                    : modelData.key === "search" ? (root.activeTab === "search" && root.searchText !== "")
                    : root.activeTab === modelData.key)
                  onPicked: {
                    if (modelData.key === "home") root.goHome()
                    else if (modelData.key === "search") { root.showTab("search"); searchField.forceActiveFocus() }
                    else root.showTab(modelData.key)
                  }
                }
              }

              RowLayout {
                visible: root.sidebarFull
                Layout.fillWidth: true
                Layout.topMargin: Style.space(14)
                Layout.leftMargin: Style.space(12)
                spacing: Style.space(4)
                Text {
                  Layout.fillWidth: true
                  text: "LIBRARY"
                  color: root.fgDim
                  font.family: Style.font.family
                  font.bold: true
                  font.letterSpacing: 1
                  font.pixelSize: Style.font.caption
                }
                FlatButton {
                  buttonSize: Style.space(28)
                  iconText: root.addingPlaylist ? root.iconClose : root.iconQueueAdd
                  foreground: root.fgDim
                  accent: root.accent
                  tooltipText: root.addingPlaylist ? "Cancel" : "New playlist"
                  onClicked: {
                    root.addingPlaylist = !root.addingPlaylist
                    if (root.addingPlaylist) Qt.callLater(function() { newPlaylistField.forceActiveFocus() })
                  }
                }
              }
              Rectangle {
                visible: root.sidebarFull && root.addingPlaylist
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(36)
                radius: Style.space(8)
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
                border.width: 1
                border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5)
                TextField {
                  id: newPlaylistField
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  background: Item {}
                  horizontalPadding: 0
                  placeholderText: "Name, then Enter"
                  onAccepted: {
                    var name = text.trim()
                    if (!name || !root.service) return
                    root.service.createPlaylist(name, [], function(ok) {
                      if (ok) root.service.listPlaylists(function() {})
                    })
                    text = ""
                    root.addingPlaylist = false
                  }
                  Keys.onEscapePressed: function(event) { root.addingPlaylist = false; playerScope.forceActiveFocus(); event.accepted = true }
                }
              }
              Rectangle {
                visible: !root.sidebarFull && root.libraryRows.length > 0
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Style.space(8)
                Layout.bottomMargin: Style.space(4)
                width: Style.space(28)
                height: 1
                color: root.rowFill
              }

              ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Style.space(2)
                model: root.libraryRows
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                  id: libRow
                  required property var modelData
                  readonly property bool current: root.page !== null && (
                    (modelData.kind === "saved" && root.page.id === modelData.id)
                    || (modelData.kind !== "saved" && root.page.virtual && root.page.name === modelData.name))
                  readonly property bool playingFrom: root.isPlayingFrom(modelData)
                  width: ListView.view.width
                  height: Style.space(root.sidebarFull ? 52 : 48)
                  radius: Style.space(8)
                  color: current ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.09)
                    : (libHover.hovered ? root.rowFill : "transparent")
                  HoverHandler { id: libHover }
                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: root.sidebarFull ? Style.space(6) : 0
                    anchors.rightMargin: root.sidebarFull ? Style.space(6) : 0
                    spacing: Style.space(12)
                    CoverTile {
                      Layout.preferredWidth: Style.space(40)
                      Layout.preferredHeight: Style.space(40)
                      Layout.alignment: root.sidebarFull ? Qt.AlignLeft : Qt.AlignHCenter
                      covers: libRow.modelData.covers
                      glyph: libRow.modelData.glyph
                      accent: root.accent
                    }
                    ColumnLayout {
                      visible: root.sidebarFull
                      Layout.fillWidth: true
                      spacing: Style.space(2)
                      Text {
                        Layout.fillWidth: true
                        text: libRow.modelData.name
                        textFormat: Text.PlainText
                        color: libRow.current || libRow.playingFrom ? root.accent : root.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption + 1
                        elide: Text.ElideRight
                      }
                      Text {
                        Layout.fillWidth: true
                        text: libRow.playingFrom ? "Playing from" : libRow.modelData.detail
                        color: root.fgDim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                    NowBars {
                      visible: root.sidebarFull && libRow.playingFrom && !libHover.hovered
                      color: root.accent
                      running: !!(root.service && root.service.effectivePlaying)
                    }
                    FlatButton {
                      visible: root.sidebarFull && libHover.hovered
                      buttonSize: Style.space(30)
                      iconText: root.iconPlay
                      foreground: root.accent
                      accent: root.accent
                      tooltipText: "Play"
                      onClicked: root.playLibraryRow(libRow.modelData)
                    }
                  }
                  MouseArea {
                    z: -1
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openLibraryRow(libRow.modelData)
                  }
                  PanelToolTip {
                    visible: !root.sidebarFull && libHover.hovered
                    text: libRow.modelData.name
                  }
                }
              }
            }
          }

          // ===================== main =====================
          Rectangle {
            id: mainPane
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.space(12)
            color: root.paneBg
            clip: true

            // The cover's colour washing down from the top on the song's own
            // pages (lyrics) and on playlist pages.
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: root.page === null ? parent.height * 0.75 : Style.space(320)
              visible: (root.page !== null || (root.activeTab === "lyrics" && !root.eqOpen)) && tint.found
              gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(root.glow.r, root.glow.g, root.glow.b, 0.85) }
                GradientStop { position: 1.0; color: Qt.rgba(root.glow.r, root.glow.g, root.glow.b, 0.0) }
              }
            }

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(root.compact ? 14 : 20)
              spacing: Style.space(14)

              // ---- search ----
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(10)

                Rectangle {
                  Layout.fillWidth: true
                  Layout.maximumWidth: Style.space(680)
                  Layout.preferredHeight: Style.space(46)
                  radius: height / 2
                  color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, searchField.activeFocus ? 0.10 : 0.07)
                  border.width: 1
                  border.color: root.searchIsLink ? root.accent
                    : (searchField.activeFocus ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.22) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08))

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(16)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(10)
                    Text {
                      text: root.searchIsLink ? root.iconLink : root.iconSearch
                      color: root.searchIsLink ? root.accent : root.fgDim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.icon + 2
                    }
                    TextField {
                      id: searchField
                      enabled: !root.karaoke
                      Layout.fillWidth: true
                      background: Item {}
                      horizontalPadding: 0
                      font.pixelSize: Style.font.body + 1
                      placeholderText: root.compact ? "Search, or paste a link" : "Search YouTube, or paste a video / playlist link"
                      text: root.searchText
                      onTextChanged: {
                        if (root.searchText === text) return
                        root.searchText = text
                        if (root.page && root.page.fromLink) root.page = null
                        root.pageError = ""
                        if (text.trim() !== "" && (root.activeTab !== "search" || root.page !== null)) {
                          root.page = null
                          root.activeTab = "search"
                        }
                        if (root.searchIsLink) {
                          liveSearchTimer.stop()
                          if (root.searchIsPlaylist) previewTimer.restart()
                        } else liveSearchTimer.restart()
                      }
                      onAccepted: root.submitSearchField()
                      Keys.onEscapePressed: function(event) { playerScope.forceActiveFocus(); event.accepted = true }
                    }
                    Rectangle {
                      visible: root.searchIsLink
                      Layout.preferredHeight: Style.space(24)
                      Layout.preferredWidth: linkTag.implicitWidth + Style.space(18)
                      radius: height / 2
                      color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                      Text {
                        id: linkTag
                        anchors.centerIn: parent
                        text: !root.searchIsPlaylist ? "Video link"
                          : (root.pageBusy ? "Reading playlist…"
                             : (root.page && root.page.fromLink ? "Playlist · " + root.page.items.length : "Playlist link"))
                        color: root.accent
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                    Text {
                      visible: root.searchText === "" && !root.compact
                      text: "/"
                      color: root.fgDim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    FlatButton {
                      visible: root.searchText !== ""
                      buttonSize: Style.space(28)
                      iconText: root.iconClose
                      foreground: root.fgDim
                      accent: root.accent
                      tooltipText: "Clear"
                      onClicked: { root.goHome(); searchField.forceActiveFocus() }
                    }
                  }
                }

                Pill {
                  visible: root.searchIsLink && !root.searchIsPlaylist
                  filled: true
                  glyph: root.iconPlay
                  label: root.searching ? "Opening…" : "Open link"
                  accent: root.accent
                  onAccent: root.onAccent
                  onPicked: root.submitSearchField()
                }
                Pill {
                  visible: root.searchIsLink && !root.searchIsPlaylist
                  glyph: root.iconQueueAdd
                  label: root.enqueuingLink ? "Queueing…" : "Add to queue"
                  enabledPill: !root.enqueuingLink
                  onPicked: root.enqueueLinkNow()
                }
                FlatButton {
                  visible: root.wide && root.paneHidden
                  buttonSize: Style.space(36)
                  iconText: "\u{f0293}"
                  foreground: root.fgDim
                  accent: root.accent
                  tooltipText: "Show the now playing pane"
                  onClicked: root.paneHidden = false
                }
                FlatButton {
                  visible: !root.sidebarFull
                  buttonSize: Style.space(36)
                  iconText: root.iconClose
                  foreground: root.fgDim
                  accent: root.accent
                  tooltipText: "Close (Esc)"
                  onClicked: root.close()
                }
              }

              Text {
                visible: root.searchIsLink
                Layout.fillWidth: true
                Layout.topMargin: -Style.space(8)
                leftPadding: Style.space(18)
                text: root.searchIsPlaylist
                  ? "A playlist link opens its page here. Nothing is saved until you press Save."
                  : "Enter opens it now. Add to queue keeps what's playing."
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Timer { id: liveSearchTimer; interval: 300; repeat: false; onTriggered: root.runSearch() }
              Timer { id: previewTimer; interval: 450; repeat: false; onTriggered: root.previewLink() }

              // ---- body ----
              Item {
                id: body
                Layout.fillWidth: true
                Layout.fillHeight: true
                readonly property bool eqHere: root.eqOpen && !root.wide

                // ===== playlist page
                ColumnLayout {
                  anchors.fill: parent
                  visible: root.page !== null && !body.eqHere
                  spacing: Style.space(14)

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(root.compact ? 14 : 22)

                    FlatButton {
                      visible: !(root.page && root.page.fromLink)
                      Layout.alignment: Qt.AlignTop
                      iconText: root.iconBack
                      foreground: root.fg
                      accent: root.accent
                      tooltipText: "Back"
                      onClicked: root.page = null
                    }
                    CoverTile {
                      readonly property real side: Style.space(root.shortWin ? 72 : (root.compact ? 96 : 168))
                      Layout.preferredWidth: side
                      Layout.preferredHeight: side
                      radius: Style.space(12)
                      accent: root.accent
                      covers: {
                        var out = []
                        var items = root.page ? root.page.items : []
                        for (var i = 0; i < items.length && out.length < 4; i++)
                          if (items[i].thumbnail) out.push(items[i].thumbnail)
                        return out
                      }
                    }
                    ColumnLayout {
                      Layout.fillWidth: true
                      Layout.alignment: Qt.AlignBottom
                      spacing: Style.space(6)
                      Text {
                        text: !root.page ? "" : (root.page.fromLink ? "FROM A LINK · NOT SAVED YET"
                          : (root.page.virtual ? "SMART LIST" : "PLAYLIST"))
                        color: root.accent
                        font.family: Style.font.family
                        font.bold: true
                        font.letterSpacing: 1
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        Layout.fillWidth: true
                        text: root.page ? root.page.name : ""
                        textFormat: Text.PlainText
                        color: root.fg
                        font.family: Style.font.family
                        font.bold: true
                        font.pixelSize: root.compact ? Style.font.subtitle + 2 : Style.font.subtitle + 12
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                      }
                      Text {
                        text: !root.page ? "" : root.lengthText(root.page.items)
                          + (root.page.createdAt > 0 ? " · saved " + Qt.formatDate(new Date(root.page.createdAt * 1000), "d MMM") : "")
                        color: root.fgDim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(8)
                    FlatButton {
                      primary: true
                      buttonSize: Style.space(52)
                      iconSize: Style.font.iconLarge
                      iconText: root.iconPlay
                      accent: root.accent
                      onAccent: root.onAccent
                      tooltipText: "Play all"
                      onClicked: root.playPage(false)
                    }
                    Pill { glyph: root.iconShuffle; label: "Shuffle"; onPicked: root.playPage(true) }
                    Pill { visible: !root.compact; glyph: root.iconQueueAdd; label: "Add to queue"; onPicked: root.addPageToQueue() }
                    Pill {
                      visible: !!root.page && root.page.id === "" && !root.page.virtual
                      glyph: root.iconPlaylistAdd
                      label: "Save to library"
                      onPicked: root.savePage()
                    }
                    Item { Layout.fillWidth: true }
                    Pill {
                      visible: !!root.page && root.page.id !== ""
                      danger: true
                      glyph: root.iconDelete
                      label: "Delete"
                      onPicked: {
                        if (!root.service) return
                        root.service.deletePlaylist(root.page.id)
                        root.page = null
                        root.service.listPlaylists(function() {})
                      }
                    }
                  }

                  // Column heads for the numbered list.
                  RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Style.space(6)
                    Layout.rightMargin: Style.space(8)
                    spacing: Style.space(10)
                    Text { Layout.preferredWidth: Style.space(26); horizontalAlignment: Text.AlignRight; text: "#"; color: root.fgDim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    Item { Layout.preferredWidth: Style.space(36) }
                    Text { Layout.fillWidth: true; text: "Title"; color: root.fgDim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    Text { Layout.preferredWidth: Style.space(44); horizontalAlignment: Text.AlignRight; text: "Length"; color: root.fgDim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                  }
                  Rectangle { Layout.fillWidth: true; height: 1; color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) }

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
                      accent: root.accent
                      playlistId: root.page && !root.page.virtual ? root.page.id : ""
                      leading: String(index + 1)
                      queueGlyph: root.iconQueueAdd
                      onPlayRequested: if (root.service) root.service.playQueueFrom(root.page.items, index, root.pageSource())
                      onQueueRequested: if (root.service) root.service.addToQueue(modelData)
                      onRemovedFromPlaylist: {
                        var id = root.page ? root.page.id : ""
                        if (id) Qt.callLater(function() { root.openPlaylist(id); root.service.listPlaylists(function() {}) })
                      }
                    }
                  }
                }

                // ===== search: start page and results
                ListView {
                  id: searchList
                  anchors.fill: parent
                  visible: root.page === null && root.activeTab === "search" && !body.eqHere && !startPage
                  model: root.searchResults
                  clip: true
                  spacing: Style.space(2)
                  ScrollBar.vertical: ScrollBar {}

                  readonly property bool startPage: root.searchResults.length === 0
                    && String(root.searchText || "").trim() === ""
                    && !root.searching && !root.pageBusy
                    && root.pageError === "" && root.searchError === ""

                  header: Text {
                    visible: root.searchResults.length > 0
                    height: visible ? implicitHeight + Style.space(8) : 0
                    text: root.searchResults.length + " results"
                    color: root.fgDim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  Label {
                    anchors.centerIn: parent
                    visible: root.searchResults.length === 0
                    text: root.pageError || root.searchError || (root.searching || root.pageBusy ? "Searching…" : "No results")
                    color: root.pageError !== "" || root.searchError !== "" ? Color.urgent : root.fgDim
                    font.family: Style.font.family
                  }

                  delegate: TrackRow {
                    width: ListView.view.width
                    item: modelData
                    service: root.service
                    accent: root.accent
                    wideArt: true
                    alwaysActions: true
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

                // Home: what you played, your library, your favourites.
                Flickable {
                  id: home
                  anchors.fill: parent
                  visible: root.page === null && root.activeTab === "search" && !body.eqHere && searchList.startPage
                  contentHeight: homeColumn.implicitHeight + Style.space(8)
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  ScrollBar.vertical: ScrollBar {}

                  readonly property int cardColumns: Math.max(2, Math.min(7, Math.floor(width / Style.space(180))))

                  ColumnLayout {
                    id: homeColumn
                    width: home.width
                    spacing: Style.space(14)

                    Heading {
                      Layout.fillWidth: true
                      visible: root.history.length > 0
                      title: "Jump back in"
                      action: "Recent · see all"
                      onActionPicked: root.showTab("recent")
                    }
                    GridLayout {
                      Layout.fillWidth: true
                      visible: root.history.length > 0
                      columns: home.cardColumns
                      columnSpacing: Style.space(14)
                      rowSpacing: Style.space(14)
                      Repeater {
                        model: root.history.slice(0, home.cardColumns)
                        delegate: Rectangle {
                          id: jump
                          required property var modelData
                          readonly property bool isCurrent: !!(root.service && root.service.track
                            && root.service.track.videoId === modelData.videoId)
                          Layout.fillWidth: true
                          Layout.preferredWidth: 1
                          implicitHeight: jumpCol.implicitHeight + Style.space(24)
                          radius: Style.space(10)
                          color: jumpHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) : root.cardFill
                          HoverHandler { id: jumpHover }
                          ColumnLayout {
                            id: jumpCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Style.space(12)
                            spacing: Style.space(10)
                            Item {
                              Layout.fillWidth: true
                              Layout.preferredHeight: width
                              RoundedImage {
                                anchors.fill: parent
                                radius: Style.space(8)
                                source: jump.modelData.thumbnail || ""
                              }
                              Rectangle {
                                visible: jump.isCurrent
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.margins: Style.space(8)
                                width: playingText.implicitWidth + Style.space(14)
                                height: Style.space(22)
                                radius: Style.space(6)
                                color: root.paneBg
                                Row {
                                  id: playingText
                                  anchors.centerIn: parent
                                  spacing: Style.space(6)
                                  NowBars {
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: root.accent
                                    barHeight: Style.space(10)
                                    running: !!(root.service && root.service.effectivePlaying)
                                  }
                                  Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Playing"
                                    color: root.accent
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                  }
                                }
                              }
                              FlatButton {
                                opacity: jumpHover.hovered || jump.isCurrent ? 1 : 0.85
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: Style.space(8)
                                primary: true
                                accent: root.accent
                                onAccent: root.onAccent
                                buttonSize: Style.space(38)
                                iconText: root.iconPlay
                                tooltipText: "Play"
                                onClicked: if (root.service) root.service.playNow(jump.modelData)
                              }
                            }
                            ColumnLayout {
                              Layout.fillWidth: true
                              spacing: Style.space(2)
                              Text {
                                Layout.fillWidth: true
                                text: jump.modelData.name || ""
                                textFormat: Text.PlainText
                                color: jump.isCurrent ? root.accent : root.fg
                                font.family: Style.font.family
                                font.bold: true
                                font.pixelSize: Style.font.caption + 1
                                elide: Text.ElideRight
                              }
                              Text {
                                Layout.fillWidth: true
                                text: jump.modelData.subtitle || ""
                                textFormat: Text.PlainText
                                color: root.fgDim
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideRight
                              }
                            }
                          }
                          MouseArea {
                            z: -1
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (root.service) root.service.playNow(jump.modelData)
                          }
                        }
                      }
                    }

                    Heading {
                      Layout.fillWidth: true
                      Layout.topMargin: Style.space(8)
                      visible: root.libraryRows.length > 0
                      title: "Your library"
                      action: "Open library"
                      onActionPicked: root.showTab("playlists")
                    }
                    GridLayout {
                      Layout.fillWidth: true
                      visible: root.libraryRows.length > 0
                      columns: Math.max(1, Math.floor(home.width / Style.space(280)))
                      columnSpacing: Style.space(12)
                      rowSpacing: Style.space(12)
                      Repeater {
                        model: root.libraryRows
                        delegate: Rectangle {
                          id: libCard
                          required property var modelData
                          Layout.fillWidth: true
                          Layout.preferredWidth: 1
                          implicitHeight: Style.space(64)
                          radius: Style.space(8)
                          clip: true
                          color: libCardHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
                          HoverHandler { id: libCardHover }
                          RowLayout {
                            anchors.fill: parent
                            anchors.rightMargin: Style.space(10)
                            spacing: Style.space(12)
                            CoverTile {
                              Layout.preferredWidth: Style.space(64)
                              Layout.preferredHeight: Style.space(64)
                              radius: 0
                              covers: libCard.modelData.covers
                              glyph: libCard.modelData.glyph
                              accent: root.accent
                            }
                            ColumnLayout {
                              Layout.fillWidth: true
                              spacing: Style.space(2)
                              Text {
                                Layout.fillWidth: true
                                text: libCard.modelData.name
                                textFormat: Text.PlainText
                                color: root.fg
                                font.family: Style.font.family
                                font.bold: true
                                font.pixelSize: Style.font.caption + 1
                                elide: Text.ElideRight
                              }
                              Text {
                                Layout.fillWidth: true
                                text: libCard.modelData.detail
                                color: root.fgDim
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideRight
                              }
                            }
                            FlatButton {
                              visible: libCardHover.hovered
                              primary: true
                              accent: root.accent
                              onAccent: root.onAccent
                              buttonSize: Style.space(34)
                              iconText: root.iconPlay
                              tooltipText: "Play"
                              onClicked: root.playLibraryRow(libCard.modelData)
                            }
                          }
                          MouseArea {
                            z: -1
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openLibraryRow(libCard.modelData)
                          }
                        }
                      }
                    }

                    Heading {
                      Layout.fillWidth: true
                      Layout.topMargin: Style.space(8)
                      visible: root.mostPlayedItems.length > 0
                      title: "Most played"
                      action: "Play all"
                      onActionPicked: if (root.service) root.service.playQueueFrom(root.mostPlayedItems, 0, { kind: "most", id: "", name: "Most played" })
                    }
                    GridLayout {
                      Layout.fillWidth: true
                      visible: root.mostPlayedItems.length > 0
                      columns: home.width >= Style.space(720) ? 2 : 1
                      columnSpacing: Style.space(20)
                      rowSpacing: Style.space(2)
                      Repeater {
                        model: root.mostPlayedItems.slice(0, home.width >= Style.space(720) ? 8 : 5)
                        delegate: TrackRow {
                          required property var modelData
                          required property int index
                          leading: String(index + 1)
                          trailing: Number(modelData.plays || 0) + " plays"
                          Layout.fillWidth: true
                          Layout.preferredWidth: 1
                          item: modelData
                          service: root.service
                          accent: root.accent
                          queueGlyph: root.iconQueueAdd
                          onPlayRequested: if (root.service) root.service.playNow(modelData)
                          onQueueRequested: if (root.service) root.service.addToQueue(modelData)
                        }
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      Layout.topMargin: Style.space(8)
                      text: root.history.length > 0
                        ? "Tip: paste a YouTube playlist link above to open it here."
                        : "Search YouTube, or paste a video or playlist link"
                      color: root.fgDim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }

                // ===== queue
                ColumnLayout {
                  anchors.fill: parent
                  visible: root.page === null && root.activeTab === "queue" && !body.eqHere
                  spacing: Style.space(10)

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(10)
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(2)
                      Heading { Layout.fillWidth: true; title: "Queue"; big: true }
                      Text {
                        text: root.service ? root.lengthText(root.service.queue) : ""
                        color: root.fgDim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                    Pill {
                      visible: !!root.service && root.service.queue.length > 0
                      glyph: root.iconPlaylistAdd
                      label: "Save as playlist"
                      onPicked: root.saveQueueAsPlaylist()
                    }
                  }

                  ListView {
                    id: queueList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: root.service ? root.service.queue : []
                    clip: true
                    spacing: Style.space(2)
                    ScrollBar.vertical: ScrollBar {}
                    Component.onCompleted: positionViewAtIndex(Math.max(0, root.service ? root.service.queueIndex : 0), ListView.Contain)

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
                      accent: root.accent
                      opacity: root.service && index < root.service.queueIndex ? 0.55 : 1
                      highlighted: index === (root.service ? root.service.queueIndex : -1)
                      queueGlyph: root.iconClose
                      onPlayRequested: if (root.service) root.service.playQueueFrom(root.service.queue, index, root.service.queueSource)
                      onQueueRequested: if (root.service) root.service.removeFromQueue(index)
                    }
                  }
                }

                // ===== library
                Flickable {
                  anchors.fill: parent
                  visible: root.page === null && root.activeTab === "playlists" && !body.eqHere
                  contentHeight: playlistsColumn.implicitHeight
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  ScrollBar.vertical: ScrollBar {}

                  ColumnLayout {
                    id: playlistsColumn
                    width: parent.width
                    spacing: Style.space(8)

                    Heading { Layout.fillWidth: true; title: "Library"; big: true }

                    Repeater {
                      model: root.libraryRows
                      delegate: ListRow {
                        required property var modelData
                        Layout.fillWidth: true
                        glyph: modelData.glyph
                        covers: modelData.covers
                        title: modelData.name
                        detail: modelData.detail
                        accent: root.accent
                        onOpened: root.openLibraryRow(modelData)
                        onPlayed: root.playLibraryRow(modelData)
                      }
                    }

                    Label {
                      visible: !root.service || root.service.playlists.length === 0
                      Layout.fillWidth: true
                      text: "No saved playlists yet. Paste a playlist link above, or save the queue."
                      color: root.fgDim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }

                // ===== lyrics
                ColumnLayout {
                  id: lyricsPage
                  anchors.fill: parent
                  visible: root.page === null && root.activeTab === "lyrics" && !body.eqHere
                  spacing: Style.space(14)

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(root.compact ? 14 : 20)
                    Rectangle {
                      readonly property real side: Style.space(root.shortWin ? 56 : (root.compact ? 72 : 120))
                      Layout.preferredWidth: side
                      Layout.preferredHeight: side
                      radius: Style.space(10)
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
                      Text {
                        visible: !root.shortWin && !!(root.service && root.service.hasTrack && root.service.queue.length > 1)
                        text: root.service ? "NOW PLAYING · " + (root.service.queueIndex + 1) + " OF " + root.service.queue.length : ""
                        color: root.accent
                        font.family: Style.font.family
                        font.bold: true
                        font.letterSpacing: 1
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        Layout.fillWidth: true
                        text: root.service && root.service.hasTrack ? root.service.trackTitle : "Nothing playing"
                        textFormat: Text.PlainText
                        color: root.fg
                        font.family: Style.font.family
                        font.bold: true
                        font.pixelSize: root.compact || root.shortWin ? Style.font.subtitle : Style.font.subtitle + 10
                        wrapMode: Text.WordWrap
                        maximumLineCount: root.shortWin ? 1 : 2
                        elide: Text.ElideRight
                      }
                      Text {
                        Layout.fillWidth: true
                        text: (root.service ? root.service.trackArtist : "")
                          + (root.service && root.service.queueSource ? " · from " + root.service.queueSource.name : "")
                        textFormat: Text.PlainText
                        color: root.fgDim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption + 1
                        elide: Text.ElideRight
                      }
                    }
                  }

                  // Source, timing, another match, copy.
                  Flow {
                    Layout.fillWidth: true
                    visible: !!(root.service && root.service.hasTrack)
                    spacing: Style.space(8)

                    Pill {
                      height: Style.space(32)
                      filled: fullLyrics.synced
                      enabledPill: fullLyrics.synced
                      glyph: "\u{f05cb}"
                      label: fullLyrics.synced ? "Karaoke · K" : "Karaoke needs timed lyrics"
                      accent: root.accent
                      onAccent: root.onAccent
                      onPicked: root.enterKaraoke()
                    }

                    Rectangle {
                      id: sourceChip
                      visible: fullLyrics.sourceText !== ""
                      height: Style.space(32)
                      width: Math.min(sourceLabel.implicitWidth + Style.space(24), Style.space(320))
                      radius: height / 2
                      color: sourceArea.containsMouse || lyricsMenu.opened
                        ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.3)
                        : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                      Text {
                        id: sourceLabel
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, Style.space(296))
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

                    Rectangle {
                      visible: fullLyrics.synced
                      height: Style.space(32)
                      width: timingRow.implicitWidth + Style.space(10)
                      radius: height / 2
                      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                      Row {
                        id: timingRow
                        anchors.centerIn: parent
                        spacing: Style.space(2)
                        FlatButton {
                          anchors.verticalCenter: parent.verticalCenter
                          buttonSize: Style.space(26)
                          iconText: "\u{f0374}"
                          foreground: root.fg
                          accent: root.accent
                          tooltipText: "Lyrics earlier"
                          onClicked: root.nudgeLyrics(-250)
                        }
                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(56)
                          horizontalAlignment: Text.AlignHCenter
                          text: {
                            var ms = root.service && root.service.lyrics ? Number(root.service.lyrics.offsetMs || 0) : 0
                            return (ms > 0 ? "+" : ms < 0 ? "−" : "") + (Math.abs(ms) / 1000).toFixed(2).replace(/0$/, "") + "s"
                          }
                          color: root.fg
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                        FlatButton {
                          anchors.verticalCenter: parent.verticalCenter
                          buttonSize: Style.space(26)
                          iconText: "\u{f0415}"
                          foreground: root.fg
                          accent: root.accent
                          tooltipText: "Lyrics later"
                          onClicked: root.nudgeLyrics(250)
                        }
                      }
                    }

                    Pill {
                      height: Style.space(32)
                      label: root.shortWin || root.compact ? "Try another" : "Wrong song? Try another"
                      onPicked: if (root.service) root.service.lyricsTryOther()
                    }
                    Pill {
                      visible: fullLyrics.hasText && !root.shortWin
                      height: Style.space(32)
                      glyph: "\u{f018f}"
                      label: "Copy"
                      onPicked: {
                        var out = []
                        var ls = fullLyrics.lines
                        for (var i = 0; i < ls.length; i++) out.push(String(ls[i].text || ""))
                        Quickshell.clipboardText = out.join("\n")
                      }
                    }
                    Pill {
                      visible: !root.shortWin
                      height: Style.space(32)
                      label: "Aa · " + root.lyricsSize.charAt(0).toUpperCase() + root.lyricsSize.slice(1)
                      onPicked: {
                        var sizes = ["small", "normal", "large"]
                        root.lyricsSize = sizes[(sizes.indexOf(root.lyricsSize) + 1) % sizes.length]
                      }
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    visible: text !== "" && (!root.shortWin || (root.service && root.service.lyrics && root.service.lyrics.sync && root.service.lyrics.sync.status === "doubtful" && Number(root.service.lyrics.sync.z) < 1.3))
                    color: root.service && root.service.lyrics && root.service.lyrics.sync && root.service.lyrics.sync.status === "doubtful" && Number(root.service.lyrics.sync.z) < 1.3 ? Color.urgent : root.fgDim
                    text: {
                      var l = root.service ? root.service.lyrics : null
                      if (!l || !l.title || (l.status !== "synced" && l.status !== "plain")) return ""
                      var how = l.fit === "fit" ? " · lined up with the video" : (l.fit === "stretch" ? " · stretched to the video" : "")
                      var note = Api.syncNote(l)
                      return "Lyrics of " + l.artist + " – " + l.title + how + (note !== "" ? " · " + note : "")
                    }
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption - 1
                    elide: Text.ElideRight
                  }

                  LyricsView {
                    id: fullLyrics
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    service: root.service
                    size: root.lyricsSize
                    foreground: root.fg
                    accent: root.accent
                    fadeTo: root.paneBg
                    active: lyricsPage.visible && root.opened
                  }
                }

                // ===== recent
                ColumnLayout {
                  anchors.fill: parent
                  visible: root.page === null && root.activeTab === "recent" && !body.eqHere
                  spacing: Style.space(10)

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(8)
                    Heading { Layout.fillWidth: true; title: "Recent"; big: true }
                    Pill {
                      visible: root.history.length > 0
                      glyph: root.iconPlay
                      label: "Play all"
                      onPicked: if (root.service) root.service.playQueueFrom(root.history, 0, { kind: "recent", id: "", name: "Recently played" })
                    }
                    Pill {
                      visible: root.history.length > 0
                      danger: true
                      glyph: root.iconDelete
                      label: "Clear history"
                      onPicked: if (root.service) root.service.clearHistory(function() {})
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
                    Text {
                      height: Style.space(36)
                      verticalAlignment: Text.AlignBottom
                      bottomPadding: Style.space(6)
                      leftPadding: Style.space(6)
                      text: rowData.label.toUpperCase()
                      color: root.fgDim
                      font.family: Style.font.family
                      font.bold: true
                      font.letterSpacing: 1
                      font.pixelSize: Style.font.caption
                    }
                  }
                  Component {
                    id: trackRow
                    TrackRow {
                      item: rowData.track
                      service: root.service
                      accent: root.accent
                      trailing: rowData.when
                      subtitleExtra: Number(rowData.track.plays || 0) > 1 ? rowData.track.plays + " plays" : ""
                      queueGlyph: root.iconQueueAdd
                      onPlayRequested: if (root.service) root.service.playNow(rowData.track)
                      onQueueRequested: if (root.service) root.service.addToQueue(rowData.track)
                    }
                  }
                }

                // ===== equaliser in the body (no right pane at this width)
                ColumnLayout {
                  anchors.fill: parent
                  visible: body.eqHere
                  spacing: Style.space(14)
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(10)
                    Heading { Layout.fillWidth: true; title: "Equaliser"; big: true }
                    Pill {
                      label: "Reset"
                      enabledPill: !!root.service && root.service.eqPreset !== "Flat"
                      onPicked: if (root.service) root.service.setEqPreset("Flat")
                    }
                    FlatButton {
                      iconText: root.iconClose
                      foreground: root.fg
                      accent: root.accent
                      tooltipText: "Close (E)"
                      onClicked: root.eqOpen = false
                    }
                  }
                  EqGraph {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    service: root.service
                    foreground: root.fg
                    accent: root.accent
                    fadeTo: root.paneBg
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "Drag a dot for ±12 dB · double-click resets a band · the glow is the live sound in that band"
                    color: root.fgDim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }

          // ===================== right pane =====================
          Rectangle {
            id: rightPane
            visible: root.wide && !root.paneHidden
            // On the lyrics page the pane shows the whole queue instead.
            readonly property bool showsQueue: root.page === null && root.activeTab === "lyrics" && !root.eqOpen
            Layout.fillHeight: true
            Layout.preferredWidth: Style.space(340)
            radius: Style.space(12)
            clip: true
            gradient: Gradient {
              GradientStop { position: 0.0; color: root.deep }
              GradientStop { position: 0.6; color: root.paneBg }
            }

            // ---- queue (lyrics page)
            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(16)
              visible: rightPane.showsQueue
              spacing: Style.space(8)
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(2)
                  Text { text: "Queue"; color: root.fg; font.family: Style.font.family; font.bold: true; font.pixelSize: Style.font.body }
                  Text {
                    Layout.fillWidth: true
                    text: {
                      if (!root.service) return ""
                      var left = Math.max(0, root.service.queue.length - root.service.queueIndex - 1)
                      return root.lengthText(root.service.queue) + " · " + left + " left"
                    }
                    color: root.fgDim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
                Pill {
                  visible: !!root.service && root.service.queue.length > 0
                  height: Style.space(30)
                  label: "Save"
                  glyph: root.iconPlaylistAdd
                  onPicked: root.saveQueueAsPlaylist()
                }
                FlatButton {
                  buttonSize: Style.space(30)
                  iconText: root.iconClose
                  foreground: root.fgDim
                  accent: root.accent
                  tooltipText: "Hide this pane"
                  onClicked: root.paneHidden = true
                }
              }
              ListView {
                id: paneQueue
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Style.space(2)
                model: root.service ? root.service.queue : []
                ScrollBar.vertical: ScrollBar {}
                onVisibleChanged: if (visible) positionViewAtIndex(Math.max(0, root.service ? root.service.queueIndex : 0), ListView.Center)
                delegate: TrackRow {
                  width: ListView.view.width
                  item: modelData
                  service: root.service
                  accent: root.accent
                  opacity: root.service && index < root.service.queueIndex ? 0.5 : 1
                  highlighted: index === (root.service ? root.service.queueIndex : -1)
                  queueGlyph: root.iconClose
                  onPlayRequested: if (root.service) root.service.playQueueFrom(root.service.queue, index, root.service.queueSource)
                  onQueueRequested: if (root.service) root.service.removeFromQueue(index)
                }
              }
            }

            // ---- now playing
            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(16)
              visible: !root.eqOpen && !rightPane.showsQueue
              spacing: Style.space(14)

              RowLayout {
                Layout.fillWidth: true
                Text {
                  Layout.fillWidth: true
                  text: "Now playing"
                  color: root.fg
                  font.family: Style.font.family
                  font.bold: true
                  font.pixelSize: Style.font.body
                }
                FlatButton {
                  buttonSize: Style.space(28)
                  iconText: root.iconClose
                  foreground: root.fgDim
                  accent: root.accent
                  tooltipText: "Hide this pane"
                  onClicked: root.paneHidden = true
                }
              }
              Item {
                Layout.fillWidth: true
                Layout.preferredHeight: width
                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(12)
                  color: root.rowFill
                  visible: !(root.service && root.service.hasTrack)
                  Text {
                    anchors.centerIn: parent
                    text: root.iconNote
                    color: root.fgDim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.displayLarge
                  }
                }
                RoundedImage {
                  anchors.fill: parent
                  radius: Style.space(12)
                  lifted: true
                  visible: !!(root.service && root.service.hasTrack)
                  source: root.service ? root.service.trackThumbnail : ""
                }
                MouseArea {
                  anchors.fill: parent
                  enabled: !!(root.service && root.service.hasTrack)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.lyricsEnabled) root.showTab("lyrics")
                }
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(4)
                Text {
                  Layout.fillWidth: true
                  text: root.service && root.service.hasTrack ? root.service.trackTitle : "Nothing playing"
                  textFormat: Text.PlainText
                  color: root.fg
                  font.family: Style.font.family
                  font.bold: true
                  font.pixelSize: Style.font.subtitle
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }
                Text {
                  Layout.fillWidth: true
                  visible: text !== ""
                  text: root.service ? root.service.trackArtist : ""
                  textFormat: Text.PlainText
                  color: root.fgDim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption + 1
                  elide: Text.ElideRight
                }
              }
                FlatButton {
                  id: addToListButton
                  Layout.alignment: Qt.AlignTop
                  visible: !!(root.service && root.service.hasTrack)
                  iconText: root.iconPlaylistAdd
                  foreground: root.fg
                  accent: root.accent
                  selected: addMenu.opened
                  tooltipText: "Add to playlist"
                  onClicked: addMenu.opened ? addMenu.close() : addMenu.open()
                  Popup {
                    id: addMenu
                    y: addToListButton.height + Style.space(4)
                    x: addToListButton.width - width
                    width: Style.space(240)
                    padding: Style.space(6)
                    onOpened: { addName.text = ""; if (root.service) root.service.listPlaylists(function() {}) }
                    background: Rectangle {
                      color: Color.popups.background
                      radius: Style.space(12)
                      border.width: Math.max(1, Style.normalBorderWidth)
                      border.color: Color.popups.border
                    }
                    contentItem: ColumnLayout {
                      spacing: Style.space(2)
                      Text {
                        Layout.leftMargin: Style.space(8)
                        Layout.topMargin: Style.space(4)
                        Layout.bottomMargin: Style.space(4)
                        text: "ADD TO PLAYLIST"
                        color: Qt.darker(Color.popups.text, 1.6)
                        font.family: Style.font.family
                        font.bold: true
                        font.letterSpacing: 1
                        font.pixelSize: Style.font.caption
                      }
                      Repeater {
                        model: root.service ? root.service.playlists : []
                        delegate: Rectangle {
                          id: addRow
                          required property var modelData
                          Layout.fillWidth: true
                          implicitHeight: Style.space(32)
                          radius: Style.space(8)
                          color: addRowArea.containsMouse ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08) : "transparent"
                          Text {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: Style.space(10)
                            anchors.rightMargin: Style.space(10)
                            anchors.verticalCenter: parent.verticalCenter
                            text: addRow.modelData.name
                            color: Color.popups.text
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption + 1
                            elide: Text.ElideRight
                          }
                          MouseArea {
                            id: addRowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              if (!root.service || !root.service.track) return
                              root.service.addToPlaylist(addRow.modelData.id, root.service.track, function() { root.service.listPlaylists(function() {}) })
                              addMenu.close()
                            }
                          }
                        }
                      }
                      TextField {
                        id: addName
                        Layout.fillWidth: true
                        Layout.topMargin: Style.space(4)
                        placeholderText: "New playlist…"
                        onAccepted: {
                          var name = text.trim()
                          if (!name || !root.service || !root.service.track) return
                          root.service.createPlaylist(name, [root.service.track], function(ok) { if (ok) root.service.listPlaylists(function() {}) })
                          addMenu.close()
                        }
                      }
                    }
                  }
                }
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: Style.space(80)
                radius: Style.space(10)
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
                ColumnLayout {
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  spacing: Style.space(4)
                  Heading {
                    Layout.fillWidth: true
                    title: "Up next"
                    action: "Open queue"
                    onActionPicked: root.showTab("queue")
                  }
                  ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    interactive: false
                    spacing: Style.space(2)
                    model: root.upNext
                    Text {
                      anchors.centerIn: parent
                      visible: root.upNext.length === 0
                      text: "Nothing queued after this"
                      color: root.fgDim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    delegate: TrackRow {
                      width: ListView.view.width
                      item: modelData
                      service: root.service
                      accent: root.accent
                      compact: true
                      queueGlyph: root.iconClose
                      onPlayRequested: {
                        if (!root.service) return
                        var i = root.service.queueIndex + 1 + index
                        root.service.playQueueFrom(root.service.queue, i, root.service.queueSource)
                      }
                      onQueueRequested: if (root.service) root.service.removeFromQueue(root.service.queueIndex + 1 + index)
                    }
                  }
                }
              }

              Rectangle {
                Layout.fillWidth: true
                visible: !!(root.service && root.service.videoActive)
                implicitHeight: Style.space(52)
                radius: Style.space(10)
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
                VideoControls {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  service: root.service
                }
              }
            }

            // ---- equaliser in the pane
            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(16)
              visible: root.eqOpen
              spacing: Style.space(12)
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                Text {
                  Layout.fillWidth: true
                  text: "Equaliser"
                  color: root.fg
                  font.family: Style.font.family
                  font.bold: true
                  font.pixelSize: Style.font.body
                }
                Pill {
                  height: Style.space(30)
                  label: "Reset"
                  enabledPill: !!root.service && root.service.eqPreset !== "Flat"
                  onPicked: if (root.service) root.service.setEqPreset("Flat")
                }
                FlatButton {
                  buttonSize: Style.space(30)
                  iconText: root.iconClose
                  foreground: root.fg
                  accent: root.accent
                  tooltipText: "Close (E)"
                  onClicked: root.eqOpen = false
                }
              }
              EqGraph {
                Layout.fillWidth: true
                Layout.fillHeight: true
                compact: true
                service: root.service
                foreground: root.fg
                accent: root.accent
                fadeTo: root.paneBg
              }
              Text {
                Layout.fillWidth: true
                text: "Drag a dot for ±12 dB · double-click resets a band"
                color: root.fgDim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Rectangle {
                Layout.fillWidth: true
                visible: !!(root.service && root.service.videoActive)
                implicitHeight: Style.space(52)
                radius: Style.space(10)
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
                VideoControls {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  service: root.service
                }
              }
            }
          }
        }

        // Video controls when there is no right pane to hold them.
        Rectangle {
          Layout.fillWidth: true
          visible: !root.wide && !!(root.service && root.service.videoActive)
          implicitHeight: Style.space(48)
          radius: Style.space(12)
          color: root.paneBg
          VideoControls {
            anchors.fill: parent
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(14)
            service: root.service
          }
        }

        PlayerBar {
          Layout.fillWidth: true
          Layout.fillHeight: root.barOnly
          Layout.preferredHeight: implicitHeight
          service: root.service
          accent: root.accent
          onAccent: root.onAccent
          deep: root.deep
          lyricsEnabled: root.lyricsEnabled
          lyricsOn: root.page === null && root.activeTab === "lyrics"
          queueOn: root.page === null && root.activeTab === "queue"
          eqOn: root.eqOpen
          outputOn: outputMenu.opened
          onArtClicked: root.showTab(root.lyricsEnabled ? "lyrics" : "queue")
          onLyricsClicked: root.activeTab === "lyrics" && root.page === null ? root.goHome() : root.showTab("lyrics")
          onQueueClicked: root.activeTab === "queue" && root.page === null ? root.goHome() : root.showTab("queue")
          onEqClicked: root.eqOpen = !root.eqOpen
          karaokeOn: root.karaoke
          onKaraokeClicked: root.karaoke ? root.exitKaraoke() : root.enterKaraoke()
          onVideoClicked: root.toggleVideo()
          onOutputClicked: function(anchor) {
            var p = anchor.mapToItem(playerScope, 0, 0)
            outputMenu.x = Math.max(Style.space(8), Math.min(p.x + anchor.width - outputMenu.width, playerScope.width - outputMenu.width - Style.space(8)))
            outputMenu.openAbove(p.y)
          }
        }

        // Bottom tabs on a narrow window.
        RowLayout {
          Layout.fillWidth: true
          visible: root.compact && !root.barOnly
          spacing: 0
          Repeater {
            model: [
              { key: "search", label: "Home", glyph: root.iconHome },
              { key: "queue", label: "Queue", glyph: root.iconNote },
              { key: "playlists", label: "Library", glyph: root.iconLibrary },
              { key: "recent", label: "Recent", glyph: root.iconRecent }
            ].concat(root.lyricsEnabled ? [{ key: "lyrics", label: "Lyrics", glyph: root.iconLyrics }] : [])
            delegate: Item {
              id: tabItem
              required property var modelData
              readonly property bool current: root.page === null && root.activeTab === modelData.key
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(48)
              Column {
                anchors.centerIn: parent
                spacing: Style.space(2)
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: tabItem.modelData.glyph
                  color: tabItem.current ? root.accent : root.fgDim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.icon + 2
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: tabItem.modelData.label
                  color: tabItem.current ? root.accent : root.fgDim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption - 1
                }
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: tabItem.modelData.key === "search" ? root.goHome() : root.showTab(tabItem.modelData.key)
              }
            }
          }
        }
      }


        KaraokeView {
          id: karaokeView
          anchors.fill: parent
          z: 10
          visible: root.karaoke
          active: root.karaoke && root.opened
          service: root.service
          accent: root.accent
          onAccent: root.onAccent
          deep: root.deep
          textSize: root.karaokeSize
          onExitRequested: root.exitKaraoke()
          onSizePicked: function(size) { root.karaokeSize = size }
          onSizeCycled: {
            var sizes = ["small", "medium", "large", "huge"]
            root.karaokeSize = sizes[(sizes.indexOf(root.karaokeSize) + 1) % sizes.length]
          }
        }
      }

      // ---- "Play on…": this app's own stream only ----
      Popup {
        id: outputMenu
        width: Style.space(300)
        padding: Style.space(8)
        property var outputs: []
        property string chosen: ""
        property bool loading: false
        property string error: ""

        function openAbove(anchorY) {
          outputMenu.loading = true
          outputMenu.error = ""
          outputMenu.y = Math.max(Style.space(8), anchorY - Style.space(8) - Math.max(implicitHeight, Style.space(120)))
          outputMenu.open()
          if (!root.service) return
          root.service.listAudioOutputs(function(ok, result, message) {
            outputMenu.loading = false
            if (!ok) { outputMenu.error = message || "Could not list outputs"; return }
            outputMenu.outputs = (result && result.outputs) || []
            outputMenu.y = Math.max(Style.space(8), anchorY - Style.space(8) - outputMenu.implicitHeight)
          })
        }

        background: Rectangle {
          color: Color.popups.background
          radius: Style.space(12)
          border.width: Math.max(1, Style.normalBorderWidth)
          border.color: Color.popups.border
        }

        contentItem: ColumnLayout {
          spacing: Style.space(2)
          Text {
            Layout.leftMargin: Style.space(10)
            Layout.topMargin: Style.space(4)
            Layout.bottomMargin: Style.space(4)
            text: "PLAY ON"
            color: Qt.darker(Color.popups.text, 1.6)
            font.family: Style.font.family
            font.bold: true
            font.letterSpacing: 1
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: outputMenu.loading || outputMenu.error !== ""
            Layout.leftMargin: Style.space(10)
            Layout.bottomMargin: Style.space(6)
            text: outputMenu.error !== "" ? outputMenu.error : "Looking for outputs…"
            color: outputMenu.error !== "" ? Color.urgent : Qt.darker(Color.popups.text, 1.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Repeater {
            model: outputMenu.outputs
            delegate: Rectangle {
              id: outRow
              required property var modelData
              readonly property bool picked: outputMenu.chosen !== "" ? outputMenu.chosen === modelData.name : !!modelData.isDefault
              Layout.fillWidth: true
              implicitHeight: Style.space(36)
              radius: Style.space(8)
              color: picked ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                : (outArea.containsMouse ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08) : "transparent")
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)
                Text {
                  text: /bluez|bluetooth/i.test(outRow.modelData.name) ? "\u{f02cb}"
                    : (/hdmi/i.test(outRow.modelData.name) ? "\u{f0379}" : "\u{f04c3}")
                  color: outRow.picked ? root.accent : Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.icon
                }
                Text {
                  Layout.fillWidth: true
                  text: outRow.modelData.description
                  color: outRow.picked ? root.accent : Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption + 1
                  elide: Text.ElideRight
                }
                Text {
                  visible: outRow.picked
                  text: "\u{f012c}"
                  color: root.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.icon
                }
              }
              MouseArea {
                id: outArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (!root.service) return
                  root.service.setAudioOutput(outRow.modelData.name)
                  outputMenu.chosen = outRow.modelData.name
                  outputMenu.close()
                }
              }
            }
          }
        }
      }
    }
  }
}
