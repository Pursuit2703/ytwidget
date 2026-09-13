import QtQuick

// The "service" kind singleton the host creates at shell startup. Panel.qml
// gets this instance injected as `service`. All the actual connection logic
// lives in PlayerConnection.qml (shared with BarWidget.qml, which holds its
// own separate instance — see that file for why).
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "omar.ytwidget"

  readonly property string lifecycle: conn.lifecycle
  readonly property bool playing: conn.playing
  // See BarWidget.qml's `playing` alias for why this can't just be `playing`
  // while a video window is open.
  readonly property bool effectivePlaying: conn.videoActive ? conn.videoPlaying : conn.playing
  readonly property bool resolving: conn.resolving
  readonly property bool shuffle: conn.shuffle
  readonly property string repeat: conn.repeat
  readonly property int volume: conn.volume
  readonly property bool muted: conn.muted
  readonly property int positionMs: conn.positionMs
  readonly property int durationMs: conn.durationMs
  readonly property var track: conn.track
  readonly property var queue: conn.queue
  readonly property int queueIndex: conn.queueIndex
  readonly property var playHistory: conn.playHistory
  readonly property var playlists: conn.playlists
  readonly property var eq: conn.eq
  readonly property var eqBands: conn.eqBands
  readonly property string eqPreset: conn.eqPreset
  readonly property var eqLabels: conn.eqLabels
  readonly property var eqPresets: conn.eqPresets
  readonly property int crossfadeMs: conn.crossfadeMs
  readonly property bool videoActive: conn.videoActive
  readonly property bool videoPlaying: conn.videoPlaying
  readonly property real videoSpeed: conn.videoSpeed
  readonly property int videoHeight: conn.videoHeight
  readonly property var videoHeights: conn.videoHeights
  readonly property var videoSpeeds: conn.videoSpeeds
  readonly property bool videoReady: conn.videoReady
  readonly property string lastError: conn.lastError
  readonly property var spectrumBands: conn.spectrumBands
  readonly property bool hasTrack: conn.hasTrack
  readonly property string trackTitle: conn.trackTitle
  readonly property string trackArtist: conn.trackArtist
  readonly property string trackThumbnail: conn.trackThumbnail
  readonly property bool backendReady: conn.backendReady

  function ensureRunning() { conn.ensureRunning() }
  function search(query, limit, callback) { conn.search(query, limit, callback) }
  function playNow(item) { conn.playNow(item) }
  function playQueueFrom(items, index) { conn.playQueueFrom(items, index) }
  function openLink(url, callback) { conn.openLink(url, callback) }
  function addToQueue(item) { conn.addToQueue(item) }
  function addAllToQueue(items, callback) { conn.addAllToQueue(items, callback) }
  function enqueueLink(url, callback) { conn.enqueueLink(url, callback) }
  function removeFromQueue(index) { conn.removeFromQueue(index) }
  function togglePlayback() { conn.togglePlayback() }
  function pause() { conn.pause() }
  function play() { conn.play() }
  function next() { conn.next() }
  function previous() { conn.previous() }
  function seek(ms) { conn.seek(ms) }
  function setVolume(value) { conn.setVolume(value) }
  function setCrossfadeMs(ms) { conn.setCrossfadeMs(ms) }
  function showVideo(videoId, callback) { conn.showVideo(videoId, callback) }
  function hideVideo() { conn.hideVideo() }
  function setSubtitleLang(lang) { conn.setSubtitleLang(lang) }
  function setVideoSpeed(speed) { conn.setVideoSpeed(speed) }
  function setVideoQuality(height) { conn.setVideoQuality(height) }
  function prepareVideo(videoId) { conn.prepareVideo(videoId) }
  function setVideoDefaults(height, windowPercent, gpu) { conn.setVideoDefaults(height, windowPercent, gpu) }
  function setIdleMinutes(minutes) { conn.setIdleMinutes(minutes) }
  function setShuffle(value) { conn.setShuffle(value) }
  function cycleRepeat() { conn.cycleRepeat() }
  function setEqBand(index, gain) { conn.setEqBand(index, gain) }
  function setEqPreset(name) { conn.setEqPreset(name) }
  function cycleEqPreset() { conn.cycleEqPreset() }
  function listAudioOutputs(callback) { conn.listAudioOutputs(callback) }
  function setAudioOutput(sinkName) { conn.setAudioOutput(sinkName) }
  function listPlaylists(callback) { conn.listPlaylists(callback) }
  function getPlaylist(playlistId, callback) { conn.getPlaylist(playlistId, callback) }
  function createPlaylist(name, items, callback) { conn.createPlaylist(name, items, callback) }
  function deletePlaylist(playlistId) { conn.deletePlaylist(playlistId) }
  function addToPlaylist(playlistId, item, callback) { conn.addToPlaylist(playlistId, item, callback) }
  function removeFromPlaylist(playlistId, videoId) { conn.removeFromPlaylist(playlistId, videoId) }
  function importPlaylist(url, name, callback) { conn.importPlaylist(url, name, callback) }

  PlayerConnection {
    id: conn
  }
}
