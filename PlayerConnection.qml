import QtQuick
import Quickshell
import Quickshell.Io

import "Api.js" as Api

// Self-contained connection to the ytwidget backend daemon: starts it on
// demand and keeps a live NDJSON socket open, exposing flattened state and
// action functions. Used both by Service.qml (the shared singleton Panel.qml
// binds to) and directly by BarWidget.qml — the shell's cross-widget service
// lookup (bar.shell.serviceFor) turned out to reliably return null for a
// third-party bar widget looking up its own service, so rather than depend
// on that, each surface holds its own connection to the same daemon and they
// stay in sync because the daemon broadcasts state to every connected client.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // manifest.__sourceDir is stripped for third-party plugins (a host security
  // boundary), so resolve our own directory from this QML file's location.
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    return url.replace(/^file:\/\//, "").replace(/\/$/, "")
  }

  // ---- Flattened state, bound from the backend's NDJSON events ----
  property string lifecycle: ""
  property bool playing: false
  property bool resolving: false
  property bool shuffle: false
  property string repeat: "off"
  property int volume: 80
  property bool muted: false
  property int positionMs: 0
  property int durationMs: 0
  property var track: null
  property var queue: []
  property int queueIndex: -1
  property var playHistory: []
  property var playlists: []
  property var eq: ({ bands: [0,0,0,0,0,0,0,0,0,0], preset: "Flat", labels: [], presets: [] })
  // Flat aliases matching omamusic's EqBar.qml (service.eqBands/eqPreset/eqLabels),
  // copied verbatim from omamusic — keep this shape so it works unmodified.
  readonly property var eqBands: eq.bands
  readonly property string eqPreset: eq.preset
  readonly property var eqLabels: eq.labels
  readonly property var eqPresets: eq.presets || []
  property int crossfadeMs: 500
  property bool videoActive: false
  property bool videoPlaying: false
  property real videoSpeed: 1.0
  property int videoHeight: 0
  property var videoHeights: []
  property var videoSpeeds: [0.25,0.5,0.75,1.0,1.25,1.5,1.75,2.0]
  property bool videoReady: false
  property string lastError: ""
  property var spectrumBands: [0,0,0,0,0,0,0,0,0,0]

  readonly property bool hasTrack: !!track
  readonly property string trackTitle: track ? String(track.name || "") : ""
  readonly property string trackArtist: track ? String(track.subtitle || "") : ""
  readonly property string trackThumbnail: track ? String(track.thumbnail || "") : ""
  readonly property bool backendReady: backendClient.connected && lifecycle === "ready"

  function _applyState(state) {
    if (!state) return
    lifecycle = String(state.lifecycle || lifecycle)
    playing = !!state.playing
    resolving = !!state.resolving
    shuffle = !!state.shuffle
    repeat = String(state.repeat || "off")
    volume = Number(state.volume !== undefined ? state.volume : volume)
    muted = !!state.muted
    positionMs = Number(state.position_ms || 0)
    durationMs = Number(state.duration_ms || 0)
    track = state.track || null
    queue = state.queue || []
    queueIndex = state.queue_index !== undefined ? Number(state.queue_index) : -1
    if (state.play_history !== undefined) playHistory = state.play_history || []
    if (state.playlists !== undefined) playlists = state.playlists || []
    if (state.eq) eq = state.eq
    if (state.crossfade_ms !== undefined) crossfadeMs = Number(state.crossfade_ms)
    videoActive = !!state.video_active
    videoPlaying = !!state.video_playing
    if (state.video_speed !== undefined) videoSpeed = Number(state.video_speed)
    if (state.video_height !== undefined) videoHeight = Number(state.video_height)
    if (state.video_heights !== undefined) videoHeights = state.video_heights || []
    if (state.video_speeds !== undefined) videoSpeeds = state.video_speeds || videoSpeeds
    videoReady = !!state.video_ready
    lastError = String(state.error || "")
  }

  function ensureRunning() {
    if (!daemonManager.serviceActive && !daemonManager.busy) daemonManager.start()
    backendClient.wanted = true
  }

  function send(command, fields, callback) {
    ensureRunning()
    backendClient.sendCommand(command, fields || {}, callback)
  }

  // ---- Actions ----
  function search(query, limit, callback) { send("search", { query: query, limit: limit || 20 }, callback) }
  function playNow(item) { send("load", { item: item, play: true }) }
  function playQueueFrom(items, index) { send("load", { items: items, index: index || 0, play: true }) }
  // A playlist link deliberately replaces the queue — see server.open_link.
  function openLink(url, callback) { send("open_link", { url: url, play: true }, callback) }
  function addToQueue(item) { send("add_to_queue", { item: item }) }
  function removeFromQueue(index) { send("remove_from_queue", { index: index }) }
  function togglePlayback() { send("toggle", {}) }
  function pause() { send("pause", {}) }
  function play() { send("play", {}) }
  function next() { send("next", {}) }
  function previous() { send("previous", {}) }
  function seek(ms) { send("seek", { position_ms: ms }) }
  function setVolume(value) { send("set_volume", { volume: value }) }
  function setCrossfadeMs(ms) { send("set_crossfade_ms", { ms: ms }) }
  // videoId is optional: omitted, the window shows whatever is playing and
  // hands the playhead back to the audio deck when it closes.
  function showVideo(videoId, callback) { send("show_video", { video_id: videoId || "" }, callback) }
  function hideVideo() { send("hide_video", {}) }
  function setSubtitleLang(lang) { send("set_subtitle_lang", { lang: lang }) }
  function setVideoSpeed(speed) { send("set_video_speed", { speed: speed }) }
  function setVideoQuality(height) { send("set_video_quality", { height: height }) }
  // Resolve the ladder ahead of the click so the window can skip yt-dlp.
  function prepareVideo(videoId) { send("prepare_video", { video_id: videoId || "" }) }
  function setVideoDefaults(height, windowPercent, gpu) {
    send("set_video_defaults", { height: height, window_percent: windowPercent, gpu: gpu || "" })
  }
  function setIdleMinutes(minutes) { send("set_idle_minutes", { minutes: minutes }) }
  function setShuffle(value) { send("set_shuffle", { shuffle: value }) }
  function cycleRepeat() { send("cycle_repeat", {}) }
  function setEqBand(index, gain) { send("set_eq_band", { index: index, gain: gain }) }
  function setEqPreset(name) { send("set_eq_preset", { name: name }) }
  function cycleEqPreset() { send("cycle_eq_preset", {}) }
  function listAudioOutputs(callback) { send("list_audio_outputs", {}, callback) }
  function setAudioOutput(sinkName) { send("set_audio_output", { sink_name: sinkName }) }
  function listPlaylists(callback) { send("list_playlists", {}, callback) }
  function getPlaylist(playlistId, callback) { send("get_playlist", { playlist_id: playlistId }, callback) }
  function createPlaylist(name, items, callback) { send("create_playlist", { name: name, items: items }, callback) }
  function deletePlaylist(playlistId) { send("delete_playlist", { playlist_id: playlistId }) }
  function addToPlaylist(playlistId, item) { send("add_to_playlist", { playlist_id: playlistId, item: item }) }
  function removeFromPlaylist(playlistId, videoId) {
    send("remove_from_playlist", { playlist_id: playlistId, video_id: videoId })
  }

  DaemonManager {
    id: daemonManager
    pluginDir: root.pluginDir
    onStarted: backendClient.wanted = true
  }

  BackendClient {
    id: backendClient
    socketPath: daemonManager.socketPath
    onStateReceived: function(state) { root._applyState(state) }
    onSpectrumReceived: function(bands) { root.spectrumBands = bands }
  }

  Component.onCompleted: ensureRunning()
}
