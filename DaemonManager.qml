import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  visible: false
  width: 0
  height: 0

  property string pluginDir: ""
  property bool binaryAvailable: false
  property bool binaryChecked: false
  property bool socketChecked: false
  property string socketPath: ""
  property bool serviceActive: false
  property bool automaticSetupAttempted: false
  readonly property bool playbackReady: binaryAvailable
  readonly property bool setupRequired: binaryChecked && !playbackReady
  readonly property bool running: serviceActive
  property bool busy: false
  property bool setupBusy: false
  property string lastError: ""

  signal started()
  signal stopped()
  signal setupSucceeded()
  signal setupFailed(string reason)

  function checkRequirements() {
    if (!pluginDir) return
    if (!binaryCheck.running) {
      binaryCheck.command = ["/usr/bin/bash",
        pluginDir + "/scripts/playback-runtime.sh", "check"]
      binaryCheck.running = true
    }
    if (!socketProbe.running) {
      socketProbe.command = ["/usr/bin/bash",
        pluginDir + "/scripts/playback-runtime.sh", "socket"]
      socketProbe.running = true
    }
  }

  function installBundledBackendIfNeeded() {
    if (automaticSetupAttempted || setupBusy || !pluginDir || !binaryChecked) return
    if (playbackReady) return
    automaticSetupAttempted = true
    setupPlayback()
  }

  function setupPlayback() {
    if (setupBusy || !pluginDir) return
    lastError = ""
    setupBusy = true
    setupCommand.command = ["/usr/bin/bash", pluginDir + "/scripts/setup.sh"]
    setupCommand.running = true
  }

  function refreshStatus() {
    if (!pluginDir || statusCheck.running) return
    statusCheck.command = ["/usr/bin/bash",
      pluginDir + "/scripts/playback-runtime.sh", "status"]
    statusCheck.running = true
  }

  function start() {
    if (busy || !pluginDir) return
    if (!binaryAvailable) {
      lastError = "Playback support needs to be set up"
      return
    }
    lastError = ""
    busy = true
    startCommand.command = ["/usr/bin/bash",
      pluginDir + "/scripts/playback-runtime.sh", "start"]
    startCommand.running = true
  }

  function stop() {
    lastError = ""
    busy = true
    stopCommand.command = ["/usr/bin/bash",
      pluginDir + "/scripts/playback-runtime.sh", "stop"]
    stopCommand.running = true
  }

  Process {
    id: binaryCheck
    running: false
    onExited: function(code) {
      root.binaryAvailable = Number(code) === 0
      root.binaryChecked = true
    }
  }

  Process {
    id: socketProbe
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var path = text.trim().split("\n")[0]
        if (path !== "") root.socketPath = path
        root.socketChecked = true
      }
    }
    onExited: function(code) {
      if (Number(code) !== 0) root.socketChecked = true
    }
  }

  Process {
    id: statusCheck
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.serviceActive = text.trim() === "active"
    }
    onExited: function(code) {
      if (Number(code) !== 0) root.serviceActive = false
    }
  }

  Process {
    id: setupCommand
    running: false
    stderr: StdioCollector { }
    onExited: function(code) {
      root.setupBusy = false
      if (Number(code) === 0) {
        root.lastError = ""
        root.checkRequirements()
        root.setupSucceeded()
      } else {
        root.lastError = String(setupCommand.stderr.text || "Could not install playback support")
        root.setupFailed(root.lastError)
      }
    }
  }

  Process {
    id: startCommand
    running: false
    stderr: StdioCollector { }
    onExited: function(code) {
      root.busy = false
      if (Number(code) === 0) {
        root.serviceActive = true
        root.started()
      } else {
        root.lastError = String(startCommand.stderr.text || "Could not start playback")
      }
    }
  }

  Process {
    id: stopCommand
    running: false
    onExited: function() {
      root.busy = false
      root.serviceActive = false
      root.stopped()
    }
  }

  Timer {
    interval: 5000
    running: root.playbackReady
    repeat: true
    onTriggered: root.refreshStatus()
  }

  onPluginDirChanged: if (pluginDir) checkRequirements()
  onBinaryCheckedChanged: if (binaryChecked) installBundledBackendIfNeeded()
  // onPluginDirChanged never fires for the *initial* binding evaluation (only
  // for later changes) — since pluginDir is already resolved by the time this
  // component is created, we must also kick things off explicitly here.
  Component.onCompleted: if (pluginDir) checkRequirements()
}
