import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "../code/format.js" as Fmt

// Top-level dual-pane SFTP file manager. Side-by-side when wide,
// single pane + [Local|Remote] toggle when narrow. Owns compare/sync state and
// the transfer queue.
ColumnLayout {
    id: fm
    property var ctrl
    signal closeRequested()

    property bool compareMode: false
    property string syncFilter: Plasmoid.configuration.syncDefaultFilter || "all"
    property string visibleSide: "remote"
    readonly property bool dualPane: width > Kirigami.Units.gridUnit * 34
    property int xferSeq: 0
    property var lClass: ({})
    property var rClass: ({})

    spacing: Kirigami.Units.smallSpacing

    // panes self-load on completion (FilePane.init); reload them if the active
    // server changes under an open file manager, otherwise they go stale.
    Connections {
        target: fm.ctrl
        ignoreUnknownSignals: true
        function onActiveChanged() {
            if (!fm.ctrl || !fm.ctrl.active) return;
            localPane.reload();
            remotePane.init();
        }
    }

    // ---- transfers ----
    function enqueueTransfer(dir, src, dstDir, isDir) {
        if (!src || !dstDir) return;
        var name = Fmt.baseName(src);
        var dst = Fmt.joinPath(dstDir, name);
        var id = "x" + (fm.xferSeq++) + "_" + Qt.formatDateTime(new Date(), "HHmmsszzz");
        id = id.replace(/[^A-Za-z0-9_-]/g, "");
        queue.enqueue({ id: id, dir: dir, src: src, dst: dst, recursive: isDir ? 1 : 0,
                        sync: compareMode ? syncFilterToMode() : "",
                        name: name, dstLabel: Fmt.baseName(dstDir) || dstDir });
    }
    function syncFilterToMode() {
        switch (syncFilter) {
        case "newer": return "newer";
        case "size":  return "size";
        case "new":   return "new-only";
        default:      return "";
        }
    }
    function enqueueFromRow(side, path, isDir) {
        var dir = side === "local" ? "up" : "down";
        var dstDir = side === "local" ? remotePane.cwd : localPane.cwd;
        enqueueTransfer(dir, path, dstDir, isDir);
    }
    function onTransferDone(dir) {
        if (dir === "up") remotePane.reload(); else localPane.reload();
    }

    // ---- compare / sync ----
    function classify(l, r) {
        if (l && !r) return "local-only";
        if (!l && r) return "remote-only";
        if (l.ftype === "dir" || r.ftype === "dir") return "same";
        if ((l.fsize || 0) !== (r.fsize || 0)) return "size-differs";
        if ((l.fmtime || 0) > (r.fmtime || 0)) return "newer-local";
        if ((l.fmtime || 0) < (r.fmtime || 0)) return "newer-remote";
        return "same";
    }
    function recompare() {
        if (!compareMode) { localPane.clearClasses(); remotePane.clearClasses(); lClass = ({}); rClass = ({}); return; }
        var L = localPane.entryMap(), R = remotePane.entryMap();
        var names = {}; var k;
        for (k in L) names[k] = 1;
        for (k in R) names[k] = 1;
        var lc = {}, rc = {};
        for (var n in names) {
            var cls = classify(L[n], R[n]);
            if (cls === "same") continue;
            if (L[n]) lc[n] = cls;
            if (R[n]) rc[n] = cls;
        }
        lClass = lc; rClass = rc;
        localPane.setClasses(lc); remotePane.setClasses(rc);
    }
    onCompareModeChanged: recompare()
    // a row "matches" the current filter for a given direction
    function rowMatches(cls, dir) {
        if (!cls) return false;
        var relevant = dir === "up"
            ? (cls === "local-only" || cls === "newer-local" || cls === "size-differs")
            : (cls === "remote-only" || cls === "newer-remote" || cls === "size-differs");
        if (!relevant) return false;
        switch (syncFilter) {
        case "new":   return cls === "local-only" || cls === "remote-only";
        case "size":  return cls === "size-differs";
        case "newer": return cls === "newer-local" || cls === "newer-remote";
        default:      return true;       // all differing
        }
    }
    function transferMatching(dir) {
        var src = dir === "up" ? localPane : remotePane;
        var cmap = dir === "up" ? lClass : rClass;
        var dstDir = dir === "up" ? remotePane.cwd : localPane.cwd;
        var map = src.entryMap();
        for (var name in map) {
            if (rowMatches(cmap[name], dir))
                enqueueTransfer(dir, Fmt.joinPath(src.cwd, name), dstDir, map[name].ftype === "dir");
        }
    }

    // ==================== header ====================
    RowLayout {
        Layout.fillWidth: true
        Kirigami.Icon {
            source: "folder-remote"
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }
        Kirigami.Heading { level: 5; text: i18n("Files") }
        PlasmaComponents.Label {
            Layout.fillWidth: true
            opacity: 0.7; elide: Text.ElideRight; font: Kirigami.Theme.smallFont
            text: fm.ctrl && fm.ctrl.active ? (fm.ctrl.active.label || fm.ctrl.targetStr()) : ""
        }
        PlasmaComponents.ToolButton {
            text: i18n("Compare"); icon.name: "view-split-left-right"
            checkable: true; checked: fm.compareMode
            onToggled: fm.compareMode = checked
            display: PlasmaComponents.AbstractButton.IconOnly
            PlasmaComponents.ToolTip { text: i18n("Compare the two folders and highlight differences") }
        }
        PlasmaComponents.ToolButton {
            icon.name: "view-refresh"
            onClicked: { localPane.reload(); remotePane.reload(); }
            PlasmaComponents.ToolTip { text: i18n("Refresh both") }
        }
        PlasmaComponents.ToolButton {
            id: fmPinBtn
            checkable: true
            checked: fm.ctrl && fm.ctrl.pinned
            icon.name: (fm.ctrl && fm.ctrl.pinned) ? "window-unpin" : "window-pin"
            display: PlasmaComponents.AbstractButton.IconOnly
            onToggled: if (fm.ctrl) fm.ctrl.pinned = checked
            PlasmaComponents.ToolTip {
                text: fmPinBtn.checked ? i18n("Pinned — stays open when it loses focus. Click to unpin.")
                                       : i18n("Pin open — keep this open so you can drag files in from Dolphin")
            }
        }
        PlasmaComponents.ToolButton {
            icon.name: "dialog-close"; onClicked: fm.closeRequested()
            PlasmaComponents.ToolTip { text: i18n("Close") }
        }
    }
    Kirigami.Separator { Layout.fillWidth: true }

    SyncBar { Layout.fillWidth: true; fm: fm; visible: fm.compareMode }
    Kirigami.Separator { Layout.fillWidth: true; visible: fm.compareMode }

    // segmented Local/Remote toggle (narrow mode only)
    RowLayout {
        Layout.fillWidth: true
        visible: !fm.dualPane
        spacing: 0
        PlasmaComponents.TabButton {
            text: i18n("Local"); checkable: true; checked: fm.visibleSide === "local"
            Layout.fillWidth: true; onClicked: fm.visibleSide = "local"
        }
        PlasmaComponents.TabButton {
            text: i18n("Remote"); checkable: true; checked: fm.visibleSide === "remote"
            Layout.fillWidth: true; onClicked: fm.visibleSide = "remote"
        }
    }

    // ==================== panes ====================
    RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Kirigami.Units.smallSpacing

        FilePane {
            id: localPane
            ctrl: fm.ctrl; fm: fm; side: "local"
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: fm.dualPane || fm.visibleSide === "local"
        }
        Kirigami.Separator { Layout.fillHeight: true; visible: fm.dualPane }
        FilePane {
            id: remotePane
            ctrl: fm.ctrl; fm: fm; side: "remote"
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: fm.dualPane || fm.visibleSide === "remote"
        }
    }

    Kirigami.Separator { Layout.fillWidth: true }

    // ==================== transfer queue ====================
    TransferQueue {
        id: queue
        Layout.fillWidth: true
        ctrl: fm.ctrl; fm: fm
    }
}
