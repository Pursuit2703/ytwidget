import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick.Effects
import qs.Ui
import qs.Commons

import "Api.js" as Api

BarWidget {
  id: root
  moduleName: "omar.ytwidget"

  // bar.shell.serviceFor() reliably returned null here (a third-party bar
  // widget looking up its own service through the host's scoped facade), so
  // this widget holds its own direct connection to the backend instead of
  // depending on that lookup — see PlayerConnection.qml for why that's safe.
  readonly property var ytService: conn
  PlayerConnection { id: conn }

  readonly property bool hasTrack: !!(ytService && ytService.hasTrack)
  // While the video window is open, the audio deck is deliberately paused
  // (they'd otherwise both play sound) — so "playing" has to come from the
  // video window's own mpv state, not the deck's, or the mini player reads
  // as paused/idle the whole time a video is actually up and playing.
  readonly property bool playing: !!(ytService &&
    (ytService.videoActive ? ytService.videoPlaying : ytService.playing))
  readonly property string title: ytService ? ytService.trackTitle : ""
  readonly property string artist: ytService ? ytService.trackArtist : ""
  // The panel has always surfaced this, the bar never did — so a failure that
  // happened while the panel was closed was invisible: the chip went on
  // reading "Nothing playing" as though nothing had gone wrong.
  readonly property string lastError: ytService ? String(ytService.lastError || "") : ""
  // Three states, and what each one shows:
  //
  //   no track            the note, alone — it is the way into the player
  //   paused, or hovered  the note and the transport controls
  //   playing, at rest    the scrolling title, and nothing else
  //
  // Paused counts as "show me the controls" because a paused track is one you
  // are about to do something to; a playing one you only want to read.
  readonly property bool paused: hasTrack && !playing
  // How much of the chip is drawn, set per bar entry in shell.json
  // ({"id":"omar.ytwidget","size":"icon"}):
  //   icon   the note alone, tinted while a track plays; the tooltip names it
  //   title  the note and the scrolling title, no transport controls
  //   full   everything above (the default)
  // Anything else falls back to full, so a typo never hides the widget.
  // A vertical bar's slot is one icon wide, so the title and full rows would
  // spill out of it: it is always icon there, whatever is stored.
  readonly property string sizeMode: {
    if (root.vertical) return "icon"
    if (root.uiSize !== "") return root.uiSize
    const s = String(root.setting("size", "full")).toLowerCase()
    return (s === "icon" || s === "title") ? s : "full"
  }
  readonly property bool showControls: sizeMode === "full" && hasTrack && (pillHover.hovered || paused)
  readonly property bool showTitle: sizeMode !== "icon" && hasTrack && !showControls
  // In title mode the note stays on screen, so the title starts after it.
  // The note takes the bar's own colour in every mode, like its neighbours.
  readonly property color noteColor: root.bar.barForeground
  readonly property real titleInset: sizeMode === "title" ? Style.bar.iconSlot + Style.space(8) : 0

  // The chip holds one width for as long as a track is loaded, whatever it is
  // showing, so it never resizes under the pointer and never shoves the bar
  // icons beside it. That works out exactly rather than by padding: hiding the
  // note frees precisely the room the title needs.
  //
  //   note + gap + controls  = 26 + 4 + 94 = 124
  //   title alone, no note   =              124
  //
  // Only losing the track shrinks it, down to the bare note.
  readonly property real ctrlGap: Style.space(8)
  // Note + prev + play + next, in the bar's own icon slots. The title is given
  // this same width, so the two simply cross-fade in place.
  readonly property real trackSpan: 4 * Style.bar.iconSlot + 3 * ctrlGap
  // The setting still widens the title, but it widens the locked width with
  // it, so the chip stays the same size in every state either way.
  readonly property real maxLabelWidth: Math.max(trackSpan,
    Style.space(Math.max(60, Number(root.setting("maxWidth", 0)) || 0)),
    root.barLyricsWide ? Style.space(root.lyricsWidthSetting) : 0)
  // Optional: a wider chip only while timed lyrics are playing. Paused, the
  // chip is back to its usual width for the transport buttons. 0 = never.
  readonly property real lyricsWidthSetting: Math.max(0, Number(root.setting("lyricsWidth", 0)) || 0)
  // The audio check found the timing doesn't fit this song: show the usual
  // title and controls instead of lyrics that would be wrong.
  readonly property bool barLyricsDoubtful: !!(root.ytService && root.ytService.lyrics
    && root.ytService.lyrics.sync && root.ytService.lyrics.sync.status === "doubtful")
  readonly property bool barLyricsActive: root.lyricsInBar && root.hasTrack && root.lastError === ""
    && barLyricsClock.synced && barLyricsClock.lines.length > 0 && !root.barLyricsDoubtful
  readonly property bool barLyricsWide: root.lyricsWidthSetting > 0 && root.barLyricsActive && root.playing
  readonly property string playIcon: playing ? "\u{f03e4}" : "\u{f040a}"
  // Plain ASCII, not a nerd-font codepoint: guaranteed to render in any font,
  // no tofu risk. The art placeholder in the popup, where a tofu box would sit
  // large and obvious in the middle of the card.
  readonly property string idleGlyph: "YT"
  // The bar's own resting mark. A note says "music" at a glance where "YT"
  // only says "YouTube", and it holds the widget's place while the title is
  // collapsed. Same codepoint the play button and the panel already use, so
  // it carries no new font risk in the bar.
  readonly property string musicGlyph: "󰝚"

  // Ambient full-bar spectrum. Off by default: it paints across the whole
  // screen width, which is a bigger change to someone's desktop than a bar
  // widget has any business making uninvited.
  // ---- lyrics
  readonly property bool lyricsEnabled: String(root.setting("lyrics", "true")) !== "false"
  // The setting is the default; the mini card's toggle overrides it and is
  // remembered (ui state file), like the bar spectrum toggle.
  property var uiLyricsInBar: null
  readonly property bool lyricsInBar: lyricsEnabled && (root.uiLyricsInBar !== null
    ? root.uiLyricsInBar : String(root.setting("lyricsInBar", "true")) !== "false")
  function setLyricsInBar(on) {
    root.uiLyricsInBar = !!on
    root.saveUi()
  }
  readonly property string lyricsSource: {
    var v = String(root.setting("lyricsSource", "auto"))
    return (v === "lrclib" || v === "captions") ? v : "auto"
  }
  readonly property bool lyricsReady: lyricsEnabled && !!(ytService && ytService.lyrics)
    && ["synced", "captions", "plain"].indexOf(ytService.lyrics.status) >= 0
    && (ytService.lyrics.lines || []).length > 0
  function sendLyricsConfig() {
    if (ytService) ytService.lyricsConfig(root.lyricsEnabled, root.lyricsSource)
  }
  onLyricsEnabledChanged: sendLyricsConfig()
  onLyricsSourceChanged: sendLyricsConfig()

  // The line being sung, for the wide chip. Empty between lines and for
  // songs without timed lyrics, so the title shows then.
  LyricsClock {
    id: barLyricsClock
    service: root.ytService
    active: root.lyricsInBar && root.sizeMode !== "icon" && root.hasTrack && root.playing
  }
  readonly property string barLyricLine: {
    if (!barLyricsClock.active || barLyricsClock.index < 0) return ""
    var line = barLyricsClock.lines[barLyricsClock.index]
    return line ? String(line.text || "").trim() : ""
  }


  // The card opens on Lyrics when the song has them, unless a tab was picked
  // by hand since the card opened.
  property bool miniTabTouched: false
  function pickMiniTabForLyrics() {
    if (root.miniTabTouched) return
    if (root.lyricsReady) root.miniTab = "lyrics"
    else if (root.miniTab === "lyrics" && ytService && ytService.lyrics
             && ytService.lyrics.status !== "loading") root.miniTab = "next"
  }
  onLyricsReadyChanged: if (root.popupOpen) pickMiniTabForLyrics()

  readonly property bool ambientDefault: String(root.setting("ambientWave", "false")) === "true"
  // The toggle in the hover controls is remembered in the widget's own state
  // file, so the spectrum stays on (or off) across shell restarts, plugin
  // reloads and every monitor's copy of this widget until it is toggled again.
  // (The host's settings API is not usable from a third-party bar widget; see
  // the note on serviceFor() above.) The shell.json setting only seeds it.
  property bool ambientEnabled: root.ambientDefault
  readonly property string uiStatePath: Quickshell.env("HOME") + "/.local/state/ytwidget/ui.json"

  // Bar-chip look chosen from the card below, remembered in the same file.
  // They override the shell.json settings, so the card is the one place you
  // need to touch. "" / -1 mean "not chosen here, use the setting".
  property string uiSize: ""
  property int uiIconWidth: -1

  function saveUi() {
    uiStateFile.setText(JSON.stringify({
      ambientWave: root.ambientEnabled,
      lyricsInBar: root.uiLyricsInBar,
      size: root.uiSize,
      iconWidth: root.uiIconWidth
    }) + "\n")
  }

  function setAmbient(on) {
    root.ambientEnabled = !!on
    root.saveUi()
    // The spectrum window shows or hides a moment from now.
    Qt.callLater(root.refocusPopup)
  }

  function toggleWide() {
    root.uiSize = root.sizeMode === "full" ? "icon" : "full"
    root.saveUi()
  }

  // Which bar is in use: islands get the island colour.
  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var cfg = JSON.parse(text() || "{}")
        root.islandBar = /island/i.test(String((cfg.bar && cfg.bar.id) || ""))
        // Read straight from the config the double click writes: the bar's
        // own `transparent` only flips after it has sampled the wallpaper
        // for a text colour, which made the switch to text colour lag.
        root.islandsHidden = !!(cfg.bar && cfg.bar.transparent === true)
      } catch (e) {}
    }
  }

  FileView {
    id: uiStateFile
    path: root.uiStatePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    // Another monitor's copy toggled it: follow.
    onFileChanged: reload()
    onLoaded: {
      try {
        var saved = JSON.parse(text() || "{}")
        if (typeof saved.ambientWave === "boolean") root.ambientEnabled = saved.ambientWave
        root.uiLyricsInBar = typeof saved.lyricsInBar === "boolean" ? saved.lyricsInBar : null
        root.uiSize = (saved.size === "icon" || saved.size === "title" || saved.size === "full") ? saved.size : ""
        root.uiIconWidth = Number(saved.iconWidth) > 0 ? Number(saved.iconWidth) : -1
      } catch (e) {}
    }
  }

  // "island": the spectrum is drawn in the islands' own colour (the bar
  // background), so it reads as part of the bar. "text": the bar's text
  // colour, as before.
  // "auto" picks island while an island bar is showing its islands, text
  // otherwise: a plain bar, or an island bar switched to transparent (double
  // click), has no islands to match.
  readonly property string ambientColorSetting: String(root.setting("ambientColor", "auto"))
  property bool islandBar: false
  property bool islandsHidden: false
  readonly property string ambientColor: ambientColorSetting === "island" || ambientColorSetting === "text"
    ? ambientColorSetting : (islandBar && !islandsHidden ? "island" : "text")
  readonly property real ambientOpacity: root.ambientColor === "island" ? 0.92
    : Math.max(0.05, Math.min(1, (Number(root.setting("ambientOpacity", 55)) || 55) / 100))
  readonly property real ambientHeight: Math.max(0.1, Math.min(1,
    (Number(root.setting("ambientHeight", 62)) || 62) / 100))

  property bool popupOpen: false
  property string miniSearchText: ""
  // How many results the mini card asks for, and how many of them it shows
  // without scrolling. Six used to be the whole list because the list was a
  // plain Column — every extra row grew the card, so the card had to stay
  // stingy. Now the list scrolls at `miniVisibleResults` rows, so asking for
  // more costs no height at all.
  readonly property int miniResultLimit: Math.max(3, Math.min(25,
    Number(root.setting("miniResults", 12)) || 12))
  readonly property int miniVisibleResults: 5
  readonly property real miniRowHeight: Style.space(38)
  readonly property real miniRowSpacing: Style.space(2)
  property var miniSearchResults: []
  property int miniSelected: 0
  property bool miniSearching: false
  property bool miniQueueOpen: false
  // The EQ section is opt-in: the mini player is a now-playing card first,
  // and ten sliders is not what you want to see every time it opens.
  property bool miniEqOpen: false

  visible: true
  // Icon mode sizes to the same slot as every other bar icon by default, so
  // it sits flush instead of keeping the padding the wider chip needs. The
  // "iconWidth" setting (px) widens or narrows just that mode; 0 = one slot.
  readonly property real iconModeWidth: {
    const w = root.uiIconWidth > 0 ? root.uiIconWidth : (Number(root.setting("iconWidth", 0)) || 0)
    return w > 0 ? Style.space(w) : Style.bar.iconSlot
  }
  // Size of the note glyph itself, in the bar's own icon-font units. 0 keeps
  // the bar default so it matches the neighbouring icons.
  readonly property real glyphSize: {
    const g = Number(root.setting("glyphSize", 0)) || 0
    return g > 0 ? g : Style.bar.iconFont
  }
  implicitWidth: sizeMode === "icon" ? iconModeWidth : row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  // Nothing inside a popup surface gets keyboard focus automatically. Same
  // fix SearchableDropdown/go-prompt use: a short delay (not Qt.callLater,
  // which fires next tick) gives the focus grab time to establish the
  // compositor-level keyboard grab before we ask Qt for active focus —
  // otherwise the field can look focused (blinking cursor) while keystrokes
  // never arrive.
  onPopupOpenChanged: {
    // One popup at a time, like the bar's own: opening the card closes
    // whatever else is open (the bar calls close() on us the same way).
    if (root.bar) {
      if (popupOpen) root.bar.requestPopout(root)
      else if (root.bar.activePopout === root) root.bar.releasePopout(root)
    }
    if (!popupOpen) { root.grabIncludesBar = false; return }
    root.grabIncludesBar = false
    grabBarTimer.restart()
    root.miniTabTouched = false
    root.pickMiniTabForLyrics()
    // Baseline for the dismiss watcher further down: the window that was
    // focused as the card came up. Opening the card does not disturb it — a
    // layer surface taking the keyboard grab leaves the focused toplevel
    // exactly where it was.
    popupFocusToplevel = ToplevelManager.activeToplevel
    focusFieldTimer.start()
    // Opening this card is a good predictor that the video button is about to
    // be pressed; resolving now means the click costs no extraction.
    if (ytService && ytService.hasTrack && !ytService.videoReady) ytService.prepareVideo("")
  }

  Timer {
    id: focusFieldTimer
    interval: 60
    repeat: false
    onTriggered: if (miniSearchField) miniSearchField.forceActiveFocus()
  }

  // PopupCard.close() does `owner.close()` if the owner has one, else it
  // directly sets its own `open` property — which permanently breaks the
  // one-way `open: root.popupOpen` binding below (QML destroys a binding
  // the moment its target is assigned directly). Without this function,
  // the very first outside-click dismissal kills the binding for good and
  // the popup can never be reopened again.
  function close() { popupOpen = false }

  // Carries the mini card's search into the full player instead of opening it
  // on an empty Search tab: the query goes into its field and the rows the
  // card was already showing go with it, so the same results are on screen
  // immediately. The panel searches wider than the card does, so it re-runs
  // the query behind them and the list fills out (see Panel.open).
  //
  // `summon`, not `toggle`: this button means "show me the full player", and
  // toggle *closes* the panel whenever it happens to be open already — which
  // threw the payload away with it.
  function openFullPlayer(tab) {
    var payload = {
      search: root.miniSearchText,
      results: root.miniSearchResults || [],
      lyrics: root.lyricsEnabled,
      lyricsSize: String(root.setting("lyricsSize", "normal")),
      tab: typeof tab === "string" && tab !== "" ? tab : (root.miniTab === "lyrics" ? "lyrics" : "")
    }
    popupOpen = false
    toggleProcess.running = false
    toggleProcess.command = ["/usr/bin/omarchy-shell", "shell", "summon", moduleName,
                             JSON.stringify(payload)]
    toggleProcess.running = true
  }

  function runMiniSearch(playFirstWhenDone) {
    if (!miniSearchText.trim()) { miniSearchResults = []; miniSelected = 0; return }
    if (!ytService) return
    miniSearching = true
    ytService.search(miniSearchText.trim(), root.miniResultLimit, function(ok, result) {
      miniSearching = false
      miniSearchResults = ok && result ? (result.items || []) : []
      miniSelected = 0
      if (playFirstWhenDone && miniSearchResults.length > 0)
        root.playSelectedResult()
    })
  }

  // Enter plays whatever row is selected (the first one by default), so a
  // search is type-then-Enter. Arrow keys move the selection.
  function playSelectedResult() {
    if (!ytService || miniSearchResults.length === 0) return
    var i = Math.max(0, Math.min(miniSelected, miniSearchResults.length - 1))
    playFromSearch(miniSearchResults[i])
  }

  // Search results take the pane over while they are up. Picking a tab or
  // playing a result puts the tabs back, so the Lyrics tab never sits
  // selected over a list of results.
  function clearMiniSearch() {
    root.miniSearchText = ""
    root.miniSearchResults = []
    root.miniSelected = 0
    root.miniPreview = null
  }
  function playFromSearch(item) {
    if (!ytService) return
    ytService.playNow(item)
    clearMiniSearch()
    // A new song: let the card move to its lyrics once they are found.
    root.miniTabTouched = false
    if (root.miniTab === "lyrics") root.miniTab = "next"
  }

  readonly property bool miniSearchIsLink: Api.isYouTubeLink(miniSearchText)

  // Settings declared in manifest.json only reach the daemon if something
  // pushes them. Do it every time the connection comes up: the daemon is
  // shared and outlives any one surface, so it may be carrying whatever the
  // last client set rather than this widget's configuration.
  function pushSettings() {
    if (!ytService) return
    var fade = Number(root.setting("crossfadeMs", 500))
    ytService.setCrossfadeMs(isFinite(fade) ? Math.max(0, Math.min(3000, fade)) : 500)
    var idle = Number(root.setting("idleShutdownMinutes", 15))
    ytService.setIdleMinutes(isFinite(idle) ? Math.max(0, Math.min(1440, idle)) : 15)
    ytService.setSubtitleLang(String(root.setting("subtitleLang", "en") || "en"))
    var q = Number(root.setting("videoQuality", 1080))
    ytService.setVideoDefaults(isFinite(q) ? Math.max(144, Math.min(2160, q)) : 1080,
                               Math.max(20, Math.min(100, Number(root.setting("videoWindowPercent", 70)) || 70)),
                               String(root.setting("videoGpu", "integrated") || "integrated"))
    var vpnMode = String(root.setting("vpnMode", "fallback") || "fallback")
    if (["off", "fallback", "always"].indexOf(vpnMode) >= 0 && typeof ytService.setVpnMode === "function")
      ytService.setVpnMode(vpnMode)
  }

  Connections {
    target: root.ytService
    function onBackendReadyChanged() {
      if (root.ytService && root.ytService.backendReady) root.pushSettings()
    }
  }

  // Keys while the card is open and the search box is not focused (Esc
  // leaves the box, "/" goes back into it). Returns true when handled.
  function cardKey(event) {
    var svc = ytService
    if (!svc) return false
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return false
    var seekBy = function(ms) { svc.seek(Math.max(0, Math.min(svc.durationMs, svc.positionMs + ms))) }
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
    case Qt.Key_1: root.miniTab = "next"; root.miniTabTouched = true; root.clearMiniSearch(); return true
    case Qt.Key_2: root.miniTab = "recent"; root.miniTabTouched = true; root.clearMiniSearch(); return true
    case Qt.Key_3: root.miniTab = "lists"; root.miniTabTouched = true; root.clearMiniSearch(); return true
    case Qt.Key_4:
    case Qt.Key_L:
      if (root.lyricsEnabled) { root.miniTab = "lyrics"; root.miniTabTouched = true; root.clearMiniSearch() }
      return true
    case Qt.Key_E: root.miniEqOpen = !root.miniEqOpen; return true
    case Qt.Key_V: root.toggleVideo(); return true
    case Qt.Key_F: root.openFullPlayer(); return true
    case Qt.Key_Slash: miniSearchField.forceActiveFocus(); return true
    }
    return false
  }

  function toggleVideo() {
    if (!ytService || !ytService.hasTrack) return
    if (ytService.videoActive) ytService.hideVideo()
    else ytService.showVideo("")
  }

  // The pane under the transport shows one of: next (queue), recent
  // (history), lists (smart + saved playlists), or a pasted playlist link.
  property string miniTab: "next"
  property var miniPreview: null          // { title, items } for a pasted playlist link
  property bool miniPreviewBusy: false
  // On a top or bottom bar the card is one fixed height (miniCardHeight), so it
  // never changes size. On a vertical bar it is tall enough for its content
  // instead: the fixed top part plus the pane, which is as tall as the current
  // tab's rows (miniPaneMinHeight .. miniPaneHeight) and grows for search
  // results and other tabs with many rows. Lyrics, the equaliser/video options
  // and a pasted playlist always take the full pane height.
  readonly property real miniPaneHeight: Style.space(290)
  readonly property real miniPaneMinHeight: Style.space(96)
  readonly property real miniCardHeight: Style.space(744)
  // Never taller than the screen leaves room for (see the card's own margins).
  readonly property real miniCardMaxHeight: root.barScreen ? Math.max(120, root.barScreen.height - 2 * Style.gapsOut - (!root.vertical ? (root.bar ? root.bar.barSize : 0) : 0)) : miniCardHeight

  function isPlaylistLink(text) {
    return Api.isYouTubeLink(text) && /[?&]list=/.test(String(text))
  }

  function previewMiniLink() {
    var link = root.miniSearchText.trim()
    if (!link || !ytService) return
    miniPreviewBusy = true
    ytService.previewPlaylist(link, function(ok, data) {
      miniPreviewBusy = false
      miniPreview = ok && data && data.items && data.items.length > 0 ? data : null
    })
  }

  function playMiniPreview(shuffle) {
    if (!miniPreview || !ytService) return
    if (shuffle) ytService.setShuffle(true)
    ytService.playQueueFrom(miniPreview.items, 0)
    miniPreview = null
    root.miniSearchText = ""
    root.miniTab = "next"
  }

  function openMiniLink() {
    var link = root.miniSearchText.trim()
    if (!link || !ytService) return
    miniSearching = true
    ytService.openLink(link, function(ok) {
      miniSearching = false
      if (!ok) return
      root.miniSearchResults = []
      root.miniSearchText = ""
      root.miniQueueOpen = true
    })
  }

  function moveMiniSelection(delta) {
    if (miniSearchResults.length === 0) return
    miniSelected = Math.max(0, Math.min(miniSelected + delta,
                                        miniSearchResults.length - 1))
  }

  Process {
    id: toggleProcess
    running: false
  }

  // Tracks whether the pointer is anywhere over the pill, independent of the
  // transport buttons' own MouseAreas on top of it. A plain MouseArea here
  // would have its containsMouse flip false whenever the cursor sits over an
  // overlapping child MouseArea (the buttons), flickering the controls/
  // waveform crossfade as the pointer moves across them — HoverHandler
  // doesn't have that "topmost claims hover" limitation.
  HoverHandler {
    id: pillHover
  }

  // No pill outline at all.
  //
  // It used to be on always, then on only while hovered as an affordance for
  // the transport buttons. But drawing a box is what made the width mismatch
  // visible: the slot is sized for the title, the three buttons need about
  // half that, and an outline around the difference turns ordinary bar
  // spacing into a conspicuously half-empty container. With no border the
  // buttons simply sit in the bar like every other icon and there is nothing
  // to look under-filled.

  Row {
    id: row
    // Sit above the click-to-open MouseArea below so the transport buttons
    // get first claim on clicks landing on them (same trick omamusic uses:
    // its inline bar buttons set z:1 over the chip's own click handler).
    z: 1
    anchors.centerIn: parent
    spacing: Style.space(4)

    // The title and the transport controls occupy the same space, crossfading
    // on pill hover: the track name at rest, prev/pause/next while hovered.
    //
    // There is no separate slot for the controls any more. One held the chip's
    // waveform, then the playback time, and both were really just filling
    // space the controls needed — the title is already there and can hand its
    // own space over. The slot is sized to whichever of the two is wider, so
    // the pill does not resize as you move onto it and shove the icons beside
    // it around.
    Item {
      id: mediaSlot
      anchors.verticalCenter: parent.verticalCenter
      // Whatever the chip is showing, the total stays root.maxLabelWidth: the
      // slot gives back exactly the room the note takes when the note is
      // there, and claims it when the note steps aside. So the widget holds
      // one width for as long as a track is loaded, and the bar icons beside
      // it never move while you use it.
      //
      // With no track there is nothing to show but the note, and the slot
      // closes entirely — the one size change left, and the one worth seeing.
      width: root.sizeMode !== "icon" && (root.hasTrack || root.lastError !== "")
        ? root.maxLabelWidth
        : Style.bar.iconSlot
      height: root.barSize
      // Without this the transport buttons spill out of the slot while it is
      // still animating shut.
      clip: true
      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }

      // Left-aligned, not centred: the title starts at this edge too, so the
      // swap happens in place rather than collapsing into the middle. What is
      // left over sits on the right, which is where it already sits whenever
      // a track has a short title.
      Row {
        id: controlsRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)
        // Shown whenever the controls are, and on its own when there is no
        // track at all — it is the way into the player either way.
        enabled: root.showControls || !root.hasTrack || root.sizeMode !== "full"
        opacity: (root.showControls || !root.hasTrack || root.sizeMode !== "full") ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        // The note lives inside the slot, ahead of the transport, rather than
        // outside it. Out there it was laid out beside the slot, so appearing
        // on hover pushed the controls sideways and the swap read as the chip
        // resizing even though the total never changed. In here both the
        // title and this row start at the same left edge and simply cross-
        // fade: nothing moves at all.
        // BarIconButton, like the bar's own icons: it centres the glyph by its
        // painted ink, not its advance width, so the note sits on the same
        // optical centre as its neighbours.
        BarIconButton {
          id: noteButton
          bar: root.bar
          text: root.musicGlyph
          fontSize: root.glyphSize
          foreground: root.lastError !== "" ? Color.urgent : root.noteColor
          fixedWidth: Style.bar.iconSlot
          fixedHeight: root.barSize
          tooltipText: root.lastError !== ""
            ? root.lastError
            : (root.hasTrack
              ? Api.barTrackText(root.title, root.artist, true, true)
              : "Nothing playing")
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton) root.popupOpen = !root.popupOpen
          }
        }

        WidgetButton {
          id: prevButton
          visible: root.hasTrack && root.sizeMode === "full"
          bar: root.bar
          text: "\u{f04ae}"
          fontSize: Style.bar.iconFont
          foreground: root.bar.barForeground
          fixedWidth: Style.bar.iconSlot
          fixedHeight: root.barSize
          tooltipText: "Previous"
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton && root.ytService) root.ytService.previous()
          }
        }
        WidgetButton {
          id: playButton
          visible: root.hasTrack && root.sizeMode === "full"
          bar: root.bar
          text: root.hasTrack ? root.playIcon : "󰝚"
          fontSize: Style.bar.iconFont
          foreground: root.bar.barForeground
          fixedWidth: Style.bar.iconSlot
          fixedHeight: root.barSize
          // Hovering the chip fades the marquee out and swaps these controls
          // in, so the error text disappears at the exact moment you lean in
          // to read it. The tooltip is where it has to survive.
          tooltipText: root.lastError !== ""
            ? root.lastError
            : (root.hasTrack ? (root.playing ? "Pause" : "Play") : "Nothing playing")
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton && root.ytService) root.ytService.togglePlayback()
          }
        }
        WidgetButton {
          id: nextButton
          visible: root.hasTrack && root.sizeMode === "full"
          bar: root.bar
          text: "\u{f04ad}"
          fontSize: Style.bar.iconFont
          foreground: root.bar.barForeground
          fixedWidth: Style.bar.iconSlot
          fixedHeight: root.barSize
          tooltipText: "Next"
          onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton && root.ytService) root.ytService.next()
          }
        }
        // The chevron that used to sit here opened the player — but so does
        // the note, which is permanent and always in the same place. Two
        // controls for one action, one of them only reachable on hover.
        // The note keeps the job.
      }

      // Scrolling title. Two copies separated by a gap, scrolled by exactly
      // one copy-plus-gap, so the second lands where the first started and the
      // loop is seamless with no visible jump.
      //
      // The earlier marquee here left a stray glyph in the bar. The guards that
      // prevent that: a hard clip, a width that can never go negative or zero,
      // scrolling only when the text genuinely overflows, and x reset to 0
      // whenever it stops — so a partial frame can't be left parked on screen.
      // The gradient the marquee is masked through. Not drawn itself — it is
      // here only to be a texture. White is opaque, transparent is cut away.
      Item {
        id: marqueeFade
        anchors.fill: marquee
        visible: false
        layer.enabled: true
        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "#00ffffff" }
            GradientStop { position: 0.06; color: "#ffffffff" }
            GradientStop { position: 0.92; color: "#ffffffff" }
            GradientStop { position: 1.0; color: "#00ffffff" }
          }
        }
      }

      Item {
        id: marquee
        anchors.left: parent.left
        anchors.leftMargin: root.titleInset
        opacity: root.showTitle ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.bar.vertical
        // The clip stays: it is the hard guarantee against a stray glyph
        // parked outside the slot. The fade is layered over it so the text
        // dissolves at the edges instead of being guillotined mid-letter —
        // only worth paying for while it actually scrolls.
        clip: true
        layer.enabled: marquee.overflowing || marquee.lyricStrip
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: marqueeFade
        }
        height: titleA.implicitHeight
        width: Math.max(0, marquee.lyricStrip ? root.maxLabelWidth - root.titleInset
          : Math.min(root.maxLabelWidth - root.titleInset, titleA.implicitWidth))

        // An error outranks the track: it is the one thing here you cannot
        // act on from the bar, and it is why the title is stale or missing.
        // Idle is now said by the note alone — the slot has collapsed to
        // nothing by this point, so there is nowhere to print "Nothing
        // playing" and no need to: an empty bar widget is the message.
        //
        // Title only, no artist. On YouTube the "artist" is the channel and
        // the title usually already carries the artist, so asking for both
        // printed the same fact twice — "LatinHype - Tame Impala - Loser" —
        // and guaranteed the text could never fit, which is what made the
        // marquee scroll constantly. The channel is still one hover away in
        // the tooltip, and spelled out in the panel.
        readonly property string fullText: root.lastError !== ""
          ? root.lastError
          : (root.hasTrack
            ? Api.barTrackText(root.title, root.artist, true, false)
            : "")
        readonly property real gapPx: Style.space(28)
        readonly property bool overflowing: titleA.implicitWidth > width + 1
        // Timed lyrics: the whole song as one strip that moves continuously.
        readonly property bool lyricStrip: root.barLyricsActive
        readonly property bool lyricMode: lyricStrip

        Row {
          id: ticker
          visible: !marquee.lyricStrip
          spacing: marquee.gapPx

          Text {
            id: titleA
            textFormat: Text.PlainText
            text: marquee.fullText
            color: root.lastError !== ""
              ? Color.urgent
              : (root.hasTrack && root.playing
                ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5))
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            textFormat: Text.PlainText
            visible: marquee.overflowing && !marquee.lyricMode
            text: marquee.fullText
            color: titleA.color
            font.family: titleA.font.family
            font.pixelSize: titleA.font.pixelSize
          }
        }

        // Still a loop — reading the whole title is the point of the thing —
        // but it now rests at the start of each pass instead of wrapping
        // straight back into motion. The old version never stood still, which
        // is what made it tiring to sit beside; this gives you a beat to read
        // the opening words, which is the part that identifies the track.
        SequentialAnimation {
          id: scrollAnim
          running: marquee.overflowing && marquee.visible && !marquee.lyricMode
          loops: Animation.Infinite
          PauseAnimation { duration: 2200 }
          NumberAnimation {
            target: ticker
            property: "x"
            from: 0
            to: -(titleA.implicitWidth + marquee.gapPx)
            duration: Math.max(4000, (titleA.implicitWidth + marquee.gapPx) * 22)
          }
          // Back to the start before the next rest, so the pause is always
          // spent showing the beginning of the title rather than the end.
          ScriptAction { script: ticker.x = 0 }
          onRunningChanged: if (!running && !marquee.lyricMode) ticker.x = 0
        }

        // The lyric strip: the title, then every line in order, instrumental
        // breaks as a note. A reading point a little in from the left edge
        // moves through each line exactly across that line's own time (start
        // to the next line's start), so the strip never jumps back: fast lines
        // pass quickly, long breaks drift slowly, and the next words are
        // always coming in from the right.
        Row {
          id: strip
          visible: marquee.lyricStrip
          spacing: marquee.gapPx
          readonly property real readPoint: marquee.width * 0.18

          // Segment 0 is the title; segment i + 1 is lyric line i.
          readonly property var segments: {
            var out = [Api.barTrackText(root.title, root.artist, true, false)]
            var ls = barLyricsClock.lines
            for (var i = 0; i < ls.length; i++) {
              var w = String(ls[i].text || "").trim()
              out.push(w !== "" ? w : "\u266A")
            }
            return out
          }
          readonly property int seg: barLyricsClock.index + 1

          // Knots: (time a segment starts, where it starts on the strip),
          // plus the end of the song. Position between knots follows a
          // monotone cubic (Fritsch-Carlson), so the speed changes smoothly
          // from one line to the next instead of jumping at each boundary.
          property var knots: []
          function rebuildKnots() {
            var ls = barLyricsClock.lines
            var out = []
            for (var i = 0; i < strip.segments.length; i++) {
              var item = stripRepeater.itemAt(i)
              if (!item) { strip.knots = []; return }
              var t = i === 0 ? 0 : Number(ls[i - 1].ms)
              if (out.length > 0 && t <= out[out.length - 1].t) t = out[out.length - 1].t + 1
              out.push({ t: t, x: item.x })
            }
            var last = stripRepeater.itemAt(strip.segments.length - 1)
            var endT = Math.max(out.length ? out[out.length - 1].t + 4000 : 4000,
                                root.ytService ? Number(root.ytService.durationMs || 0) : 0)
            out.push({ t: endT, x: last ? last.x + last.width : 0 })
            // Slopes
            var n = out.length
            var d = [], m = []
            for (var k = 0; k < n - 1; k++) d.push((out[k + 1].x - out[k].x) / Math.max(1, out[k + 1].t - out[k].t))
            for (var k2 = 0; k2 < n; k2++) {
              if (k2 === 0) m.push(d[0] || 0)
              else if (k2 === n - 1) m.push(d[n - 2] || 0)
              else m.push(d[k2 - 1] * d[k2] <= 0 ? 0 : (d[k2 - 1] + d[k2]) / 2)
            }
            for (var k3 = 0; k3 < n - 1; k3++) {
              if (d[k3] === 0) { m[k3] = 0; m[k3 + 1] = 0; continue }
              var a = m[k3] / d[k3], b = m[k3 + 1] / d[k3], h = a * a + b * b
              if (h > 9) { var tau = 3 / Math.sqrt(h); m[k3] = tau * a * d[k3]; m[k3 + 1] = tau * b * d[k3] }
            }
            for (var k4 = 0; k4 < n; k4++) out[k4].m = m[k4]
            strip.knots = out
          }
          function posAt(t) {
            var ks = strip.knots
            if (ks.length < 2) return 0
            if (t <= ks[0].t) return ks[0].x
            if (t >= ks[ks.length - 1].t) return ks[ks.length - 1].x
            var lo = 0, hi = ks.length - 2
            while (lo < hi) { var mid = (lo + hi + 1) >> 1; if (ks[mid].t <= t) lo = mid; else hi = mid - 1 }
            var k0 = ks[lo], k1 = ks[lo + 1]
            var h = k1.t - k0.t, s = (t - k0.t) / h
            var s2 = s * s, s3 = s2 * s
            return (2 * s3 - 3 * s2 + 1) * k0.x + (s3 - 2 * s2 + s) * h * k0.m
                 + (-2 * s3 + 3 * s2) * k1.x + (s3 - s2) * h * k1.m
          }
          onSegmentsChanged: Qt.callLater(rebuildKnots)
          // The Row has laid its texts out once its size settles.
          onImplicitWidthChanged: Qt.callLater(rebuildKnots)
          Connections {
            target: root.ytService
            function onDurationMsChanged() { Qt.callLater(strip.rebuildKnots) }
          }

          // Its own song clock, advanced every frame by real time, so it never
          // waits for a position report. Reports from the backend only steer
          // it gently (or snap it after a seek), so they never show as a
          // stop-and-go. The shared lyrics clock caps its guess at 2 s
          // between reports, which is what made the strip pause.
          property real localT: -1
          FrameAnimation {
            running: marquee.lyricStrip && marquee.visible && strip.knots.length > 1
            onTriggered: {
              var svc = root.ytService
              if (!svc) return
              var c = barLyricsClock
              var target = Number(svc.positionMs || 0)
              if (root.playing && svc.positionStampMs > 0)
                target += Math.max(0, Date.now() - svc.positionStampMs)
              target += c.leadMs - c.offsetMs
              if (strip.localT < 0 || Math.abs(target - strip.localT) > 1200) strip.localT = target
              else {
                if (root.playing) strip.localT += frameTime * 1000
                strip.localT += (target - strip.localT) * Math.min(1, frameTime * 2)
              }
              strip.x = strip.readPoint - strip.posAt(strip.localT)
            }
          }

          // A break is drawn at a fixed width, so its countdown never shifts
          // the strip.
          TextMetrics {
            id: breakMetrics
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            text: "\u266A 0:00"
          }

          Repeater {
            id: stripRepeater
            model: marquee.lyricStrip ? strip.segments : []
            delegate: Item {
              id: segItem
              required property var modelData
              required property int index
              readonly property bool isBreak: index > 0 && modelData === "\u266A"
              readonly property bool isCurrent: index === strip.seg
              width: isBreak ? breakMetrics.advanceWidth : segText.implicitWidth
              height: segText.implicitHeight

              // Seconds until singing comes back, on the break being played.
              readonly property string countdown: {
                if (!isBreak || !isCurrent) return ""
                var ls = barLyricsClock.lines
                if (index >= ls.length) return ""
                var left = Number(ls[index].ms) - strip.localT
                return left > 3000 ? " " + Api.formatTime(left) : ""
              }

              Text {
                id: segText
                textFormat: Text.PlainText
                text: segItem.modelData + segItem.countdown
                color: segItem.isCurrent
                  ? root.bar.barForeground
                  : Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g, root.bar.barForeground.b,
                            segItem.index < strip.seg ? 0.38 : 0.62)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.italic: segItem.index === 0
                Behavior on color { ColorAnimation { duration: 200 } }
              }
              // The part already sung, in the cover's colour: everything of
              // this line left of the reading point.
              Item {
                visible: segItem.isCurrent && !segItem.isBreak && segItem.index > 0
                width: Math.max(0, Math.min(segItem.width, strip.readPoint - (strip.x + segItem.x)))
                height: segItem.height
                clip: true
                Text {
                  textFormat: Text.PlainText
                  text: segText.text
                  color: miniTint.found ? miniTint.accent : Color.accent
                  font: segText.font
                }
              }
            }
          }
        }
      }

      // How far through the track we are, as a line under the title — the
      // same idea as the bar under a YouTube thumbnail. It stays put while
      // the controls swap in on hover: it is status, not a control, and
      // nothing about it changes when the pointer arrives.
      Rectangle {
        id: progressTrack
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(4)
        height: Math.max(1, Style.space(1))
        radius: height / 2
        visible: root.hasTrack && root.sizeMode !== "icon" && !!root.bar && !root.bar.vertical
                 && root.ytService && root.ytService.durationMs > 0
        color: Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g,
                       root.bar.barForeground.b, 0.18)

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          radius: parent.radius
          color: root.bar.barForeground
          width: {
            if (!root.ytService || root.ytService.durationMs <= 0) return 0
            var f = root.ytService.positionMs / root.ytService.durationMs
            return parent.width * Math.max(0, Math.min(1, f))
          }

          // Position arrives in steps as mpv reports it; interpolating
          // between them turns a twitching line into a moving one. Short
          // enough not to lag a seek.
          Behavior on width {
            NumberAnimation { duration: 250; easing.type: Easing.OutQuad }
          }
        }
      }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        if (root.ytService) root.ytService.previous()
      } else if (mouse.button === Qt.RightButton) {
        if (root.ytService) root.ytService.next()
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
    // Double-click the chip: straight to the full player.
    onDoubleClicked: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.openFullPlayer()
    }
    onWheel: function(wheel) {
      if (!root.ytService) return
      var delta = wheel.angleDelta.y > 0 ? 5 : -5
      root.ytService.setVolume(Math.max(0, Math.min(100, root.ytService.volume + delta)))
    }
    onEntered: if (root.bar) root.bar.showTooltip(root,
      root.hasTrack ? (root.title + (root.artist ? " — " + root.artist : "")) : "Nothing playing")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // Where the bar is actually empty.
  //
  // The strip behind the bar has no way to ask for this: island-bar's IPC
  // exposes only syncHidden(), and the PluginBarApi facade handed to widgets
  // carries scalars alone — barSize, colours, position — with no island
  // geometry on it. But that same facade notes it "cannot isolate a visual
  // child from the parent hierarchy of the QML scene that renders it", and
  // that is the way in: this widget really is an item inside the bar's own
  // tree, so it can walk up to the bar's root and measure what is drawn.
  //
  // Occupancy is taken from the leaves — the items with no visible children,
  // i.e. the text and icons that actually paint — rather than from the three
  // island hosts. Leaves are what "empty" is really about, and reading them
  // needs no knowledge of how island-bar names or nests its containers, so a
  // layout change degrades to a wrong-ish gap rather than a broken binding.
  property var ambientGaps: []
  // True while the last measurement differed from the one before it, i.e.
  // while the bar is animating (a drawer opening, a title changing width).
  // The timer then ticks fast so the spectrum follows instead of lagging.
  property bool ambientMoving: false

  readonly property real ambientGapPad: Style.space(10)
  readonly property real ambientMinGap: Style.space(40)

  function barRootItem() {
    var node = root
    var guard = 0
    while (node && node.parent && guard < 64) {
      node = node.parent
      guard++
    }
    return node
  }

  // Only things that actually put ink on the bar count as occupied. The first
  // attempt at this treated any childless item as occupied, which handed the
  // whole width over to a bar-wide MouseArea and left no gaps at all.
  function paintsInk(item) {
    if (item.opacity !== undefined && item.opacity <= 0.02) return false
    if (item.text !== undefined && String(item.text).length > 0) return true
    if (item.source !== undefined && String(item.source).length > 0) return true
    var c = item.color
    if (c !== undefined && c !== null && c.a !== undefined && c.a > 0.05) return true
    var b = item.border
    if (b !== undefined && b !== null && b.width > 0
        && b.color !== undefined && b.color !== null && b.color.a > 0.05) return true
    return false
  }

  // Spans are clamped to whatever clips them on the way down.
  //
  // Without this the scrolling title wrecks the result: the marquee's Text is
  // far wider than the window it shows through and slides continuously, so its
  // measured span crawls leftwards and drags the gap edge with it, popping
  // bars off one at a time. Intersecting with each clipping ancestor gives the
  // span you can actually see, which for a marquee is a fixed window.
  function collectOccupied(item, out, depth, clipLo, clipHi) {
    if (!item || depth > 24) return
    if (!item.visible || !(item.width > 0) || !(item.height > 0)) return
    if (clipHi <= clipLo) return

    var at = item.mapToItem(null, 0, 0)
    if (!at) return
    var lo = at.x
    var hi = at.x + item.width

    if (root.paintsInk(item)) {
      var vlo = Math.max(lo, clipLo)
      var vhi = Math.min(hi, clipHi)
      if (vhi > vlo) out.push([vlo, vhi])
    }

    var nextLo = clipLo
    var nextHi = clipHi
    if (item.clip) {
      nextLo = Math.max(clipLo, lo)
      nextHi = Math.min(clipHi, hi)
    }

    var kids = item.children || []
    for (var i = 0; i < kids.length; i++)
      root.collectOccupied(kids[i], out, depth + 1, nextLo, nextHi)
  }

  function recomputeAmbientGaps() {
    if (!ambientEnabled) return
    var barItem = barRootItem()
    if (!barItem || !(barItem.width > 0)) { ambientGaps = []; return }

    var spans = []
    collectOccupied(barItem, spans, 0, 0, barItem.width)
    if (spans.length === 0) { ambientGaps = [[0, barItem.width]]; return }

    spans.sort(function(a, b) { return a[0] - b[0] })

    // Merge, padded, so two glyphs a few pixels apart do not leave a sliver
    // of spectrum stranded between them.
    var merged = []
    var curLo = spans[0][0] - ambientGapPad
    var curHi = spans[0][1] + ambientGapPad
    for (var i = 1; i < spans.length; i++) {
      var lo = spans[i][0] - ambientGapPad
      var hi = spans[i][1] + ambientGapPad
      if (lo <= curHi) {
        if (hi > curHi) curHi = hi
      } else {
        merged.push([curLo, curHi])
        curLo = lo
        curHi = hi
      }
    }
    merged.push([curLo, curHi])

    // The complement is what is left over.
    var gaps = []
    var cursor = 0
    for (var m = 0; m < merged.length; m++) {
      var start = Math.max(0, merged[m][0])
      if (start - cursor >= ambientMinGap) gaps.push([cursor, start])
      cursor = Math.max(cursor, merged[m][1])
    }
    if (barItem.width - cursor >= ambientMinGap) gaps.push([cursor, barItem.width])

    // Ignore sub-pixel reflow (a clock digit changing width, say) so bars are
    // not switched on and off for a change nobody can see.
    var prev = root.ambientGaps
    if (prev && prev.length === gaps.length) {
      var same = true
      for (var q = 0; q < gaps.length; q++) {
        if (Math.abs(prev[q][0] - gaps[q][0]) > 2 || Math.abs(prev[q][1] - gaps[q][1]) > 2) {
          same = false
          break
        }
      }
      if (same) { ambientMoving = false; return }
    }
    ambientMoving = true
    ambientGaps = gaps
  }

  // The bar's contents resize constantly — a scrolling title, a ticking
  // clock — so this is re-measured on a timer rather than hooked to any one
  // widget's geometry. Cheap: a few hundred item reads, four times a second.
  Timer {
    interval: root.ambientMoving ? 40 : 250
    repeat: true
    running: root.ambientEnabled && !root.vertical
    triggeredOnStart: true
    onTriggered: root.recomputeAmbientGaps()
  }

  // Whether the plugin is making any sound at this instant.
  //
  // `playing` alone is not enough to decide whether to draw. It stays true
  // across a track change while yt-dlp resolves the next URL, which is three
  // or four seconds with mpv's stream gone — the bars sit frozen at their
  // floor with the strip still faded in, which reads as the visualiser being
  // stuck on after the music stopped. It also stays true through any future
  // state bug of the kind that already cost us a stalled play button.
  readonly property bool ambientAudible: {
    var bands = ytService ? ytService.spectrumBands : null
    if (!bands) return false
    for (var i = 0; i < bands.length; i++) {
      if (Number(bands[i]) > 0.02) return true
    }
    return false
  }

  // Held, so a rest in the music does not blink the strip out and back. Only
  // a real stop lasts long enough to trip it.
  property bool ambientSilent: true

  onAmbientAudibleChanged: {
    if (ambientAudible) {
      silenceHold.stop()
      ambientSilent = false
    } else {
      silenceHold.restart()
    }
  }

  Timer {
    id: silenceHold
    interval: 1200
    repeat: false
    onTriggered: root.ambientSilent = true
  }

  // The monitor this copy of the widget is on.
  //
  // A bar surface is built per output (the bar's `Variants { model:
  // Quickshell.screens }`), so this file runs once per monitor — and a
  // PanelWindow that never sets `screen` lands on whichever output Quickshell
  // picks first. Every copy therefore stacked its windows on that one screen:
  // two ambient strips over the laptop panel, none over the external one, each
  // masking with gaps it had measured from a different bar. The strip that had
  // the other monitor's gaps painted the spectrum straight across this
  // monitor's modules, which is what put bars under the clock and the tray.
  //
  // Pinning both windows to this instance's own screen is also what puts the
  // spectrum on every monitor: one bar, one strip, its own gaps.
  readonly property var barWindow: root.QsWindow ? root.QsWindow.window : null
  readonly property var barScreen: barWindow ? barWindow.screen : null

  // Light/dark wallpaper under each ambient bar, so each bar picks the colour
  // that reads against what is actually behind it. Re-sampled when the
  // wallpaper, screen or bar changes.
  property var ambientTones: []
  Process {
    id: tonesProc
    stdout: SplitParser {
      onRead: function(line) {
        var v = String(line).trim().split(/\s+/).map(Number)
        root.ambientTones = v.length === 160 ? v : []
      }
    }
  }
  function refreshTones() {
    if (!root.barScreen || tonesProc.running) return
    tonesProc.command = ["/usr/bin/bash", Qt.resolvedUrl("scripts/strip-tones.sh").toString().replace("file://", ""),
      root.barScreen.name, String(root.barSize), "160", root.bar ? root.bar.position : "top"]
    tonesProc.running = true
  }
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: tonesDebounce.restart()
  }
  // The theme name changes before the wallpaper link does; sampling at once
  // reads the old wallpaper.
  Timer { id: tonesDebounce; interval: 900; onTriggered: root.refreshTones() }
  onBarScreenChanged: refreshTones()
  Component.onCompleted: { refreshTones(); sendLyricsConfig() }

  // The ambient spectrum behind the bar.
  //
  // WlrLayer.Bottom puts it above the wallpaper and below the bar, and the
  // bar's exclusive zone means no ordinary window is ever in that strip, so
  // it cannot be covered. exclusionMode Ignore is essential: reserving space
  // of its own would push every window down by a second bar's height.
  //
  // It fades out whenever nothing is playing, so an idle machine looks
  // exactly as it did before this existed.
  PanelWindow {
    id: ambient
    screen: root.barScreen
    // No screen yet means the window would fall back to Quickshell's first
    // output, which is the stacking this is here to avoid. Nothing is playing
    // that early anyway, so waiting costs nothing.
    visible: root.ambientEnabled && !!root.barScreen && !!root.bar && !root.bar.vertical
    // Follows the bar to whichever horizontal edge it sits on. Anchored to the
    // top unconditionally, a bottom bar left the strip stranded across the top
    // of the wallpaper. Vertical bars never show it at all (see `visible`).
    anchors {
      top: !root.bar || root.bar.position !== "bottom"
      bottom: !!root.bar && root.bar.position === "bottom"
      left: true
      right: true
    }
    implicitHeight: root.barSize
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omar-ytwidget-ambient"
    WlrLayershell.layer: root.bar && root.bar.transparent ? WlrLayer.Bottom : WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Visual-only, same as Omarchy's own bar-drag-ghost window (Bar.qml):
    // an empty input region so this can never steal a click or an
    // in-progress drag (e.g. dragging a widget into an empty bar section)
    // meant for whatever is above or below it.
    mask: Region {}

    AmbientWave {
      anchors.fill: parent
      levels: root.ytService ? root.ytService.spectrumBands : []
      // Islands showing: the islands' own colour. Otherwise the colour the
      // bar picked for its icons and text over this wallpaper, so the
      // spectrum always matches what sits next to it.
      color: root.ambientColor === "island"
        ? (root.bar ? root.bar.background : "#2d353b")
        : (root.bar ? root.bar.barForeground : "white")
      darkColor: root.bar ? root.bar.background : "#2d353b"
      tones: []
      heightFraction: root.ambientHeight
      gaps: root.ambientGaps
      opacity: root.hasTrack && root.playing && !root.ambientSilent ? root.ambientOpacity : 0
      Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutQuad } }
    }
  }

  // Dismissing the mini player.
  //
  // The card used to hold the keyboard with an exclusive layer-shell grab,
  // and that is what made it impossible to click away from: Hyprland routes
  // *all* input to an exclusive surface, so a click on any other output was
  // dropped by the compositor before anything could see it. Not the window
  // you clicked, and not a catcher surface of our own on that output either —
  // the click simply went nowhere, which is why the only way out was to click
  // the screen the card was already on.
  //
  // A focus grab is the primitive that actually fits: input is routed to the
  // listed windows, and a click anywhere else clears the grab rather than
  // vanishing into it. It is what every Omarchy bar popup uses (see
  // Ui/PopupCard.qml), so the card now dismisses the way the rest of the bar
  // already does.
  property var popupFocusToplevel: null

  // Showing or hiding the ambient spectrum window takes keyboard focus away
  // from the card: typing in the search field then lands in whatever window
  // was focused before. Dropping the grab for a moment and taking it again
  // gives the card its focus back.
  property bool grabPaused: false
  property bool grabIncludesBar: false
  Timer {
    id: grabBarTimer
    interval: 300
    onTriggered: root.grabIncludesBar = !cardHover.hovered
  }

  HyprlandFocusGrab {
    id: popupGrab
    // With two windows in a grab Hyprland hands the keyboard to either one,
    // which is why typing sometimes went nowhere. So the grab holds only
    // the card while it opens and whenever the pointer is on it (the card
    // gets the keyboard), and adds the bar's window only while the pointer
    // is elsewhere: a click on another bar icon then opens it in one go,
    // and the keyboard stays with the card, which is still in the grab.
    windows: root.grabIncludesBar && root.QsWindow.window ? [popup, root.QsWindow.window] : [popup]
    active: root.popupOpen && !root.grabPaused
    onCleared: if (!root.grabPaused) root.popupOpen = false
  }

  Timer {
    id: grabResume
    interval: 120
    onTriggered: root.grabPaused = false
  }

  function refocusPopup() {
    if (!root.popupOpen) return
    root.grabPaused = true
    grabResume.restart()
  }

  // Focus moving to a different window closes the card too. The grab only
  // hears about clicks, and focus moves perfectly well without one — a
  // keybind, a workspace switch, a window opening somewhere else.
  //
  // Deliberately the compositor's *toplevel*, not Hyprland's activewindow
  // event: Hyprland re-emits that every time the focused window's title
  // changes, so a background tab renaming itself would shut the card
  // mid-search, while the toplevel's identity only changes when the focus
  // really does.
  Connections {
    target: ToplevelManager

    function onActiveToplevelChanged() {
      if (!root.popupOpen) return
      var active = ToplevelManager.activeToplevel
      if (active && active !== root.popupFocusToplevel) root.popupOpen = false
    }
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (!root.popupOpen) return
      var name = String(event.name)

      if (name === "workspace" || name === "workspacev2") {
        // A layer surface outlives the workspace it was opened on, so without
        // this the card follows you to the next one, grab and all.
        root.popupOpen = false
      } else if (name === "openlayer") {
        // Someone else's popup, launcher or menu is opening and wants the
        // keyboard. This widget's own surfaces are not that — the card can
        // raise the ambient strip from inside itself.
        if (String(event.data || "").indexOf("omar-ytwidget") !== 0)
          root.popupOpen = false
      }
    }
  }

  // A real WlrLayershell surface rather than a PopupCard: PopupCard never
  // reliably delivered keyboard input to the search field here — a blinking
  // cursor with no characters landing, only "working" once the window had
  // lost and regained focus.
  //
  // The keyboard comes from the focus grab above, not from the surface
  // itself. Exclusive layer-shell focus delivers keystrokes too, and is what
  // this used to do, but it puts the compositor in a state where every click
  // on every other monitor is swallowed (see above). The grab hands this
  // surface the keyboard without that.
  PanelWindow {
    id: popup
    // Same per-monitor pinning as the ambient strip: without it the mini
    // player opens on whichever output Quickshell picked first, not the one
    // whose chip was clicked.
    screen: root.barScreen
    visible: root.popupOpen
    // Full-screen + transparent, same trick go-prompt uses: a background
    // MouseArea catches outside clicks to dismiss, while the actual card
    // is just anchored to a corner of it. PanelWindow has no usable
    // focus-loss signal in this Quickshell version to hang dismiss off
    // of instead.
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omar-ytwidget-popup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.popupOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Only the card takes input. The rest of this full-screen layer used to
    // catch every click (to dismiss), which also ate clicks on the bar: you
    // had to click once to close the card and again to open Audio. Outside
    // clicks now pass through; the focus grab below closes the card, and a
    // bar icon closes it through requestPopout like the bar's own popups.
    mask: Region { item: card }

    BorderSurface {
      id: card
      HoverHandler {
        id: cardHover
        onHoveredChanged: {
          if (hovered) { grabBarTimer.stop(); root.grabIncludesBar = false }
          else if (root.popupOpen) grabBarTimer.restart()
        }
      }
      // Clear the bar instead of covering it.
      //
      // This surface sits on the Overlay layer, above the bar's Top layer,
      // and spans the whole output — so anchoring the card to the screen
      // edge parked it on top of the bar, hiding the tray and status icons
      // behind it. Every other panel opens clear of the bar, and this one
      // looked wrong next to them for exactly that reason.
      //
      // The card lives in the top-right on a top or bottom bar, so only a
      // top bar is in its way. On a left or right bar it sits just clear of
      // the bar instead, level with the note button and kept on screen,
      // the way the stock popups place themselves.
      readonly property string barPos: root.bar ? root.bar.position : "top"
      readonly property int barThickness: root.bar ? root.bar.barSize : 0
      readonly property bool onSide: barPos === "left" || barPos === "right"
      // The button's centre in the bar window; popupOpen is read so it is
      // re-measured each time the card opens (mapToItem is not reactive).
      readonly property real noteCentreY: {
        root.popupOpen
        if (!root.barWindow) return 0
        const at = root.mapToItem(root.barWindow.contentItem, 0, 0)
        return at.y + root.height / 2
      }
      x: onSide
        ? (barPos === "left" ? barThickness + Style.gapsOut
                             : parent.width - barThickness - Style.gapsOut - width)
        : parent.width - Style.gapsOut - width
      y: onSide
        ? Math.round(Math.max(Style.gapsOut, Math.min(noteCentreY - height / 2,
                                                      parent.height - height - Style.gapsOut)))
        : (barPos === "top" ? barThickness : 0) + Style.gapsOut
      width: Style.space(340)
      height: root.vertical
        ? Math.min(column.implicitHeight + card.contentTopInset + card.contentBottomInset,
                   onSide ? parent.height - 2 * Style.gapsOut : root.miniCardMaxHeight)
        // Sized to what it holds (the pane is a fixed height here, so the
        // card still keeps one size); a fixed number cut off the bottom of
        // the pane, language chip included, once the card gained rows.
        : Math.min(column.implicitHeight + card.contentTopInset + card.contentBottomInset,
                   onSide ? parent.height - 2 * Style.gapsOut : root.miniCardMaxHeight)
      // No Behavior here: the pane's own height animates and the card follows it.
      radius: Style.cornerRadius
      color: miniTint.found ? miniTint.deepAnimated : Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", miniTint.found ? Qt.rgba(miniTint.accent.r, miniTint.accent.g, miniTint.accent.b, 0.7) : Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

    MouseArea {
      // Swallow clicks so they don't fall through to the dismiss area above.
      anchors.fill: parent
      onClicked: {}
    }

    FocusScope {
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      focus: true
      id: cardScope
      // Esc: first leaves the search box (so the keys below work), then closes.
      Keys.onEscapePressed: root.popupOpen = false
      Keys.onPressed: function(event) { if (root.cardKey(event)) event.accepted = true }

    // Colours from the cover art (see AlbumTint.qml). Covered by the blur.
    AlbumTint {
      id: miniTint
      x: 0
      y: 0
      source: root.ytService ? root.ytService.trackThumbnail : ""
      base: Color.popups.background
    }

    CoverBlur {
      // Reaches the card edges (the surface insets its children), so the
      // blur has no visible rectangle of its own.
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(2) - card.contentLeftInset
      anchors.rightMargin: Style.space(2) - card.contentRightInset
      anchors.topMargin: Style.space(2) - card.contentTopInset
      height: Style.space(230) + card.contentTopInset
      source: root.ytService ? root.ytService.trackThumbnail : ""
      strength: 0.55
      fadeTo: miniTint.found ? miniTint.deepAnimated : Color.popups.background
    }

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(12)

      // Art beside the title, not above it, so the card stays short. The
      // way into the full player sits in the corner.
      RowLayout {
        width: parent.width
        spacing: Style.space(14)


        Rectangle {
          Layout.preferredWidth: Style.space(112)
          Layout.preferredHeight: Style.space(112)
          Layout.alignment: Qt.AlignTop
          radius: Style.space(14)
          color: root.ytService && root.ytService.trackThumbnail !== ""
            ? "transparent"
            : Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g, root.bar.barForeground.b, 0.08)

          RoundedImage {
            anchors.fill: parent
            radius: parent.radius
            lifted: true
            visible: root.ytService && root.ytService.trackThumbnail !== ""
            source: root.ytService ? root.ytService.trackThumbnail : ""
          }
          Text {
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            visible: !root.ytService || root.ytService.trackThumbnail === ""
            text: root.idleGlyph
            color: root.bar.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
          }
          MouseArea {
            anchors.fill: parent
            enabled: root.hasTrack
            cursorShape: root.hasTrack ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.ytService && root.ytService.togglePlayback()
          }
        }

        // Right of the art: the corner actions in one quiet row, then the
        // title and channel.
        ColumnLayout {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          spacing: Style.space(4)
          RowLayout {
            Layout.alignment: Qt.AlignRight
            Layout.topMargin: -Style.space(6)
            Layout.rightMargin: -Style.space(6)
            spacing: Style.space(2)
            FlatButton {
              id: copyLinkButton
              property bool copied: false
              accent: miniTint.accentAnimated
              onAccent: miniTint.onAccent
              buttonSize: Style.space(28)
              iconSize: Style.font.icon
              iconText: copied ? "\u{f012c}" : "\u{f0337}"
              selected: copied
              enabled: !!(root.ytService && root.ytService.track && root.ytService.track.videoId)
              foreground: root.bar.foreground
              tooltipText: copied ? "Link copied" : "Copy link"
              onClicked: {
                var track = root.ytService ? root.ytService.track : null
                if (!track || !track.videoId) return
                // The song itself, not this moment in it.
                Quickshell.clipboardText = "https://www.youtube.com/watch?v=" + encodeURIComponent(track.videoId)
                copied = true
                copiedTimer.restart()
              }
              Timer { id: copiedTimer; interval: 1500; onTriggered: copyLinkButton.copied = false }
            }
            FlatButton {
              accent: miniTint.accentAnimated
              onAccent: miniTint.onAccent
              buttonSize: Style.space(28)
              iconSize: Style.font.icon
              iconText: "\u{f05c3}"
              enabled: !!(root.ytService && root.ytService.track && root.ytService.track.videoId)
              foreground: root.bar.foreground
              tooltipText: "Open on YouTube (at this moment)"
              onClicked: {
                var track = root.ytService ? root.ytService.track : null
                if (!track || !track.videoId) return
                var seconds = Math.floor(Number(root.ytService.positionMs || 0) / 1000)
                var url = "https://www.youtube.com/watch?v=" + encodeURIComponent(track.videoId)
                  + (seconds > 5 ? "&t=" + seconds + "s" : "")
                if (root.playing) root.ytService.pause()
                Qt.openUrlExternally(url)
              }
            }
            FlatButton {
              accent: miniTint.accentAnimated
              onAccent: miniTint.onAccent
              buttonSize: Style.space(28)
              iconSize: Style.font.icon
              iconText: "\u{f0293}"
              foreground: root.bar.foreground
              tooltipText: "Full player (F)"
              onClicked: root.openFullPlayer()
            }
          }
          Column {
            id: cardTitle
            Layout.fillWidth: true
            spacing: Style.space(4)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              id: cardTitleText
              text: root.hasTrack ? root.title : "Nothing playing"
              color: root.bar.foreground
              font.family: Style.font.family
              font.bold: true
              font.pixelSize: Style.font.subtitle
              wrapMode: Text.Wrap
              maximumLineCount: 3
              elide: Text.ElideRight
              // The title opens the full player, like the corner button.
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openFullPlayer()
                onContainsMouseChanged: cardTitleText.font.underline = containsMouse
              }
            }
            Text {
              width: parent.width
              visible: root.artist !== ""
              textFormat: Text.PlainText
              text: root.artist
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }

      // Seek, with the times on the same line.
      RowLayout {
        width: parent.width
        spacing: Style.space(10)
        Text {
          text: Api.formatTime(root.ytService ? root.ytService.positionMs : 0)
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        PanelSlider {
          Layout.fillWidth: true
          minimum: 0
          maximum: Math.max(1, root.ytService ? root.ytService.durationMs : 1)
          value: root.ytService ? root.ytService.positionMs : 0
          fillColor: miniTint.accentAnimated
          knobColor: Qt.lighter(miniTint.accentAnimated, 1.15)
          trackColor: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.14)
          onMoved: function(v) { if (root.ytService) root.ytService.seek(v) }
        }
        Text {
          text: Api.formatTime(root.ytService ? root.ytService.durationMs : 0)
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // Transport: one filled disc, everything else flat.
      RowLayout {
        width: parent.width
        spacing: 0

        FlatButton {

          accent: miniTint.accentAnimated

          onAccent: miniTint.onAccent
          iconText: "\u{f049f}"
          selected: !!(root.ytService && root.ytService.shuffle)
          foreground: Qt.darker(root.bar.foreground, 1.35)
          tooltipText: "Shuffle"
          onClicked: root.ytService && root.ytService.setShuffle(!root.ytService.shuffle)
        }
        Item { Layout.fillWidth: true }
        FlatButton {
          accent: miniTint.accentAnimated
          onAccent: miniTint.onAccent
          iconText: "\u{f04ae}"
          iconSize: Style.font.iconLarge
          foreground: root.bar.foreground
          tooltipText: "Previous"
          onClicked: root.ytService && root.ytService.previous()
        }
        Item { Layout.fillWidth: true }
        FlatButton {
          accent: miniTint.accentAnimated
          onAccent: miniTint.onAccent
          primary: true
          buttonSize: Style.space(52)
          iconSize: Style.font.iconLarge
          iconText: root.playing ? "\u{f03e4}" : "\u{f040a}"
          tooltipText: root.playing ? "Pause" : "Play"
          onClicked: root.ytService && root.ytService.togglePlayback()
        }
        Item { Layout.fillWidth: true }
        FlatButton {
          accent: miniTint.accentAnimated
          onAccent: miniTint.onAccent
          iconText: "\u{f04ad}"
          iconSize: Style.font.iconLarge
          foreground: root.bar.foreground
          tooltipText: "Next"
          onClicked: root.ytService && root.ytService.next()
        }
        Item { Layout.fillWidth: true }
        FlatButton {
          accent: miniTint.accentAnimated
          onAccent: miniTint.onAccent
          iconText: root.ytService && root.ytService.repeat === "track" ? "\u{f0458}" : "\u{f0456}"
          selected: root.ytService && root.ytService.repeat !== "off"
          foreground: Qt.darker(root.bar.foreground, 1.35)
          tooltipText: "Repeat"
          onClicked: root.ytService && root.ytService.cycleRepeat()
        }
      }

      // Volume on its own row, full width.
      RowLayout {
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: root.ytService && root.ytService.volume === 0 ? "\u{f0581}" : "\u{f057e}"
          textFormat: Text.PlainText
          color: Qt.darker(root.bar.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.icon
          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.ytService) root.ytService.setVolume(root.ytService.volume > 0 ? 0 : 50)
          }
        }
        PanelSlider {
          Layout.fillWidth: true
          minimum: 0
          maximum: 100
          value: root.ytService ? root.ytService.volume : 80
          // Neutral, so it never reads as the seek bar.
          fillColor: Qt.darker(root.bar.foreground, 1.1)
          knobColor: root.bar.foreground
          trackColor: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.14)
          onMoved: function(v) { if (root.ytService) root.ytService.setVolume(v) }
        }
      }

      // The card's tools: things you do per song as tiles, and the
      // set-and-forget bar options behind one "Bar" tile.
      RowLayout {
        width: parent.width
        spacing: Style.space(6)

        MiniTile {
          accent: miniTint.accentAnimated
          foreground: root.bar.foreground
          glyph: "\u{f0567}"
          label: "Video"
          on: !!(root.ytService && root.ytService.videoActive)
          enabled: !!(root.ytService && root.ytService.hasTrack)
          tip: root.ytService && root.ytService.videoActive ? "Close the video window (V)" : "Watch the video (V)"
          onPicked: root.toggleVideo()
        }
        MiniTile {
          accent: miniTint.accentAnimated
          foreground: root.bar.foreground
          // Only when this song has timed lyrics to sing along to.
          visible: root.lyricsEnabled && barLyricsClock.synced && barLyricsClock.lines.length > 0
          glyph: "\u{f05cb}"
          label: "Karaoke"
          tip: "Karaoke (opens the big player)"
          onPicked: root.openFullPlayer("karaoke")
        }
        MiniTile {
          accent: miniTint.accentAnimated
          foreground: root.bar.foreground
          glyph: "\u{f066a}"
          label: "EQ"
          on: root.miniEqOpen
          tip: root.miniEqOpen ? "Hide equaliser (E)" : "Equaliser (E)"
          onPicked: root.miniEqOpen = !root.miniEqOpen
        }
        MiniTile {
          id: barTile
          accent: miniTint.accentAnimated
          foreground: root.bar.foreground
          glyph: "\u{f0493}"
          label: "Bar"
          on: barMenu.opened
          tip: "What the bar shows: spectrum, lyrics, chip width"
          onPicked: barMenu.opened ? barMenu.close() : barMenu.open()

          Popup {
            id: barMenu
            // Opens upwards, so it never sits over the tabs.
            y: -height - Style.space(6)
            x: barTile.width - width
            width: Style.space(230)
            padding: Style.space(6)
            background: Rectangle {
              color: Color.popups.background
              radius: Style.space(12)
              border.width: Math.max(1, Style.normalBorderWidth)
              border.color: Qt.rgba(miniTint.accent.r, miniTint.accent.g, miniTint.accent.b, 0.35)
            }
            contentItem: ColumnLayout {
              spacing: Style.space(2)
              Text {
                Layout.leftMargin: Style.space(8)
                Layout.topMargin: Style.space(4)
                Layout.bottomMargin: Style.space(4)
                text: "IN THE BAR"
                color: Qt.darker(Color.popups.text, 1.6)
                font.family: Style.font.family
                font.bold: true
                font.letterSpacing: 1
                font.pixelSize: Style.font.caption
              }
              Repeater {
                model: [
                  { key: "wave", label: "Spectrum", glyph: "\u{f147d}", show: true },
                  { key: "lyrics", label: "Lyrics", glyph: "\u{f0369}", show: root.lyricsEnabled && !root.vertical },
                  { key: "wide", label: "Wide chip", glyph: "\u{f084e}", show: !root.vertical }
                ]
                delegate: Rectangle {
                  id: barOpt
                  required property var modelData
                  readonly property bool isOn: modelData.key === "wave" ? root.ambientEnabled
                    : modelData.key === "lyrics" ? root.lyricsInBar : root.sizeMode === "full"
                  visible: modelData.show
                  Layout.fillWidth: true
                  implicitHeight: Style.space(36)
                  radius: Style.space(8)
                  color: barOptArea.containsMouse ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08) : "transparent"
                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(10)
                    Text {
                      text: barOpt.modelData.glyph
                      color: barOpt.isOn ? miniTint.accent : Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.icon
                    }
                    Text {
                      Layout.fillWidth: true
                      text: barOpt.modelData.label
                      color: Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption + 1
                    }
                    // Switch
                    Rectangle {
                      implicitWidth: Style.space(32)
                      implicitHeight: Style.space(18)
                      radius: height / 2
                      color: barOpt.isOn ? miniTint.accent : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.2)
                      Behavior on color { ColorAnimation { duration: 120 } }
                      Rectangle {
                        width: parent.height - Style.space(4)
                        height: width
                        radius: width / 2
                        y: Style.space(2)
                        x: barOpt.isOn ? parent.width - width - Style.space(2) : Style.space(2)
                        color: barOpt.isOn ? miniTint.onAccent : Color.popups.text
                        Behavior on x { NumberAnimation { duration: 120 } }
                      }
                    }
                  }
                  MouseArea {
                    id: barOptArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      if (barOpt.modelData.key === "wave") root.setAmbient(!root.ambientEnabled)
                      else if (barOpt.modelData.key === "lyrics") root.setLyricsInBar(!root.lyricsInBar)
                      else root.toggleWide()
                    }
                  }
                }
              }
            }
          }
        }
      }

      // Search has no band of its own: typing in the card searches and the
      // results take over the pane. While there is a query, the field shows
      // in the tabs' place; empty, it stays out of sight but keeps the
      // keyboard (an invisible item could not), so typing still lands in it.
      Item {
        id: miniTabs
        width: parent.width
        visible: !root.miniEqOpen
        readonly property bool searching: root.miniSearchText !== ""
        implicitHeight: searching ? Style.space(40) : Style.space(36)
        height: implicitHeight

      Rectangle {
        anchors.fill: parent
        // Under the tabs while there is no query, so the invisible field
        // never sits on top of them and takes their clicks.
        z: miniTabs.searching ? 1 : -1
        opacity: miniTabs.searching ? 1 : 0
        radius: height / 2
        color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, miniSearchField.activeFocus ? 0.10 : 0.06)
        border.width: 1
        border.color: miniSearchField.activeFocus
          ? Qt.rgba(miniTint.accent.r, miniTint.accent.g, miniTint.accent.b, 0.6)
          : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)

        Text {
          id: miniSearchGlyph
          anchors.left: parent.left
          anchors.leftMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          text: "\u{f0349}"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.icon
        }

        TextField {
          id: miniSearchField
          anchors.left: miniSearchGlyph.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          background: Item {}
          horizontalPadding: 0
          placeholderText: root.lastError !== "" ? root.lastError
          : (root.ytService && root.ytService.backendReady ? "Search, or paste a link" : "Starting up…")
          text: root.miniSearchText
          onTextChanged: {
            root.miniSearchText = text
            if (root.miniSearchIsLink) {
              miniLiveSearchTimer.stop()
              if (root.isPlaylistLink(text)) previewTimer.restart()
              else root.miniPreview = null
            } else {
              root.miniPreview = null
              miniLiveSearchTimer.restart()
            }
          }
          onAccepted: {
            miniLiveSearchTimer.stop()
            if (root.miniSearchIsLink) {
              if (root.isPlaylistLink(text)) { root.previewMiniLink(); return }
              root.openMiniLink(); return
            }
            if (root.miniSearchResults.length > 0) root.playSelectedResult()
            else root.runMiniSearch(true)
          }
          Keys.onDownPressed: root.moveMiniSelection(1)
          Keys.onUpPressed: root.moveMiniSelection(-1)
          Keys.onEscapePressed: function(event) { cardScope.forceActiveFocus(); event.accepted = true }
        }
      }

      // Tabs: text with an underline in the cover's colour.
      Item {
        id: tabsRow
        anchors.fill: parent
        visible: !miniTabs.searching
        readonly property var tabs: [
          { key: "next", label: "Up next" },
          { key: "recent", label: "Recent" },
          { key: "lists", label: "Lists" }
        ].concat(root.lyricsEnabled ? [{ key: "lyrics", label: "Lyrics" }] : [])

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 1
          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.10)
        }
        Row {
          anchors.fill: parent
          Repeater {
            model: tabsRow.tabs
            delegate: Item {
              id: tabCell
              required property var modelData
              readonly property bool active: modelData.key === root.miniTab
              width: tabsRow.width / Math.max(1, tabsRow.tabs.length)
              height: tabsRow.height
              Text {
                anchors.centerIn: parent
                text: tabCell.modelData.label
                textFormat: Text.PlainText
                color: tabCell.active ? root.bar.foreground
                  : (tabArea.containsMouse ? Qt.darker(root.bar.foreground, 1.15) : Qt.darker(root.bar.foreground, 1.5))
                font.family: Style.font.family
                font.bold: tabCell.active
                font.pixelSize: Style.font.caption + 1
              }
              Rectangle {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - Style.space(8)
                height: Style.space(2)
                radius: 1
                visible: tabCell.active
                color: miniTint.accentAnimated
              }
              MouseArea {
                id: tabArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.miniTab = tabCell.modelData.key; root.miniTabTouched = true; root.clearMiniSearch() }
              }
            }
          }
        }
      }
      }

      // One fixed-height pane. Results, a pasted playlist, the equaliser and
      // the video controls take it over while they are open, so the card
      // itself never changes size.
      Item {
        id: pane
        width: parent.width
        readonly property real maxHeight: root.miniPaneHeight + (root.miniEqOpen ? miniTabs.implicitHeight + column.spacing : 0)
        // Vertical bar: the rows' real height, clamped. Everything but search
        // results and the Up next / Recent / Lists rows wants the full pane.
        readonly property real wantHeight: {
          if (!root.vertical || showOptions || showPreview) return maxHeight
          var rows = showResults ? miniResultList.contentHeight
                   : root.miniTab === "lyrics" ? maxHeight : tabList.contentHeight
          return Math.max(root.miniPaneMinHeight, Math.min(maxHeight, rows))
        }
        height: wantHeight
        Behavior on height {
          enabled: root.vertical
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        clip: true

        readonly property bool showOptions: root.miniEqOpen || !!(root.ytService && root.ytService.videoActive)
        readonly property bool showResults: !showOptions && root.miniSearchResults.length > 0
        readonly property bool showPreview: !showOptions && !showResults && root.miniPreview !== null

        // ---- equaliser and video controls
        Flickable {
          anchors.fill: parent
          visible: pane.showOptions
          contentHeight: optionsColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar {}

          Column {
            id: optionsColumn
            width: parent.width
            spacing: Style.space(10)

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: !!(root.ytService && root.ytService.videoActive)

              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                Text {
                  text: "QUALITY"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Dropdown {
                  Layout.fillWidth: true
                  showLabel: false
                  options: {
                    var out = []
                    var hs = root.ytService ? root.ytService.videoHeights : []
                    for (var i = 0; i < hs.length; i++)
                      out.push({ value: String(hs[i]), label: hs[i] + "p" })
                    return out
                  }
                  value: root.ytService ? String(root.ytService.videoHeight) : ""
                  foreground: root.bar.foreground
                  onChanged: function(value) {
                    if (root.ytService) root.ytService.setVideoQuality(parseInt(value, 10))
                  }
                }
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                Text {
                  text: "SPEED"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Dropdown {
                  Layout.fillWidth: true
                  showLabel: false
                  options: {
                    var out = []
                    var sp = root.ytService ? root.ytService.videoSpeeds : []
                    for (var i = 0; i < sp.length; i++)
                      out.push({ value: String(sp[i]), label: (sp[i] === 1 ? "Normal" : sp[i] + "x") })
                    return out
                  }
                  value: root.ytService ? String(root.ytService.videoSpeed) : "1"
                  foreground: root.bar.foreground
                  onChanged: function(value) {
                    if (root.ytService) root.ytService.setVideoSpeed(parseFloat(value))
                  }
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.miniEqOpen

              // The live sound and the ten bands in one control; presets as
              // chips above it.
              EqGraph {
                width: parent.width
                height: pane.height
                compact: true
                service: root.ytService
                foreground: root.bar.foreground
                accent: miniTint.accentAnimated
                fadeTo: miniTint.found ? miniTint.deepAnimated : Color.popups.background
              }
            }
          }
        }

        // ---- search results
        ListView {
          id: miniResultList
          anchors.fill: parent
          visible: pane.showResults
          model: root.miniSearchResults
          spacing: root.miniRowSpacing
          clip: true
          currentIndex: root.miniSelected
          highlightRangeMode: ListView.ApplyRange
          preferredHighlightBegin: 0
          preferredHighlightEnd: height
          ScrollBar.vertical: ScrollBar {}

          delegate: TrackRow {
            width: miniResultList.width
            item: modelData
            compact: false
            fg: root.bar.foreground
            highlighted: index === root.miniSelected
            onPlayRequested: {
              root.miniSelected = index
              root.playFromSearch(modelData)
            }
            onQueueRequested: root.ytService && root.ytService.addToQueue(modelData)
          }
        }

        // ---- pasted playlist link
        Column {
          anchors.fill: parent
          visible: pane.showPreview
          spacing: Style.space(6)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Column {
              Layout.fillWidth: true
              Text {
                width: parent.width
                text: root.miniPreview ? (root.miniPreview.title || "Playlist") : ""
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                text: root.miniPreview ? root.miniPreview.items.length + " tracks" : ""
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            FlatButton {
              accent: miniTint.accentAnimated
              onAccent: miniTint.onAccent
              iconText: "\u{f049f}"
              buttonSize: Style.space(32)
              foreground: root.bar.foreground
              tooltipText: "Shuffle the playlist"
              onClicked: root.playMiniPreview(true)
            }
            FlatButton {
              accent: miniTint.accentAnimated
              onAccent: miniTint.onAccent
              primary: true
              iconText: "\u{f040a}"
              buttonSize: Style.space(36)
              tooltipText: "Play the playlist"
              onClicked: root.playMiniPreview(false)
            }
          }

          ListView {
            width: parent.width
            height: parent.height - Style.space(44)
            clip: true
            spacing: root.miniRowSpacing
            model: root.miniPreview ? root.miniPreview.items : []
            ScrollBar.vertical: ScrollBar {}
            delegate: TrackRow {
              width: ListView.view.width
              item: modelData
              compact: false
              fg: root.bar.foreground
              onPlayRequested: root.ytService && root.ytService.playQueueFrom(root.miniPreview.items, index)
              onQueueRequested: root.ytService && root.ytService.addToQueue(modelData)
            }
          }
        }

        // ---- lyrics
        LyricsView {
          anchors.fill: parent
          visible: !pane.showOptions && !pane.showResults && !pane.showPreview && root.miniTab === "lyrics"
          compact: true
          service: root.ytService
          foreground: root.bar.foreground
          accent: miniTint.accentAnimated
          fadeTo: miniTint.found ? miniTint.deepAnimated : Color.popups.background
          onOpenPlayerRequested: root.openFullPlayer()
          onKaraokeRequested: root.openFullPlayer("karaoke")
        }

        // ---- tabs
        ListView {
          id: tabList
          anchors.fill: parent
          visible: !pane.showOptions && !pane.showResults && !pane.showPreview && root.miniTab !== "lyrics"
          clip: true
          spacing: root.miniRowSpacing
          ScrollBar.vertical: ScrollBar {}
          model: root.miniTab === "next" ? (root.ytService ? root.ytService.queue : [])
               : root.miniTab === "recent" ? (root.ytService ? root.ytService.playHistory : [])
               : (root.ytService ? root.ytService.playlists : [])

          delegate: Loader {
            width: tabList.width
            sourceComponent: root.miniTab === "lists" ? listRow : trackRowComp
            property var rowData: modelData
            property int rowIndex: index
          }

          Text {
            anchors.centerIn: parent
            visible: tabList.count === 0
            text: root.miniTab === "next" ? "Queue is empty"
                : root.miniTab === "recent" ? "Nothing played yet" : "No playlists yet"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Component {
          id: trackRowComp
          TrackRow {
            accent: miniTint.accentAnimated
            item: rowData
            compact: false
            fg: root.bar.foreground
            highlighted: root.miniTab === "next" && rowIndex === (root.ytService ? root.ytService.queueIndex : -1)
            queueGlyph: root.miniTab === "next" ? "\u{f0156}" : "\u{f0415}"
            onPlayRequested: {
              if (!root.ytService) return
              if (root.miniTab === "next") root.ytService.playQueueFrom(root.ytService.queue, rowIndex)
              else root.ytService.playNow(rowData)
            }
            onQueueRequested: {
              if (!root.ytService) return
              if (root.miniTab === "next") root.ytService.removeFromQueue(rowIndex)
              else root.ytService.addToQueue(rowData)
            }
          }
        }

        Component {
          id: listRow
          Rectangle {
            height: Style.space(40)
            radius: Style.space(10)
            color: listHover.containsMouse ? Style.hoverFillFor(root.bar.foreground, miniTint.accentAnimated) : "transparent"
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(10)
              Text {
                text: "\u{f0cb8}"
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
                color: miniTint.accentAnimated
              }
              Text {
                Layout.fillWidth: true
                text: rowData.name
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                text: rowData.count + " tracks"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            MouseArea {
              id: listHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (!root.ytService) return
                root.ytService.getPlaylist(rowData.id, function(ok, data) {
                  if (ok && data && data.items && data.items.length > 0)
                    root.miniPreview = { title: rowData.name, items: data.items }
                })
              }
            }
          }
        }
      }


      Timer {
        id: miniLiveSearchTimer
        interval: 300
        repeat: false
        onTriggered: root.runMiniSearch(false)
      }

      Timer {
        id: previewTimer
        interval: 450
        repeat: false
        onTriggered: root.previewMiniLink()
      }
    }

    }
    }
  }
}
