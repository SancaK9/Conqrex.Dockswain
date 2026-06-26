import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "../code/format.js" as Fmt

// One container row: status dot + name/ports + meta line, with a minimal action
// cluster on the right (logs + overflow menu). Everything else (start/stop,
// restart, exec, pin, remove) lives in the ⋯ menu. Actions dim until hover.
PlasmaComponents.ItemDelegate {
    id: del

    property string cid: model.cid
    property string cname: model.cname
    property string cimage: model.cimage
    property string cstate: model.cstate
    property string cstatus: model.cstatus
    property string cports: model.cports
    property string ccpu: model.ccpu
    property string cmem: model.cmem
    property bool cfav: model.cfav
    property bool showStats: false

    signal actionRequested(string act, string id, string name)
    signal execRequested(string id, string name)
    signal logsRequested(string id, string name)
    signal favToggleRequested(string name)

    hoverEnabled: true
    topPadding: Kirigami.Units.smallSpacing
    bottomPadding: Kirigami.Units.smallSpacing

    readonly property string cat: Fmt.stateCategory(cstate)
    readonly property bool running: cstate === "running"
    readonly property color dotColor:
          cat === "ok"   ? Kirigami.Theme.positiveTextColor
        : cat === "warn" ? Kirigami.Theme.neutralTextColor
        : cat === "bad"  ? Kirigami.Theme.negativeTextColor
        :                  Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.4)

    readonly property string metaLine: {
        var parts = [Fmt.shortImage(cimage)];
        if (cstatus) parts.push(cstatus);
        if (showStats && running && ccpu) parts.push("CPU " + ccpu + "  MEM " + cmem);
        return parts.join("   ·   ");
    }

    contentItem: RowLayout {
        spacing: Kirigami.Units.smallSpacing

        Rectangle {                                  // status dot
            Layout.preferredWidth: Math.round(Kirigami.Units.iconSizes.small * 0.55)
            Layout.preferredHeight: width
            Layout.leftMargin: Kirigami.Units.smallSpacing / 2
            Layout.alignment: Qt.AlignVCenter
            radius: width / 2
            color: del.dotColor
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    visible: del.cfav
                    source: "starred-symbolic"
                    color: Kirigami.Theme.neutralTextColor
                    Layout.preferredWidth: Math.round(Kirigami.Units.iconSizes.small * 0.8)
                    Layout.preferredHeight: Layout.preferredWidth
                }
                PlasmaComponents.Label {
                    text: del.cname
                    font.bold: true
                    font.family: "monospace"
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                PlasmaComponents.Label {
                    visible: del.cports !== ""
                    text: del.cports
                    opacity: 0.55
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    elide: Text.ElideRight
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 8
                }
            }
            PlasmaComponents.Label {
                text: del.metaLine
                opacity: 0.6
                font: Kirigami.Theme.smallFont
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        // minimal action cluster, dim until hovered
        RowLayout {
            spacing: 0
            Layout.alignment: Qt.AlignVCenter
            opacity: del.hovered ? 1.0 : 0.45
            Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }

            CompactBtn {
                icon.name: "viewlog"
                tip: i18n("Logs")
                onClicked: del.logsRequested(del.cid, del.cname)
            }
            CompactBtn {
                icon.name: "overflow-menu"
                tip: i18n("Actions")
                onClicked: moreMenu.popup()
            }
        }
    }

    // all per-container actions live here
    QQC2.Menu {
        id: moreMenu
        QQC2.MenuItem {
            text: del.running ? i18n("Stop") : i18n("Start")
            icon.name: del.running ? "media-playback-stop" : "media-playback-start"
            onTriggered: del.actionRequested(del.running ? "stop" : "start", del.cid, del.cname)
        }
        QQC2.MenuItem {
            text: i18n("Restart"); icon.name: "view-refresh"
            enabled: del.running
            onTriggered: del.actionRequested("restart", del.cid, del.cname)
        }
        QQC2.MenuItem {
            text: i18n("Exec shell"); icon.name: "utilities-terminal"
            enabled: del.running
            onTriggered: del.execRequested(del.cid, del.cname)
        }
        QQC2.MenuSeparator {}
        QQC2.MenuItem {
            text: del.cfav ? i18n("Unpin from top") : i18n("Pin to top")
            icon.name: del.cfav ? "starred-symbolic" : "non-starred-symbolic"
            onTriggered: del.favToggleRequested(del.cname)
        }
        QQC2.MenuSeparator {}
        QQC2.MenuItem {
            text: i18n("Remove…"); icon.name: "edit-delete"
            onTriggered: del.actionRequested("rm", del.cid, del.cname)
        }
    }

    // small flat icon button used in the action cluster
    component CompactBtn: PlasmaComponents.ToolButton {
        property string tip: ""
        display: PlasmaComponents.AbstractButton.IconOnly
        flat: true
        icon.width: Kirigami.Units.iconSizes.small
        icon.height: Kirigami.Units.iconSizes.small
        implicitWidth: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing * 2
        implicitHeight: implicitWidth
        PlasmaComponents.ToolTip { text: parent.tip }
    }
}
