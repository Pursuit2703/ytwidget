import QtQuick
import Quickshell
import Quickshell.Io

import "Api.js" as Api

Item {
  id: root

  visible: false
  width: 0
  height: 0

  property bool wanted: false
  readonly property var activeSocket: socketLoader.item
  readonly property bool connected: !!(activeSocket && activeSocket.connected)
  property string lifecycle: ""
  property var lastState: null
  property int nextId: 1
  property var pending: ({})
  property int reconnectAttempt: 0
  property string lineBuffer: ""
  property string socketPath: ""

  signal stateReceived(var state)
  signal spectrumReceived(var bands)

  function resetPending(reason) {
    var waiters = pending
    pending = ({})
    var message = String(reason || "Playback is unavailable")
    for (var id in waiters) {
      var callback = waiters[id]
      if (typeof callback === "function") callback(false, null, message)
    }
  }

  function sendCommand(name, fields, callback) {
    var socket = activeSocket
    if (!socket || !socket.connected) {
      if (typeof callback === "function") callback(false, null, "Not connected")
      return 0
    }
    var id = nextId++
    var payload = { v: 1, id: id, command: String(name || "") }
    Api.assign(payload, fields || {})
    payload.v = 1
    payload.id = id
    payload.command = String(name || "")
    var nextPending = ({})
    for (var existing in pending) nextPending[existing] = pending[existing]
    nextPending[String(id)] = typeof callback === "function" ? callback : null
    pending = nextPending
    socket.write(JSON.stringify(payload) + "\n")
    socket.flush()
    return id
  }

  function handleChunk(chunk) {
    var split = Api.splitSocketBuffer(root.lineBuffer, chunk, Api.MAX_SOCKET_LINE)
    if (split.overflow) {
      root.lineBuffer = ""
      root.resetPending("Backend sent a message that was too large")
      root.tearDownSocket()
      return
    }
    root.lineBuffer = split.buffer
    var lines = split.lines || []
    for (var i = 0; i < lines.length; i++) root.handleLine(lines[i])
  }

  function handleLine(line) {
    var message = Api.parseJson(line, null)
    if (!message || typeof message !== "object") return
    if (message.type === "event" && message.event === "spectrum") {
      spectrumReceived(message.bands || [])
      return
    }
    if (message.type === "event" && message.state) {
      lastState = message.state
      lifecycle = String(message.state.lifecycle || "")
      stateReceived(message.state)
      return
    }
    if (message.type !== "response") return
    var id = String(message.id || "")
    var callback = pending[id]
    if (callback === undefined) return
    var nextPending = ({})
    for (var key in pending) if (key !== id) nextPending[key] = pending[key]
    pending = nextPending
    if (message.ok === true) {
      var result = message.result || ({})
      if (result && typeof result === "object" && result.lifecycle !== undefined) {
        lastState = result
        lifecycle = String(result.lifecycle || lifecycle)
        stateReceived(result)
      }
      if (typeof callback === "function") callback(true, result, "")
    } else if (typeof callback === "function") {
      var error = message.error || {}
      callback(false, null, String(error.message || "Command failed"))
    }
  }

  function tearDownSocket() {
    reconnectTimer.stop()
    socketLoader.active = false
    lifecycle = ""
    lastState = null
    reconnectAttempt = 0
    lineBuffer = ""
  }

  onWantedChanged: {
    if (wanted) return
    tearDownSocket()
    resetPending("Playback stopped")
  }

  onSocketPathChanged: {
    if (!socketLoader.active) return
    tearDownSocket()
  }

  onConnectedChanged: if (connected) reconnectAttempt = 0

  Component {
    id: socketComponent
    Socket {
      id: socket
      path: root.socketPath
      connected: false
      parser: SplitParser {
        splitMarker: ""
        onRead: function(chunk) { root.handleChunk(chunk) }
      }
      Component.onCompleted: connected = true
      onConnectionStateChanged: {
        if (!connected) root.lifecycle = ""
      }
      onError: function() {
        connected = false
        root.lifecycle = ""
      }
    }
  }

  Loader {
    id: socketLoader
    active: false
    sourceComponent: socketComponent
  }

  Timer {
    id: reconnectTimer
    interval: Math.min(1500, 180 + root.reconnectAttempt * 120)
    repeat: true
    triggeredOnStart: true
    running: root.wanted && !root.connected && root.socketPath !== ""
    onTriggered: {
      root.reconnectAttempt = Math.min(24, root.reconnectAttempt + 1)
      if (socketLoader.active) {
        socketLoader.active = false
        return
      }
      socketLoader.active = true
    }
  }
}
