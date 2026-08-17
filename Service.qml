import QtQuick
import Quickshell
import Quickshell.Io

// Feeds the built-in omarchy.agents panel usage records collected with each
// provider's own desktop login (zcode for Z.ai, kimi-cli for Kimi). The panel
// draws whatever lands in the usage state directory; this service only runs
// the bundled collectors on a cadence and publishes their output there,
// mirroring what omarchy-agent-usage-update does for the packaged collectors
// in OMARCHY_PATH/bin.
Item {
  id: root

  // Injected by omarchy-shell (the service loader).
  property var shell: null

  readonly property int refreshIntervalMs: 300000

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agents/usage"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  // One delegate per collector: runs the script and publishes its record as
  // <recordId>.json. Add an entry here to support another provider.
  readonly property var collectors: [
    {
      "recordId": "zai",
      "script": "omarchy-agent-usage-zcode"
    },
    {
      "recordId": "kimi",
      "script": "omarchy-agent-usage-kimi"
    }
  ]

  function refresh() {
    for (var i = 0; i < collectorRepeater.count; i++) {
      var item = collectorRepeater.itemAt(i);
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
    id: collectorRepeater
    model: root.collectors

    delegate: Item {
      id: collectorItem

      required property var modelData

      function refresh() {
        if (!collector.running)
          collector.running = true;
      }

      Process {
        id: collector
        command: ["python3", root.pluginDir + "/collectors/" + collectorItem.modelData.script]
        stdout: StdioCollector {
          waitForEnd: true
          onStreamFinished: collectorItem.publish(text)
        }
        onExited: function(exitCode) {
          if (exitCode !== 0)
            console.warn("agent-usage-zcode: " + collectorItem.modelData.script + " exited " + exitCode);
        }
      }

      function publish(output) {
        var record = null;
        try {
          record = JSON.parse(output);
        } catch (e) {
          record = null;
        }
        if (record && typeof record === "object" && record.id === collectorItem.modelData.recordId) {
          recordWriter.setText(output.trim() + "\n");
        } else {
          console.warn("agent-usage-zcode: invalid record from " + collectorItem.modelData.script);
        }
      }

      // atomicWrites so the panel's file watcher never sees a torn record.
      FileView {
        id: recordWriter
        path: root.usageDir + "/" + collectorItem.modelData.recordId + ".json"
        watchChanges: false
        atomicWrites: true
        printErrors: true
      }
    }
  }
}
