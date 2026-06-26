import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "../code/format.js" as Fmt

// Collapsible transfer queue with a small in-flight pool. Jobs are enqueued
// "pending" and started (ctrl.xfer spawns the detached worker) only as earlier
// transfers finish, so a big sync doesn't fan out into hundreds of processes.
// Active rows are polled via ctrl.xferStatus (in-flight guard avoids collisions).
ColumnLayout {
    id: queue
    property var ctrl
    property var fm
    property bool expanded: true
    property int maxInFlight: 3
    property int activeCount: 0
    spacing: 0

    ListModel { id: xferModel }

    // job: { id, dir, src, dst, recursive, sync, name, dstLabel }
    function enqueue(job) {
        xferModel.append({ xid: job.id, dir: job.dir, src: job.src, dst: job.dst,
                           recursive: job.recursive ? 1 : 0, sync: job.sync || "",
                           name: job.name, dstLabel: job.dstLabel,
                           state: "pending", pct: 0, rate: "", polling: false });
        expanded = true;
        pump();
    }
    function pump() {
        for (var i = 0; i < xferModel.count && queue.activeCount < queue.maxInFlight; i++) {
            if (xferModel.get(i).state === "pending") start(i);
        }
    }
    function start(idx) {
        var r = xferModel.get(idx);
        xferModel.setProperty(idx, "state", "active");
        queue.activeCount++;
        queue.ctrl.xfer(r.xid, r.dir, r.src, r.dst, r.recursive, r.sync, function (res) {
            if (res && res.ok) return;                 // worker spawned; Timer will track it
            var j = queue.indexOfId(r.xid);            // dispatch failed -> mark error, free the slot
            if (j >= 0) xferModel.setProperty(j, "state", "error");
            queue.activeCount = Math.max(0, queue.activeCount - 1);
            queue.pump();
        });
    }
    function indexOfId(id) {
        for (var i = 0; i < xferModel.count; i++) if (xferModel.get(i).xid === id) return i;
        return -1;
    }
    function clearDone() {
        for (var i = xferModel.count - 1; i >= 0; i--) {
            var s = xferModel.get(i).state;
            if (s !== "active" && s !== "pending") xferModel.remove(i);
        }
    }

    Timer {
        interval: 1000
        running: queue.activeCount > 0
        repeat: true
        onTriggered: {
            for (var i = 0; i < xferModel.count; i++) {
                var r = xferModel.get(i);
                if (r.state !== "active" || r.polling) continue;
                xferModel.setProperty(i, "polling", true);
                (function (xid) {
                    queue.ctrl.xferStatus(xid, function (s) {
                        var idx = queue.indexOfId(xid);
                        if (idx < 0) return;
                        xferModel.setProperty(idx, "polling", false);
                        if (!s || !s.ok) return;
                        if (s.last && s.last.pct !== undefined) {
                            xferModel.setProperty(idx, "pct", s.last.pct);
                            if (s.last.rate) xferModel.setProperty(idx, "rate", s.last.rate);
                        }
                        if (s.done) {
                            var term = s.terminal || {};
                            var st = term.event === "done" ? "done"
                                   : (term.code === "cancelled" ? "cancelled" : "error");
                            var dir = xferModel.get(idx).dir;
                            xferModel.setProperty(idx, "state", st);
                            if (st === "done") xferModel.setProperty(idx, "pct", 100);
                            queue.activeCount = Math.max(0, queue.activeCount - 1);
                            queue.ctrl.xferClear(xid, null);
                            if (st === "done" && queue.fm) queue.fm.onTransferDone(dir);
                            queue.pump();              // start the next pending transfer
                        }
                    });
                })(r.xid);
            }
        }
    }

    // ---- header ----
    RowLayout {
        Layout.fillWidth: true
        PlasmaComponents.ToolButton {
            icon.name: queue.expanded ? "go-down" : "go-up"
            flat: true; icon.width: Kirigami.Units.iconSizes.small
            onClicked: queue.expanded = !queue.expanded
        }
        PlasmaComponents.Label {
            text: queue.activeCount > 0 ? i18n("Transfers — %1 active", queue.activeCount)
                                        : i18n("Transfers")
            font.bold: true
        }
        Item { Layout.fillWidth: true }
        PlasmaComponents.ToolButton {
            text: i18n("Clear finished"); icon.name: "edit-clear-history"
            flat: true; visible: xferModel.count > queue.activeCount
            onClicked: queue.clearDone()
        }
    }

    // ---- rows ----
    PlasmaComponents.ScrollView {
        Layout.fillWidth: true
        Layout.preferredHeight: queue.expanded ? Math.min(xferModel.count, 4) * Kirigami.Units.gridUnit * 2.4 : 0
        visible: queue.expanded && xferModel.count > 0
        Behavior on Layout.preferredHeight { NumberAnimation { duration: Kirigami.Units.shortDuration } }
        ListView {
            model: xferModel
            clip: true
            delegate: RowLayout {
                width: ListView.view ? ListView.view.width : implicitWidth
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: model.dir === "up" ? "go-up" : "go-down"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    color: model.state === "error" ? Kirigami.Theme.negativeTextColor
                         : model.state === "done" ? Kirigami.Theme.positiveTextColor
                         : Kirigami.Theme.textColor
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    PlasmaComponents.Label { text: model.name; elide: Text.ElideMiddle; Layout.fillWidth: true }
                    RowLayout {
                        Layout.fillWidth: true
                        Rectangle {
                            Layout.fillWidth: true
                            height: Kirigami.Units.gridUnit * 0.4
                            radius: height / 2
                            visible: model.state === "active" && model.pct >= 0
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
                            Rectangle {
                                width: parent.width * Math.max(0, Math.min(1, model.pct / 100))
                                height: parent.height; radius: height / 2
                                color: Kirigami.Theme.highlightColor
                            }
                        }
                        PlasmaComponents.Label {
                            Layout.fillWidth: true
                            font: Kirigami.Theme.smallFont; opacity: 0.7; elide: Text.ElideRight
                            text: model.state === "pending" ? i18n("queued → %1", model.dstLabel)
                                : model.state === "done" ? i18n("done — %1", model.dstLabel)
                                : model.state === "error" ? i18n("failed")
                                : model.state === "cancelled" ? i18n("cancelled")
                                : model.pct < 0 ? i18n("transferring… → %1", model.dstLabel)
                                : i18n("%1%2 → %3", model.pct, "%", model.dstLabel)
                            visible: model.state !== "active" || model.pct < 0
                        }
                        PlasmaComponents.Label {
                            visible: model.state === "active" && model.rate !== ""
                            text: model.rate; font: Kirigami.Theme.smallFont; opacity: 0.7
                        }
                    }
                }
                PlasmaComponents.ToolButton {
                    visible: model.state === "active" || model.state === "pending"
                    icon.name: "dialog-cancel"; flat: true; icon.width: Kirigami.Units.iconSizes.small
                    onClicked: {
                        if (model.state === "pending") {
                            xferModel.setProperty(index, "state", "cancelled");
                        } else {
                            queue.ctrl.xferCancel(model.xid, null);
                        }
                    }
                }
            }
        }
    }
}
