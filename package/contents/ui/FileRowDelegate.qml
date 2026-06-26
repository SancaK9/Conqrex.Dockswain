import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "../code/format.js" as Fmt

// One file/dir row in a FilePane's list. Reads model roles (fname/ftype/fsize/
// fmtime/fmode/fsel) and drives actions through its owning `pane`.
PlasmaComponents.ItemDelegate {
    id: del

    property var pane                 // the owning FilePane
    property var fm                   // the FileManager (for transfers)
    readonly property string fname: model.fname
    readonly property string ftype: model.ftype
    readonly property bool isDir: model.ftype === "dir"
    readonly property bool isLink: model.ftype === "link"
    readonly property string fpath: Fmt.joinPath(pane.cwd, fname)
    readonly property string cls: pane.classByName[fname] || ""

    width: ListView.view ? ListView.view.width : implicitWidth
    hoverEnabled: true
    highlighted: model.fsel === true
    topPadding: Kirigami.Units.smallSpacing / 2
    bottomPadding: Kirigami.Units.smallSpacing / 2

    onClicked: del.pane.selectOnly(del.index)

    // internal drag payload (pane<->pane). Drag.Internal keeps drop.source alive
    // on the receiving DropArea. external-in from Dolphin goes through drop.urls.
    property string dragSide: pane ? pane.side : ""
    property string dragPath: fpath
    property bool dragIsDir: isDir
    Drag.active: dragHandler.active
    Drag.dragType: Drag.Internal
    Drag.hotSpot: Qt.point(Kirigami.Units.iconSizes.smallMedium / 2, height / 2)
    DragHandler {
        id: dragHandler
        acceptedDevices: PointerDevice.Mouse
        target: null
        onActiveChanged: if (active) del.grabToImage(function (r) { del.Drag.imageSource = r.url; })
    }

    // faint row tint by compare class
    background: Rectangle {
        color: {
            if (del.highlighted) return Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.25);
            if (del.hovered) return Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.06);
            var c = del.classColor;
            return c ? Qt.rgba(c.r, c.g, c.b, 0.12) : "transparent";
        }
    }
    readonly property var classColor: {
        switch (cls) {
        case "local-only":
        case "remote-only":  return Kirigami.Theme.positiveTextColor;
        case "size-differs":
        case "newer-local":
        case "newer-remote": return Kirigami.Theme.neutralTextColor;
        default:             return null;
        }
    }

    contentItem: RowLayout {
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            source: Fmt.extIcon(del.fname, del.isDir)
            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            opacity: del.isLink ? 0.7 : 1.0
        }
        // link emblem
        Kirigami.Icon {
            source: "emblem-symbolic-link"
            visible: del.isLink
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            PlasmaComponents.Label {
                text: del.fname
                Layout.fillWidth: true
                elide: Text.ElideMiddle
                font.bold: del.isDir
            }
        }

        // compare class glyph
        PlasmaComponents.Label {
            visible: del.cls !== ""
            text: del.cls === "local-only" || del.cls === "remote-only" ? "○"
                : del.cls === "size-differs" ? "≠"
                : del.cls === "newer-local" ? "▲"
                : del.cls === "newer-remote" ? "▼" : ""
            color: del.classColor || Kirigami.Theme.textColor
            font: Kirigami.Theme.smallFont
        }

        PlasmaComponents.Label {
            visible: !del.isDir
            text: Fmt.fmtBytes(model.fsize)
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: Kirigami.Units.gridUnit * 3.2
        }
        PlasmaComponents.Label {
            text: Fmt.fmtMtime(model.fmtime, Qt)
            opacity: 0.6
            font: Kirigami.Theme.smallFont
            Layout.preferredWidth: Kirigami.Units.gridUnit * 6
            visible: parent.width > Kirigami.Units.gridUnit * 16
        }

        // hover action cluster
        RowLayout {
            spacing: 0
            opacity: del.hovered ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }

            PlasmaComponents.ToolButton {
                icon.name: del.pane.side === "local" ? "go-up" : "go-down"
                icon.width: Kirigami.Units.iconSizes.small
                flat: true
                onClicked: del.fm.enqueueFromRow(del.pane.side, del.fpath, del.isDir)
                PlasmaComponents.ToolTip { text: del.pane.side === "local" ? i18n("Upload to remote") : i18n("Download to local") }
            }
            PlasmaComponents.ToolButton {
                icon.name: "overflow-menu"
                icon.width: Kirigami.Units.iconSizes.small
                flat: true
                onClicked: rowMenu.popup()
            }
        }
    }

    TapHandler {
        acceptedButtons: Qt.LeftButton
        onDoubleTapped: if (del.isDir) del.pane.cd(del.fpath)
    }
    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: rowMenu.popup()
    }

    QQC2.Menu {
        id: rowMenu
        QQC2.MenuItem {
            text: del.isDir ? i18n("Open") : (del.pane.side === "local" ? i18n("Upload to remote") : i18n("Download to local"))
            onTriggered: del.isDir ? del.pane.cd(del.fpath) : del.fm.enqueueFromRow(del.pane.side, del.fpath, del.isDir)
        }
        QQC2.MenuItem {
            text: del.pane.side === "local" ? i18n("Upload to remote") : i18n("Download to local")
            visible: del.isDir
            onTriggered: del.fm.enqueueFromRow(del.pane.side, del.fpath, del.isDir)
        }
        QQC2.MenuSeparator {}
        QQC2.MenuItem {
            text: del.pane.isFav(del.fpath) ? i18n("Remove from favorites") : i18n("Add to favorites")
            onTriggered: del.pane.toggleFav(del.fpath)
        }
        QQC2.MenuItem {
            text: i18n("Rename…")
            onTriggered: del.pane.promptRename(del.fpath, del.fname)
        }
        QQC2.MenuItem {
            text: i18n("Delete…")
            onTriggered: del.pane.promptDelete(del.fpath, del.fname, del.isDir)
        }
    }
}
