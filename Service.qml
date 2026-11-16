import QtQuick
import Quickshell
import Quickshell.Io

// Feeds the built-in omarchy.agents panel's Z.ai and Kimi collectors with
// the desktop-app logins they cannot reach themselves. Omarchy now ships
// first-party omarchy-agent-usage-zai and -kimi collectors, and the panel
// runs them itself on its own cadence, so this service no longer publishes
// usage records. It only keeps their credentials in step:
//
//   - zai: the zcode app's Z.ai sign-in, bridged into
//     ~/.config/omarchy/agents/zai.json, which the built-in collector
//     reads first.
//   - kimi: the kimi-code app's sign-in, kept readable at the store path
//     the built-in collector scans (normally a symlink to the regional
//     credential file the current CLI writes).
//
// Each bridge is a single-file Python script under collectors/, run every
// 5 minutes and on shell start. Add an entry to `bridges` for another one.
Item {
  id: root

  // Injected by omarchy-shell (the service loader).
  property var shell: null

  readonly property int refreshIntervalMs: 300000

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agents/usage"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  readonly property var bridges: [
    {
      "name": "zai",
      "script": "zai-zcode-bridge"
    },
    {
      "name": "kimi",
      "script": "kimi-store-bridge"
    }
  ]

  function refresh() {
    for (var i = 0; i < bridgeRepeater.count; i++) {
      var item = bridgeRepeater.itemAt(i);
      if (item && item.refresh)
        item.refresh();
    }
  }

  // The state directory is normally created by omarchy-agent-usage-update on
  // the panel's first scan, but this service can beat the panel to it.
  Component.onCompleted: mkdirProcess.running = true

  Process {
    id: mkdirProcess
    command: ["mkdir", "-p", root.usageDir]
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("agent-usage-zcode: could not create " + root.usageDir);
      root.refresh();
    }
  }

  Timer {
    interval: root.refreshIntervalMs
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  Repeater {
    id: bridgeRepeater
    model: root.bridges

    delegate: Item {
      id: bridgeItem

      required property var modelData

      function refresh() {
        if (!bridge.running)
          bridge.running = true;
      }

      Process {
        id: bridge
        command: ["python3", root.pluginDir + "/collectors/" + bridgeItem.modelData.script]
        stderr: StdioCollector {
          waitForEnd: true
          onStreamFinished: if (text.trim() !== "")
            console.warn("agent-usage-zcode: " + bridgeItem.modelData.name + ": " + text.trim());
        }
        onExited: function(exitCode) {
          if (exitCode !== 0)
            console.warn("agent-usage-zcode: " + bridgeItem.modelData.name + " exited " + exitCode);
        }
      }
    }
  }
}
