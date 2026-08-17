import QtQuick
import Quickshell
import Quickshell.Io

// Feeds the built-in omarchy.agents panel a Z.ai record collected with the
// zcode app's sign-in. The panel draws whatever lands in the usage state
// directory; this service only runs the bundled collector on a cadence and
// publishes its output there, mirroring what omarchy-agent-usage-update does
// for the packaged collectors in OMARCHY_PATH/bin.
Item {
  id: root

  // Injected by omarchy-shell (the service loader).
  property var shell: null

  readonly property int refreshIntervalMs: 300000

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agents/usage"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  function refresh() {
    if (!zcodeCollector.running)
      zcodeCollector.running = true;
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

  Process {
    id: zcodeCollector
    command: ["python3", root.pluginDir + "/collectors/omarchy-agent-usage-zcode"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publish(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("agent-usage-zcode: collector exited " + exitCode);
    }
  }

  function publish(output) {
    var record = null;
    try {
      record = JSON.parse(output);
    } catch (e) {
      record = null;
    }
    if (record && typeof record === "object" && record.id === "zai") {
      zaiWriter.setText(output.trim() + "\n");
    } else {
      console.warn("agent-usage-zcode: invalid record from collector");
    }
  }

  // atomicWrites so the panel's file watcher never sees a torn record.
  FileView {
    id: zaiWriter
    path: root.usageDir + "/zai.json"
    watchChanges: false
    atomicWrites: true
    printErrors: true
  }
}
