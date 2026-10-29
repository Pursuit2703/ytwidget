import QtQuick

// Playback time for following lyrics, smooth between backend updates.
//
// The backend's position reaches the UI on irregular broadcasts (mpv's
// time-pos throttled to 50 ms, plus a once-a-second heartbeat), so binding
// lyrics straight to positionMs would make the highlight lag and stutter.
// This keeps its own clock: the last reported position plus the time since
// it arrived, ticking every 50 ms while playing and re-synced on every
// update or seek. `index` is the line being sung.
QtObject {
  id: root

  property var service: null
  property bool active: true
  // Light a line a moment before its stamp: the eye is slower than the ear.
  property int leadMs: 150

  readonly property var lyrics: service ? service.lyrics : null
  readonly property var lines: lyrics && lyrics.lines ? lyrics.lines : []
  readonly property bool synced: !!lyrics && (lyrics.status === "synced" || lyrics.status === "captions")
  readonly property int offsetMs: lyrics ? Number(lyrics.offsetMs || 0) : 0
  readonly property bool playing: !!(service && service.effectivePlaying)

  property real nowMs: 0
  property int index: -1
  // How far through the current line we are (0..1), measured to the next
  // line's start, and how long until the next line. Drive the word-by-word
  // fill and the countdown dots in a break.
  property real progress: 0
  property real nextInMs: -1

  function tick() {
    if (!service) return
    var pos = Number(service.positionMs || 0)
    if (playing && service.positionStampMs > 0)
      pos += Math.max(0, Math.min(2000, Date.now() - service.positionStampMs))
    // Never step back a hair: a late position report would otherwise make
    // the highlight flick back to the previous line at a boundary. A real
    // seek backwards is bigger than this and goes through.
    if (playing && pos < nowMs && nowMs - pos < 1200) pos = nowMs
    nowMs = pos
    var t = pos - offsetMs + leadMs
    index = synced ? lineAt(t) : -1
    if (synced && lines.length > 0) {
      var startMs = index >= 0 ? Number(lines[index].ms) : 0
      var nextMs = index + 1 < lines.length ? Number(lines[index + 1].ms) : -1
      if (nextMs > startMs) {
        progress = Math.max(0, Math.min(1, (t - startMs) / (nextMs - startMs)))
        nextInMs = Math.max(0, nextMs - t)
      } else {
        progress = 1
        nextInMs = -1
      }
    } else {
      progress = 0
      nextInMs = -1
    }
  }

  // Last line whose time has come (binary search; lines are sorted).
  function lineAt(ms) {
    var lo = 0, hi = lines.length - 1, found = -1
    while (lo <= hi) {
      var mid = (lo + hi) >> 1
      if (Number(lines[mid].ms) <= ms) { found = mid; lo = mid + 1 }
      else hi = mid - 1
    }
    return found
  }

  property Timer timer: Timer {
    interval: 50
    repeat: true
    running: root.active && root.synced
    triggeredOnStart: true
    onTriggered: root.tick()
  }

  property Connections positionWatch: Connections {
    target: root.service
    function onPositionMsChanged() { root.tick() }
  }

  onLinesChanged: tick()
  onOffsetMsChanged: tick()
  onPlayingChanged: tick()
}
