import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import "../code/format.js" as Fmt

// One side of the file manager (local or remote): toolbar + breadcrumb + places
// strip + file list with drag-drop. Calls ctrl.{local,sftp}* for IO.
ColumnLayout {
    id: filePane

    property var ctrl
    property var fm
    property string side: "local"          // "local" | "remote"
    property string cwd: side === "local" ? (Plasmoid.configuration.defaultLocalDir || "") : "/"
    property string homePath: ""
    property bool loading: false
    property string errorText: ""
    property var classByName: ({})         // name -> compare class (set by FileManager)

    readonly property bool isLocal: side === "local"
    spacing: Kirigami.Units.smallSpacing / 2

    ListModel { id: dirModel }

    function listFn(path, cb) { isLocal ? ctrl.localList(path, cb) : ctrl.sftpList(path, cb); }

    function load() {
        if (!ctrl) return;
        loading = true; errorText = "";
        var showHidden = Plasmoid.configuration.showHiddenFiles;
        listFn(cwd, function (d) {
            loading = false;
            if (!d || !d.ok) {
                errorText = filePane.reasonText(d ? d.reason : "error");
                dirModel.clear();
                return;
            }
            filePane.cwd = d.path || filePane.cwd;
            if (d.home) filePane.homePath = d.home;
            var list = (d.entries || []).filter(function (e) {
                return showHidden || ("" + e.name).charAt(0) !== ".";
            });
            list.sort(function (a, b) {
                var ad = a.type === "dir" ? 0 : 1, bd = b.type === "dir" ? 0 : 1;
                if (ad !== bd) return ad - bd;
                return ("" + a.name).toLowerCase().localeCompare(("" + b.name).toLowerCase());
            });
            dirModel.clear();
            list.forEach(function (e) {
                dirModel.append({ fname: e.name, ftype: e.type, fsize: e.size || 0,
                                  fmtime: e.mtime || 0, fmode: e.mode || "", fsel: false });
            });
            if (filePane.fm) filePane.fm.recompare();
        });
    }
    function reasonText(r) {
        switch (r) {
        case "not_found":  return i18n("Folder not found.");
        case "permission": return i18n("Permission denied.");
        case "no_session": return i18n("No active server connection.");
        case "parse_error":return i18n("Could not read the folder.");
        default:           return i18n("Could not list (%1).", r);
        }
    }

    // first load: the remote pane resolves the SSH user's home and starts there
    function init() {
        if (isLocal || !ctrl) { load(); return; }
        ctrl.sftpHome(function (d) {
            if (d && d.ok && d.home) { filePane.homePath = d.home; filePane.cwd = d.home; }
            load();
        });
    }
    Component.onCompleted: filePane.init()

    function cd(path) { cwd = path; load(); }
    function goUp() { cd(Fmt.parentPath(cwd)); }
    function goHome() { cd(homePath || (isLocal ? "" : "/")); }
    function reload() { load(); }

    function selectOnly(idx) {
        for (var i = 0; i < dirModel.count; i++) dirModel.setProperty(i, "fsel", i === idx);
    }
    function clearSel() { for (var i = 0; i < dirModel.count; i++) dirModel.setProperty(i, "fsel", false); }

    function setClasses(m) { classByName = m; }
    function clearClasses() { classByName = ({}); }
    function entryMap() {                  // name -> entry, for the compare diff
        var m = {};
        for (var i = 0; i < dirModel.count; i++) { var e = dirModel.get(i); m[e.fname] = e; }
        return m;
    }

    function isFav(path) { return ctrl && ctrl.isFavPath(side, path); }
    function toggleFav(path) { if (ctrl) ctrl.toggleFavPath(side, path); }

    function doMkdir(path, cb) { isLocal ? ctrl.localMkdir(path, cb) : ctrl.sftpMkdir(path, cb); }
    function doRename(o, n, cb) { isLocal ? ctrl.localRename(o, n, cb) : ctrl.sftpRename(o, n, cb); }
    function doDelete(p, isDir, cb) { isLocal ? ctrl.localDelete(p, isDir, cb) : ctrl.sftpDelete(p, isDir, cb); }

    function promptNewFolder() { newFolderField.text = ""; newFolderDialog.open(); }
    function promptRename(path, name) { renameDialog.targetPath = path; renameField.text = name; renameDialog.open(); }
    function promptDelete(path, name, isDir) {
        if (Plasmoid.configuration.confirmDelete) {
            delDialog.targetPath = path; delDialog.targetName = name; delDialog.targetIsDir = isDir; delDialog.open();
        } else {
            doDelete(path, isDir, function (r) { if (r && r.ok) reload(); else filePane.errorText = filePane.opError(r); });
        }
    }
    function opError(r) {
        var x = r ? r.reason : "error";
        switch (x) {
        case "exists":    return i18n("Already exists.");
        case "not_empty": return i18n("Folder is not empty — delete its contents first, or use recursive delete.");
        case "permission":return i18n("Permission denied.");
        case "refused":   return i18n("Refused (protected path).");
        default:          return i18n("Operation failed (%1).", x);
        }
    }

    // ---- toolbar ----
    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing / 2
        PlasmaComponents.Label {
            text: filePane.isLocal ? i18n("Local") : i18n("Remote")
            font.bold: true
        }
        Item { Layout.fillWidth: true }
        PlasmaComponents.ToolButton {
            icon.name: "go-home"; flat: true; icon.width: Kirigami.Units.iconSizes.small
            onClicked: filePane.goHome(); PlasmaComponents.ToolTip { text: i18n("Home") }
        }
        PlasmaComponents.ToolButton {
            icon.name: "go-up"; flat: true; icon.width: Kirigami.Units.iconSizes.small
            onClicked: filePane.goUp(); PlasmaComponents.ToolTip { text: i18n("Up") }
        }
        PlasmaComponents.ToolButton {
            icon.name: "folder-new"; flat: true; icon.width: Kirigami.Units.iconSizes.small
            onClicked: filePane.promptNewFolder(); PlasmaComponents.ToolTip { text: i18n("New folder") }
        }
        PlasmaComponents.ToolButton {
            icon.name: filePane.isFav(filePane.cwd) ? "starred-symbolic" : "non-starred-symbolic"
            flat: true; icon.width: Kirigami.Units.iconSizes.small
            onClicked: filePane.toggleFav(filePane.cwd)
            PlasmaComponents.ToolTip { text: filePane.isFav(filePane.cwd) ? i18n("Unfavorite this folder") : i18n("Favorite this folder") }
        }
        PlasmaComponents.ToolButton {
            icon.name: "bookmarks"; flat: true; icon.width: Kirigami.Units.iconSizes.small
            onClicked: placesMenu.popup()
            PlasmaComponents.ToolTip { text: i18n("Go to a place or favorite folder") }
        }
        PlasmaComponents.ToolButton {
            icon.name: "view-refresh"; flat: true; icon.width: Kirigami.Units.iconSizes.small
            onClicked: filePane.reload(); PlasmaComponents.ToolTip { text: i18n("Refresh") }
        }
    }

    // Always-reachable places + favorites list (the side Places strip only fits
    // when a pane is wide; this dropdown works at any width / in dual-pane mode).
    QQC2.Menu {
        id: placesMenu
        QQC2.MenuItem {
            text: i18n("Home"); icon.name: "user-home"
            onTriggered: filePane.goHome()
        }
        QQC2.MenuItem {
            text: i18n("Root (/)"); icon.name: "folder-root"
            onTriggered: filePane.cd("/")
        }
        QQC2.MenuSeparator {}
        QQC2.MenuItem {
            enabled: false
            text: favInstantiator.count > 0 ? i18n("Favorites")
                                            : i18n("No favorites yet — ☆ a folder")
        }
        Instantiator {
            id: favInstantiator
            model: filePane.ctrl ? filePane.ctrl.favPathsFor(filePane.side) : []
            delegate: QQC2.MenuItem {
                required property string modelData
                text: Fmt.baseName(modelData) || modelData
                icon.name: "folder"
                onTriggered: filePane.cd(modelData)
            }
            onObjectAdded: (index, object) => placesMenu.addItem(object)
            onObjectRemoved: (index, object) => placesMenu.removeItem(object)
        }
    }

    BreadcrumbBar {
        Layout.fillWidth: true
        path: filePane.cwd
        onNavigate: (p) => filePane.cd(p)
    }
    Kirigami.Separator { Layout.fillWidth: true }

    // ---- places strip + file list ----
    RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.ScrollView {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 7
            Layout.fillHeight: true
            visible: filePane.width > Kirigami.Units.gridUnit * 22
            PlacesStrip {
                width: parent.width
                ctrl: filePane.ctrl; pane: filePane; side: filePane.side; homePath: filePane.homePath
            }
        }
        Kirigami.Separator { Layout.fillHeight: true; visible: filePane.width > Kirigami.Units.gridUnit * 22 }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            PlasmaComponents.ScrollView {
                anchors.fill: parent
                ListView {
                    id: listView
                    model: dirModel
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: FileRowDelegate { pane: filePane; fm: filePane.fm }
                }
            }

            // empty / error state
            PlasmaExtras.PlaceholderMessage {
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 2
                visible: dirModel.count === 0 && !filePane.loading
                text: filePane.errorText !== "" ? filePane.errorText : i18n("Empty folder")
                iconName: filePane.errorText !== "" ? "dialog-error" : "folder"
            }
            PlasmaComponents.BusyIndicator {
                anchors.centerIn: parent
                running: filePane.loading; visible: filePane.loading
            }

            // drop target
            DropArea {
                id: dropArea
                anchors.fill: parent
                onDropped: (drop) => {
                    if (drop.source && drop.source.dragSide !== undefined && drop.source.dragSide !== ""
                        && drop.source.dragSide !== filePane.side) {
                        var dir = filePane.side === "remote" ? "up" : "down";
                        filePane.fm.enqueueTransfer(dir, drop.source.dragPath, filePane.cwd, drop.source.dragIsDir);
                        drop.accept(Qt.CopyAction);
                    } else if (drop.hasUrls && filePane.side === "remote") {
                        drop.urls.forEach(function (u) {
                            var s = "" + u;
                            if (s.indexOf("file://") !== 0) return;
                            var lp = decodeURIComponent(s.replace(/^file:\/\//, ""));
                            var isDir = lp.charAt(lp.length - 1) === "/";
                            filePane.fm.enqueueTransfer("up", lp.replace(/\/+$/, ""), filePane.cwd, isDir);
                        });
                        drop.accept(Qt.CopyAction);
                    }
                }
            }
            Rectangle {                       // drop highlight
                anchors.fill: parent
                visible: dropArea.containsDrag
                color: "transparent"
                border.width: 2
                border.color: Kirigami.Theme.highlightColor
                radius: Kirigami.Units.smallSpacing
            }
        }
    }

    // ---- dialogs ----
    Kirigami.PromptDialog {
        id: newFolderDialog
        title: i18n("New folder")
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        QQC2.TextField {
            id: newFolderField
            placeholderText: i18n("folder name")
            onAccepted: newFolderDialog.accept()
        }
        onAccepted: {
            var nm = newFolderField.text.trim();
            if (!nm) return;
            filePane.doMkdir(Fmt.joinPath(filePane.cwd, nm), function (r) {
                if (r && r.ok) filePane.reload(); else filePane.errorText = filePane.opError(r);
            });
        }
    }
    Kirigami.PromptDialog {
        id: renameDialog
        property string targetPath: ""
        title: i18n("Rename")
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        QQC2.TextField { id: renameField; onAccepted: renameDialog.accept() }
        onAccepted: {
            var nm = renameField.text.trim();
            if (!nm) return;
            filePane.doRename(targetPath, Fmt.joinPath(Fmt.parentPath(targetPath), nm), function (r) {
                if (r && r.ok) filePane.reload(); else filePane.errorText = filePane.opError(r);
            });
        }
    }
    Kirigami.PromptDialog {
        id: delDialog
        property string targetPath: ""
        property string targetName: ""
        property bool targetIsDir: false
        title: i18n("Delete")
        subtitle: targetIsDir ? i18n("Delete the folder “%1” and everything in it?", targetName)
                              : i18n("Delete “%1”?", targetName)
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: {
            // a confirmed directory delete is recursive (the subtitle says so);
            // doDelete(targetIsDir) already sends the recursive flag for folders.
            filePane.doDelete(targetPath, targetIsDir, function (r) {
                if (r && r.ok) filePane.reload();
                else filePane.errorText = filePane.opError(r);
            });
        }
    }
}
