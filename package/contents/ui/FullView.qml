import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import "../code/format.js" as Fmt

Item {
    id: fullView

    property var ctrl

    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.minimumHeight: Kirigami.Units.gridUnit * 16
    // grow the popup while the file manager is open so the dual pane has room
    Layout.preferredWidth: Kirigami.Units.gridUnit * (fmOverlay.visible ? Plasmoid.configuration.fmPopupWidth : 24)
    Layout.preferredHeight: Kirigami.Units.gridUnit * (fmOverlay.visible ? Plasmoid.configuration.fmPopupHeight : 28)

    readonly property bool ready: ctrl.active && ctrl.reachable && ctrl.dockerOk
    readonly property bool hasList: ready && ctrl.containerModel.count > 0

    property string logsId: ""
    property string logsName: ""
    property string filePath: ""
    property var nginxData: null
    property string nginxResult: ""
    property var nginxCertsData: []
    property bool certbotAvailable: true
    property string siteFormResult: ""
    property bool siteCreated: false
    property string lastCreatedDomains: ""
    property string sslResult: ""
    property bool sslRunning: false
    property var diskData: null
    property string diskResult: ""

    function reasonText(r) {
        switch (r) {
        case "no_server":        return i18n("No server configured. Add one in settings, or import from Remmina.");
        case "no_password":      return i18n("This server uses password auth but no password is saved. Open Settings → Servers → Set password.");
        case "ssh_auth":         return i18n("SSH authentication failed — wrong password/key, or for key auth load it with `ssh-add`. Check the server in Settings.");
        case "timeout":          return i18n("Connection timed out — the host is unreachable.");
        case "refused":          return i18n("Connection refused — is sshd running on that port?");
        case "dns":              return i18n("Host name could not be resolved.");
        case "unreachable":      return i18n("No route to host / network unreachable.");
        case "docker_permission":return i18n("Permission denied on the Docker socket. Add the remote user to the `docker` group, or set the docker command to `sudo docker` in settings.");
        case "docker_down":      return i18n("The Docker daemon is not running on the server.");
        case "docker_missing":   return i18n("`docker` was not found on the server.");
        default:                 return i18n("Could not connect (%1).", r);
        }
    }

    // ---- logs ----
    function showLogs(id, name) {
        logsId = id; logsName = name;
        logsTitle.text = name;
        logsArea.text = i18n("Loading logs…");
        logsOverlay.visible = true;
        refreshLogs();
    }
    function refreshLogs() {
        if (!logsOverlay.visible) return;
        ctrl.fetchLogs(logsId, function (t) { logScroll.setText(t || i18n("(empty)")); });
    }

    // ---- file viewer ----
    function showFile(path) {
        filePath = path;
        fileTitle.text = path;
        fileArea.text = i18n("Loading…");
        fileOverlay.visible = true;
        ctrl.readFile(path, function (t) { fileArea.text = t; });
    }

    // ---- nginx ----
    function openNginx() { nginxResult = ""; nginxOverlay.visible = true; loadNginx(); loadCerts(); }
    function loadNginx() {
        ctrl.nginxInfo(function (d) {
            fullView.nginxData = d;
            nginxModel.clear();
            if (d && d.ok) (d.sites || []).forEach(function (s) {
                nginxModel.append({ sname: s.name, senabled: s.enabled,
                                    ssl: !!s.ssl, domains: s.domains || "" });
            });
        });
    }
    function loadCerts() {
        ctrl.nginxCerts(function (d) {
            fullView.certbotAvailable = !(d && d.ok) ? true : (d.certbot !== false);
            fullView.nginxCertsData = (d && d.ok && d.certs) ? d.certs : [];
        });
    }
    function nginxFilePath(name, enabled) {
        var base = nginxData ? nginxData.base : "/etc/nginx";
        if (nginxData && nginxData.style === "confd")
            return base + "/conf.d/" + (enabled ? name : name + ".disabled");
        return base + "/sites-available/" + name;
    }

    // ---- create site form ----
    function openSiteForm() {
        siteName.text = "";
        siteDomains.text = "";
        siteTypeStatic.checked = false;
        siteTypeProxy.checked = true;
        siteTarget.text = "";
        siteEnable.checked = true;
        siteMkroot.checked = true;
        siteFormResult = "";
        siteCreated = false;
        lastCreatedDomains = "";
        siteFormOverlay.visible = true;
    }
    function doCreateSite() {
        var domains = siteDomains.text.trim().replace(/\s+/g, " ");
        var name = siteName.text.trim() || (domains ? domains.split(" ")[0] : "");
        var type = siteTypeProxy.checked ? "proxy" : "static";
        var target = siteTarget.text.trim();
        if (!domains) { siteFormResult = i18n("Enter at least one domain."); return; }
        if (!/^[A-Za-z0-9_.*\- ]+$/.test(domains)) {
            siteFormResult = i18n("Domains may only contain letters, digits, dot, hyphen and *."); return; }
        if (!target) { siteFormResult = type === "proxy"
                ? i18n("Enter a proxy target, e.g. http://127.0.0.1:3000")
                : i18n("Enter a root directory, e.g. /var/www/site"); return; }
        // block stray nginx directives from the generated config
        if (type === "proxy") {
            if (!/^https?:\/\/[^\s;{}]+$/.test(target)) {
                siteFormResult = i18n("Proxy target must be a URL like http://127.0.0.1:3000"); return; }
        } else {
            if (target.charAt(0) !== "/" || /[\s;{}]/.test(target)) {
                siteFormResult = i18n("Root must be an absolute path like /var/www/site"); return; }
        }
        siteFormResult = i18n("Creating…");
        ctrl.nginxCreate(name, domains, type, target, siteEnable.checked,
                         type === "static" && siteMkroot.checked, function (r) {
            if (r && r.ok) {
                siteCreated = true;
                lastCreatedDomains = domains;
                siteFormResult = siteEnable.checked
                    ? i18n("Created %1 — run Test, then Reload to apply.", r.path || name)
                    : i18n("Created %1 (disabled) — enable it from the list and Reload before getting SSL.", r.path || name);
                fullView.loadNginx();
            } else {
                siteCreated = false;
                siteFormResult = i18n("Could not create site: %1",
                    r ? fullView.nginxErr(r.reason) : "error");
            }
        });
    }
    function nginxErr(reason) {
        switch (reason) {
        case "exists":        return i18n("a config with that name already exists");
        case "no_domain":     return i18n("no domain given");
        case "no_target":     return i18n("no target given");
        case "write_failed":  return i18n("could not write the file (permission?)");
        case "bad_name":      return i18n("invalid name");
        default:              return reason || "error";
        }
    }

    // ---- SSL / certbot form ----
    function openSslForm(domains) {
        // drop catch-all '_', turn wildcard '*.example.com' into its apex, de-dup.
        // certbot --nginx (HTTP-01) can't do those, so don't prefill an invalid value
        var seen = {}, clean = [];
        ("" + (domains || "")).trim().split(/\s+/).forEach(function (t) {
            t = t.replace(/^\*\./, "");
            if (t && t !== "_" && !seen[t]) { seen[t] = 1; clean.push(t); }
        });
        sslDomains.text = clean.join(" ");
        sslRedirect.checked = true;
        sslResult = "";
        sslRunning = false;
        sslFormOverlay.visible = true;
    }
    function doRunCertbot() {
        var domains = sslDomains.text.trim().replace(/\s+/g, " ");
        if (!domains) { sslResult = i18n("Enter at least one domain."); return; }
        if (!/^[A-Za-z0-9_.\- ]+$/.test(domains)) {
            sslResult = i18n("Domains may only contain letters, digits, dot and hyphen (no wildcards for HTTP validation)."); return; }
        var toks = domains.split(" ");
        for (var i = 0; i < toks.length; i++) {
            if (toks[i] === "_" || toks[i].indexOf(".") < 0) {
                sslResult = i18n("Each domain must be a fully-qualified name like example.com."); return; }
        }
        sslRunning = true;
        sslResult = i18n("Requesting certificate from Let's Encrypt… this can take up to a minute.");
        ctrl.nginxCertbot(domains, sslRedirect.checked, function (r) {
            sslRunning = false;
            if (r && r.ok) {
                sslResult = (r.output || "") + "\n" + i18n("✓ Certificate installed — certbot reloaded nginx.");
                fullView.loadNginx(); fullView.loadCerts();
            } else if (r && r.reason === "no_certbot") {
                sslResult = i18n("certbot is not installed on the server.\nInstall it, e.g.:  apt install certbot python3-certbot-nginx");
            } else {
                sslResult = (r && r.output ? r.output + "\n" : "") + i18n("✗ certbot failed. Check that the domain's DNS points here and port 80 is reachable.");
            }
        });
    }

    // ---- disk usage + cleanup ----
    function openDisk() {
        diskData = null;
        diskResult = i18n("Loading…");
        diskOverlay.visible = true;
        loadDisk();
    }
    function loadDisk() {
        ctrl.refreshDisk(function (d) {
            if (d && d.ok) { fullView.diskData = d; fullView.diskResult = ""; }
            else { fullView.diskData = null;
                   fullView.diskResult = i18n("Could not read disk usage (%1)", d ? d.reason : "error"); }
        });
    }
    function pruneKeyFor(type) {
        return type === "Build Cache" ? "builder"
             : type === "Images" ? "images"
             : type === "Containers" ? "containers" : "";
    }

    function confirm(msg, action) {
        confirmDialog.message = msg;
        confirmDialog.pendingAction = action;
        confirmDialog.open();
    }

    // ==================== main content ====================
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        // ---- header row 1 ----
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Image {
                source: ctrl.iconSource
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                sourceSize.width: 128; sourceSize.height: 128
                fillMode: Image.PreserveAspectFit; smooth: true
            }
            // --- tab strip: one tab per open server, each a live connection ---
            ListView {
                id: tabStrip
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
                orientation: ListView.Horizontal
                clip: true
                spacing: Kirigami.Units.smallSpacing / 2
                boundsBehavior: Flickable.StopAtBounds
                model: ctrl.openTabs

                function srvLabel(s) {
                    return s ? (s.label && s.label.length ? s.label
                               : ((s.user ? s.user + "@" : "") + s.host)) : i18n("?");
                }

                delegate: Rectangle {
                    id: tabChip
                    property var srv: ctrl.servers[modelData] || null
                    property bool isActive: index === ctrl.activeTab
                    height: tabStrip.height
                    width: tabContent.implicitWidth + Kirigami.Units.smallSpacing * 2
                    radius: Kirigami.Units.smallSpacing
                    color: isActive ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.22)
                         : tabHover.hovered ? Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
                         : "transparent"
                    border.width: isActive ? 1 : 0
                    border.color: Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.5)

                    HoverHandler { id: tabHover }
                    TapHandler { onTapped: ctrl.setActiveTab(index) }

                    RowLayout {
                        id: tabContent
                        anchors.centerIn: parent
                        spacing: Kirigami.Units.smallSpacing / 2
                        PlasmaComponents.Label {
                            text: tabStrip.srvLabel(tabChip.srv)
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.bold: tabChip.isActive
                            elide: Text.ElideRight
                            Layout.maximumWidth: Kirigami.Units.gridUnit * 9
                        }
                        PlasmaComponents.ToolButton {
                            visible: tabChip.isActive || tabHover.hovered
                            icon.name: "tab-close"
                            icon.width: Math.round(Kirigami.Units.iconSizes.small * 0.8)
                            icon.height: Math.round(Kirigami.Units.iconSizes.small * 0.8)
                            implicitWidth: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
                            implicitHeight: implicitWidth
                            flat: true
                            onClicked: ctrl.closeTab(index)
                            PlasmaComponents.ToolTip { text: i18n("Close tab") }
                        }
                    }
                }
            }
            // + open another server in a new tab
            PlasmaComponents.ToolButton {
                icon.name: "list-add"
                enabled: ctrl.servers.length > 0
                onClicked: addTabMenu.popup()
                PlasmaComponents.ToolTip { text: i18n("Open a server in a new tab") }
                QQC2.Menu {
                    id: addTabMenu
                    Instantiator {
                        model: ctrl.servers.length
                        delegate: QQC2.MenuItem {
                            required property int index
                            text: tabStrip.srvLabel(ctrl.servers[index])
                            icon.name: ctrl.openTabs.indexOf(index) >= 0 ? "checkmark" : "network-server"
                            onTriggered: ctrl.openServerTab(index)
                        }
                        onObjectAdded: (i, obj) => addTabMenu.insertItem(i, obj)
                        onObjectRemoved: (i, obj) => addTabMenu.removeItem(obj)
                    }
                }
            }
            Rectangle {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.6
                Layout.preferredHeight: width
                radius: width / 2
                color: !ctrl.active ? Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.4)
                     : !ctrl.reachable ? Kirigami.Theme.negativeTextColor
                     : !ctrl.dockerOk ? Kirigami.Theme.neutralTextColor
                     : Kirigami.Theme.positiveTextColor
            }
            PlasmaComponents.ToolButton {
                icon.name: "utilities-terminal"
                enabled: ctrl.active !== null
                onClicked: ctrl.openShell()
                PlasmaComponents.ToolTip { text: i18n("Open Konsole → SSH") }
            }
            PlasmaComponents.ToolButton {
                icon.name: "view-refresh"
                enabled: ctrl.active !== null
                onClicked: ctrl.refresh()
                PlasmaComponents.ToolTip { text: i18n("Refresh") }
            }
            PlasmaComponents.ToolButton {
                id: pinBtn
                checkable: true
                checked: ctrl.pinned
                icon.name: ctrl.pinned ? "window-unpin" : "window-pin"
                display: PlasmaComponents.AbstractButton.IconOnly
                onToggled: ctrl.pinned = checked
                PlasmaComponents.ToolTip {
                    text: pinBtn.checked ? i18n("Pinned — stays open when it loses focus. Click to unpin.")
                                         : i18n("Pin open — keep the popup open (e.g. to drag files in from Dolphin)")
                }
            }
        }

        // ---- header row 2: filter + nginx ----
        RowLayout {
            Layout.fillWidth: true
            visible: fullView.ready
            spacing: Kirigami.Units.smallSpacing

            Kirigami.SearchField {
                Layout.fillWidth: true
                placeholderText: i18n("Filter containers…")
                onTextChanged: ctrl.searchText = text
            }
            PlasmaComponents.ToolButton {
                id: hideExitedBtn
                checkable: true
                checked: ctrl.hideExited
                icon.name: "view-filter"
                text: i18n("Running")
                display: PlasmaComponents.AbstractButton.IconOnly
                onToggled: ctrl.hideExited = checked
                PlasmaComponents.ToolTip { text: hideExitedBtn.checked ? i18n("Showing running only — click to show all") : i18n("Showing all — click to hide exited") }
            }
            PlasmaComponents.ToolButton {
                id: groupNetBtn
                checkable: true
                checked: ctrl.groupByNetwork
                icon.name: "network-workgroup"
                display: PlasmaComponents.AbstractButton.IconOnly
                onToggled: ctrl.groupByNetwork = checked
                PlasmaComponents.ToolTip { text: groupNetBtn.checked ? i18n("Grouped by network — click for a flat list") : i18n("Group by docker network") }
            }
            PlasmaComponents.ToolButton {
                icon.name: "drive-harddisk"
                onClicked: fullView.openDisk()
                PlasmaComponents.ToolTip { text: i18n("Disk usage & cleanup") }
            }
            PlasmaComponents.ToolButton {
                icon.name: "globe"
                onClicked: fullView.openNginx()
                PlasmaComponents.ToolTip { text: i18n("Nginx configs") }
            }
            PlasmaComponents.ToolButton {
                icon.name: "system-file-manager"
                onClicked: fmOverlay.visible = true
                PlasmaComponents.ToolTip { text: i18n("File manager (SFTP)") }
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---- container list ----
        // Changing a populated ListView's section.property live crashes QtQuick
        // (SIGSEGV in libQt6Quick). So grouping is applied by REBUILDING the view
        // through this Loader: destroy it, re-sort the model while nothing is
        // attached, then build a fresh view with section.property set exactly once
        // at construction.
        Loader {
            id: listLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: fullView.hasList
            active: false
            property bool groupedSnapshot: false
            sourceComponent: listComponent

            function rebuild() {
                active = false;                       // tear the old view down first
                groupedSnapshot = ctrl.groupByNetwork;
                ctrl.applyFilter();                   // re-sort the model with no view attached
                active = true;                        // fresh view; section set at construction
            }
            Component.onCompleted: rebuild()
            Connections {
                target: ctrl
                function onGroupByNetworkChanged() { listLoader.rebuild(); }
                function onActiveTabChanged() { listLoader.rebuild(); }   // fresh view per session
            }
        }

        Component {
            id: listComponent
            PlasmaComponents.ScrollView {
                ListView {
                    model: ctrl.containerModel
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    highlight: PlasmaExtras.Highlight {}
                    highlightMoveDuration: Kirigami.Units.shortDuration

                    section.criteria: ViewSection.FullString
                    // set ONCE here, never re-bound (mutating it live crashes QtQuick)
                    Component.onCompleted: section.property = listLoader.groupedSnapshot ? "cnet1" : ""

                    // safe band, close to the v0.4.0 header that worked:
                    // tinted background + accent bar + uppercase accent label + count.
                    section.delegate: Rectangle {
                        width: ListView.view ? ListView.view.width : 0
                        height: Math.round(Kirigami.Units.gridUnit * 1.5)
                        color: Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                                       Kirigami.Theme.highlightColor.b, 0.10)

                        Rectangle {        // left accent bar
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: 2
                            color: Kirigami.Theme.highlightColor
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Kirigami.Units.smallSpacing * 1.5
                            anchors.rightMargin: Kirigami.Units.gridUnit   // clear the overlay scrollbar
                            spacing: Kirigami.Units.smallSpacing

                            Kirigami.Icon {
                                source: "network-card-symbolic"
                                opacity: 0.7
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            }
                            PlasmaComponents.Label {
                                text: section
                                font.weight: Font.DemiBold
                                font.capitalization: Font.AllUppercase
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                color: Kirigami.Theme.highlightColor
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            // count, as a solid accent badge with contrasting text
                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                implicitHeight: Math.round(secCount.implicitHeight + Kirigami.Units.smallSpacing / 2)
                                implicitWidth: Math.max(implicitHeight, secCount.implicitWidth + Kirigami.Units.smallSpacing * 1.5)
                                radius: height / 2
                                color: Kirigami.Theme.highlightColor
                                PlasmaComponents.Label {
                                    id: secCount
                                    anchors.centerIn: parent
                                    text: ctrl.networkCounts[section] || 0
                                    font.bold: true
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    color: Kirigami.Theme.highlightedTextColor
                                }
                            }
                            // favorite (pin network to top)
                            Kirigami.Icon {
                                source: ctrl.favNets[section] ? "starred-symbolic" : "non-starred-symbolic"
                                color: ctrl.favNets[section] ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.highlightColor
                                opacity: ctrl.favNets[section] ? 1.0 : 0.55
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -Kirigami.Units.smallSpacing   // larger hit target
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: ctrl.toggleFavNet(section)
                                }
                            }
                        }
                    }

                    delegate: ContainerDelegate {
                        width: ListView.view ? ListView.view.width : 0
                        showStats: ctrl.showStats
                        onActionRequested: (act, id, name) => {
                            if (act === "rm" && Plasmoid.configuration.confirmDestructive)
                                fullView.confirm(i18n("Remove container “%1”?", name),
                                                 function () { ctrl.doAction("rm", id); });
                            else ctrl.doAction(act, id);
                        }
                        onExecRequested: (id, name) => ctrl.openExec(id, name)
                        onLogsRequested: (id, name) => fullView.showLogs(id, name)
                        onFavToggleRequested: (name) => ctrl.toggleFavCont(name)
                    }
                }
            }
        }

        // ---- empty / error placeholder ----
        PlasmaExtras.PlaceholderMessage {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !fullView.hasList
            iconName: !ctrl.active ? "network-server"
                    : ctrl.loading && !ctrl.reachable ? "view-refresh"
                    : !ctrl.reachable ? "network-disconnect"
                    : !ctrl.dockerOk ? "dialog-warning"
                    : "docker"
            text: !ctrl.active ? i18n("No server")
                : (ctrl.loading && !ctrl.reachable && ctrl.reason === "") ? i18n("Connecting…")
                : ctrl.reachable && ctrl.dockerOk ? (ctrl.totalCount > 0 ? i18n("Nothing matches") : i18n("No containers"))
                : i18n("Not connected")
            explanation: !ctrl.active ? fullView.reasonText("no_server")
                : (ctrl.reachable && ctrl.dockerOk) ? (ctrl.totalCount > 0
                    ? i18n("%1 hidden by the filter. Clear the search or turn off ‘running only’.", ctrl.totalCount)
                    : i18n("This server is reachable but has no containers."))
                : (ctrl.reason === "" ? "" : fullView.reasonText(ctrl.reason))
            helpfulAction: !ctrl.active ? configureAction : null
        }

        // ---- compose section ----
        ColumnLayout {
            Layout.fillWidth: true
            visible: ctrl.showCompose && fullView.ready && ctrl.composeModel.count > 0
            spacing: Kirigami.Units.smallSpacing / 2

            Kirigami.Separator { Layout.fillWidth: true }
            Kirigami.Heading { level: 5; text: i18n("Compose projects") }
            Repeater {
                model: ctrl.composeModel
                delegate: ComposeDelegate {
                    Layout.fillWidth: true
                    onUpRequested: (files, name) => ctrl.doComposeAction("up", files)
                    onDownRequested: (files, name) => {
                        if (Plasmoid.configuration.confirmDestructive)
                            fullView.confirm(i18n("Stop project “%1”? (compose down)", name),
                                             function () { ctrl.doComposeAction("down", files); });
                        else ctrl.doComposeAction("down", files);
                    }
                    onViewFileRequested: (path) => fullView.showFile(path)
                    onEditFileRequested: (path) => ctrl.openInKate(path)
                    onStackRemoveRequested: (name) =>
                        fullView.confirm(i18n("Remove swarm stack “%1”? This stops all its services.", name),
                                         function () { ctrl.doStackAction("rm", name); })
                }
            }
        }

        // ---- footer ----
        PlasmaComponents.Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            opacity: 0.6
            font: Kirigami.Theme.smallFont
            text: fullView.ready
                  ? i18n("%1 running / %2 · showing %3%4 · updated %5",
                         ctrl.runningCount, ctrl.totalCount, ctrl.containerModel.count,
                         (ctrl.exitedHiddenCount > 0 ? i18n(" (%1 hidden)", ctrl.exitedHiddenCount) : ""),
                         ctrl.lastUpdated)
                  : (ctrl.active ? (ctrl.active.label || ctrl.active.host) : "")
        }
    }

    Kirigami.Action {
        id: configureAction
        text: i18n("Configure…")
        icon.name: "configure"
        onTriggered: {
            var a = Plasmoid.internalAction ? Plasmoid.internalAction("configure") : null;
            if (a) a.trigger();
        }
    }

    // ==================== logs overlay (auto-follow) ====================
    Rectangle {
        id: logsOverlay
        anchors.fill: parent
        visible: false
        color: Kirigami.Theme.backgroundColor
        radius: Kirigami.Units.smallSpacing

        Timer {
            interval: Math.max(1, Plasmoid.configuration.logFollowInterval) * 1000
            running: logsOverlay.visible && followToggle.checked
            repeat: true
            onTriggered: fullView.refreshLogs()
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading { level: 5; text: i18n("Logs") }
                PlasmaComponents.Label { id: logsTitle; font.family: "monospace"; opacity: 0.8; Layout.fillWidth: true; elide: Text.ElideRight }
                PlasmaComponents.ToolButton {
                    id: followToggle
                    checkable: true
                    checked: true
                    icon.name: "media-playback-start"
                    text: i18n("Follow")
                    display: PlasmaComponents.AbstractButton.IconOnly
                    PlasmaComponents.ToolTip { text: followToggle.checked ? i18n("Following (auto-refresh) — click to pause") : i18n("Paused — click to follow") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "utilities-terminal"
                    onClicked: ctrl.followLogs(fullView.logsId, fullView.logsName)
                    PlasmaComponents.ToolTip { text: i18n("Follow live in Konsole") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "dialog-close"
                    onClicked: logsOverlay.visible = false
                    PlasmaComponents.ToolTip { text: i18n("Close") }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }
            QQC2.ScrollView {
                id: logScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                QQC2.ScrollBar.vertical: QQC2.ScrollBar { id: logVBar }

                // set text but keep the view pinned to the bottom if it already was
                function setText(t) {
                    if (t === logsArea.text) return;
                    var wasBottom = (logVBar.size >= 1.0) || (logVBar.position >= (1.0 - logVBar.size) - 0.002);
                    logsArea.text = t;
                    Qt.callLater(function () { if (wasBottom) logVBar.position = 1.0 - logVBar.size; });
                }

                QQC2.TextArea {
                    id: logsArea
                    readOnly: true
                    textFormat: TextEdit.PlainText
                    wrapMode: TextEdit.NoWrap
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    selectByMouse: true
                }
            }
        }
    }

    // ==================== nginx overlay ====================
    Rectangle {
        id: nginxOverlay
        anchors.fill: parent
        visible: false
        color: Kirigami.Theme.backgroundColor
        radius: Kirigami.Units.smallSpacing

        ListModel { id: nginxModel }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading { level: 5; text: i18n("Nginx") }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    opacity: 0.7; elide: Text.ElideRight
                    font.family: "monospace"
                    text: fullView.nginxData ? (fullView.nginxData.base + (fullView.nginxData.style === "confd" ? "  (conf.d)" : "")) : ""
                }
                QQC2.Button {
                    text: i18n("New site"); icon.name: "list-add"
                    onClicked: fullView.openSiteForm()
                    PlasmaComponents.ToolTip { text: i18n("Create a new nginx website config") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"; onClicked: { fullView.loadNginx(); fullView.loadCerts(); }
                    PlasmaComponents.ToolTip { text: i18n("Reload list") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "dialog-close"; onClicked: nginxOverlay.visible = false
                    PlasmaComponents.ToolTip { text: i18n("Close") }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // nginx.conf row
            RowLayout {
                Layout.fillWidth: true
                visible: fullView.nginxData && fullView.nginxData.hasConf
                PlasmaComponents.Label { text: "nginx.conf"; font.bold: true; Layout.fillWidth: true; font.family: "monospace" }
                PlasmaComponents.ToolButton {
                    icon.name: "document-preview"; text: i18n("View"); display: PlasmaComponents.AbstractButton.IconOnly
                    onClicked: fullView.showFile(fullView.nginxData.base + "/nginx.conf")
                    PlasmaComponents.ToolTip { text: i18n("View") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "document-edit"; text: i18n("Edit"); display: PlasmaComponents.AbstractButton.IconOnly
                    onClicked: ctrl.openInKate(fullView.nginxData.base + "/nginx.conf")
                    PlasmaComponents.ToolTip { text: i18n("Edit in Kate") }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true; visible: fullView.nginxData && fullView.nginxData.hasConf }

            // sites list
            PlasmaComponents.Label {
                text: i18n("Sites"); opacity: 0.7; font: Kirigami.Theme.smallFont
                visible: nginxModel.count > 0
            }
            PlasmaComponents.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ListView {
                    model: nginxModel
                    clip: true
                    delegate: RowLayout {
                        width: ListView.view.width
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Switch {
                            checked: model.senabled
                            onToggled: fullView.ctrl.nginxSite(checked ? "enable" : "disable", model.sname,
                                          function (r) { fullView.nginxResult = r && r.ok
                                              ? i18n("%1 %2 — Test & Reload to apply", model.sname, (checked ? i18n("enabled") : i18n("disabled")))
                                              : i18n("Failed to change %1", model.sname);
                                              fullView.loadNginx(); })
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                PlasmaComponents.Label {
                                    text: model.sname; elide: Text.ElideRight
                                    Layout.fillWidth: true
                                    font.family: "monospace"
                                    opacity: model.senabled ? 1.0 : 0.6
                                }
                                Kirigami.Icon {
                                    source: "lock"
                                    visible: model.ssl
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                    PlasmaComponents.ToolTip { text: i18n("Has an SSL/TLS certificate block") }
                                }
                            }
                            PlasmaComponents.Label {
                                visible: ("" + model.domains).length > 0
                                text: model.domains; elide: Text.ElideRight
                                Layout.fillWidth: true
                                opacity: 0.6; font: Kirigami.Theme.smallFont
                            }
                        }
                        PlasmaComponents.ToolButton {
                            icon.name: model.ssl ? "security-high" : "security-low"
                            enabled: model.senabled
                            onClicked: fullView.openSslForm(model.domains)
                            PlasmaComponents.ToolTip {
                                text: !model.senabled ? i18n("Enable & reload the site first to request SSL")
                                    : model.ssl ? i18n("Renew / reissue SSL (certbot)")
                                    : i18n("Get SSL certificate (certbot)")
                            }
                        }
                        PlasmaComponents.ToolButton {
                            icon.name: "document-preview"
                            onClicked: fullView.showFile(fullView.nginxFilePath(model.sname, model.senabled))
                            PlasmaComponents.ToolTip { text: i18n("View") }
                        }
                        PlasmaComponents.ToolButton {
                            icon.name: "document-edit"
                            onClicked: ctrl.openInKate(fullView.nginxFilePath(model.sname, model.senabled))
                            PlasmaComponents.ToolTip { text: i18n("Edit in Kate") }
                        }
                    }
                }
            }

            // ---- certificates (expiry) ----
            Kirigami.Separator { Layout.fillWidth: true; visible: fullView.nginxCertsData.length > 0 }
            PlasmaComponents.Label {
                text: i18n("Certificates"); opacity: 0.7; font: Kirigami.Theme.smallFont
                visible: fullView.nginxCertsData.length > 0
            }
            PlasmaComponents.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(fullView.nginxCertsData.length, 3) * Kirigami.Units.gridUnit * 2.2
                visible: fullView.nginxCertsData.length > 0
                ListView {
                    clip: true
                    model: fullView.nginxCertsData
                    delegate: ColumnLayout {
                        width: ListView.view.width
                        spacing: 0
                        RowLayout {
                            Layout.fillWidth: true
                            Kirigami.Icon {
                                source: ("" + modelData.valid).indexOf("INVALID") >= 0 ? "data-error" : "lock"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            }
                            PlasmaComponents.Label {
                                text: modelData.name; Layout.fillWidth: true; elide: Text.ElideRight
                                font.family: "monospace"
                            }
                            PlasmaComponents.Label {
                                text: modelData.valid || ""; font: Kirigami.Theme.smallFont
                                opacity: 0.8
                                color: ("" + modelData.valid).indexOf("INVALID") >= 0
                                       ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                            }
                        }
                        PlasmaComponents.Label {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            text: i18n("expires %1", modelData.expiry || "?")
                            opacity: 0.55; font: Kirigami.Theme.smallFont
                        }
                    }
                }
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                visible: !fullView.certbotAvailable
                opacity: 0.7; font: Kirigami.Theme.smallFont
                text: i18n("certbot is not installed on this server — install it to manage SSL certificates.")
            }

            // nginx -t / reload result
            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: fullView.nginxResult !== ""
                wrapMode: Text.WordWrap
                font.family: "monospace"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: fullView.nginxResult
            }

            RowLayout {
                Layout.fillWidth: true
                QQC2.Button {
                    text: i18n("Test (nginx -t)"); icon.name: "checkmark"
                    onClicked: ctrl.nginxTest(function (r) { fullView.nginxResult = (r ? r.output : "") || (r && r.ok ? i18n("OK") : i18n("failed")); })
                }
                Item { Layout.fillWidth: true }
                QQC2.Button {
                    text: i18n("Reload nginx"); icon.name: "system-reboot"
                    onClicked: fullView.confirm(i18n("Reload nginx now?"),
                                  function () { ctrl.nginxReload(function (r) { fullView.nginxResult = (r ? r.output : "") || (r && r.ok ? i18n("Reloaded") : i18n("reload failed")); }); })
                }
            }
        }
    }

    // ==================== create-site form ====================
    Rectangle {
        id: siteFormOverlay
        anchors.fill: parent
        visible: false
        color: Kirigami.Theme.backgroundColor
        radius: Kirigami.Units.smallSpacing

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading { level: 5; text: i18n("New website"); Layout.fillWidth: true }
                PlasmaComponents.ToolButton {
                    icon.name: "dialog-close"; onClicked: siteFormOverlay.visible = false
                    PlasmaComponents.ToolTip { text: i18n("Close") }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                ColumnLayout {
                    width: siteFormOverlay.width - Kirigami.Units.smallSpacing * 2
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label { text: i18n("Domain(s) — space separated"); font: Kirigami.Theme.smallFont; opacity: 0.7 }
                    QQC2.TextField {
                        id: siteDomains
                        Layout.fillWidth: true
                        placeholderText: i18n("example.com www.example.com")
                    }

                    PlasmaComponents.Label { text: i18n("Config name (optional — defaults to first domain)"); font: Kirigami.Theme.smallFont; opacity: 0.7 }
                    QQC2.TextField {
                        id: siteName
                        Layout.fillWidth: true
                        placeholderText: siteDomains.text.trim().split(/\s+/)[0] || i18n("example.com")
                    }

                    PlasmaComponents.Label { text: i18n("Type"); font: Kirigami.Theme.smallFont; opacity: 0.7 }
                    RowLayout {
                        Layout.fillWidth: true
                        QQC2.RadioButton { id: siteTypeProxy; text: i18n("Reverse proxy"); checked: true }
                        QQC2.RadioButton { id: siteTypeStatic; text: i18n("Static files") }
                    }

                    PlasmaComponents.Label {
                        text: siteTypeProxy.checked ? i18n("Proxy to (URL)") : i18n("Root directory")
                        font: Kirigami.Theme.smallFont; opacity: 0.7
                    }
                    QQC2.TextField {
                        id: siteTarget
                        Layout.fillWidth: true
                        placeholderText: siteTypeProxy.checked
                            ? "http://127.0.0.1:3000"
                            : "/var/www/" + (siteDomains.text.trim().split(/\s+/)[0] || "site")
                    }

                    QQC2.CheckBox { id: siteEnable; text: i18n("Enable site now"); checked: true }
                    QQC2.CheckBox {
                        id: siteMkroot; text: i18n("Create the root directory with a placeholder index.html")
                        checked: true; visible: siteTypeStatic.checked
                    }

                    PlasmaComponents.Label {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        visible: fullView.siteFormResult !== ""
                        font.family: "monospace"; font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: fullView.siteFormResult
                    }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                QQC2.Button {
                    text: i18n("Create"); icon.name: "list-add"
                    enabled: !fullView.siteCreated
                    onClicked: fullView.doCreateSite()
                }
                QQC2.Button {
                    text: i18n("Test"); icon.name: "checkmark"
                    visible: fullView.siteCreated
                    onClicked: ctrl.nginxTest(function (r) { fullView.siteFormResult = (r ? r.output : "") || (r && r.ok ? i18n("OK") : i18n("failed")); })
                }
                QQC2.Button {
                    text: i18n("Reload"); icon.name: "system-reboot"
                    visible: fullView.siteCreated
                    onClicked: ctrl.nginxReload(function (r) { fullView.siteFormResult = (r ? r.output : "") || (r && r.ok ? i18n("Reloaded") : i18n("reload failed")); })
                }
                Item { Layout.fillWidth: true }
                QQC2.Button {
                    text: i18n("Get SSL"); icon.name: "security-high"
                    visible: fullView.siteCreated && siteEnable.checked
                    onClicked: { siteFormOverlay.visible = false; fullView.openSslForm(fullView.lastCreatedDomains); }
                }
                QQC2.Button {
                    text: fullView.siteCreated ? i18n("Done") : i18n("Cancel"); icon.name: "dialog-close"
                    onClicked: siteFormOverlay.visible = false
                }
            }
        }
    }

    // ==================== SSL / certbot form ====================
    Rectangle {
        id: sslFormOverlay
        anchors.fill: parent
        visible: false
        color: Kirigami.Theme.backgroundColor
        radius: Kirigami.Units.smallSpacing

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading { level: 5; text: i18n("Get SSL certificate"); Layout.fillWidth: true }
                PlasmaComponents.ToolButton {
                    icon.name: "dialog-close"; onClicked: sslFormOverlay.visible = false
                    PlasmaComponents.ToolTip { text: i18n("Close") }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            PlasmaComponents.Label { text: i18n("Domain(s) — space separated"); font: Kirigami.Theme.smallFont; opacity: 0.7 }
            QQC2.TextField {
                id: sslDomains
                Layout.fillWidth: true
                placeholderText: i18n("example.com www.example.com")
            }
            QQC2.CheckBox { id: sslRedirect; text: i18n("Redirect HTTP → HTTPS"); checked: true }
            PlasmaComponents.Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                opacity: 0.6; font: Kirigami.Theme.smallFont
                text: i18n("Uses certbot --nginx (Let's Encrypt). The domain's DNS must point to this server and port 80 must be reachable. No email is registered.")
            }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                QQC2.TextArea {
                    id: sslArea
                    readOnly: true
                    textFormat: TextEdit.PlainText
                    wrapMode: TextEdit.Wrap
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    selectByMouse: true
                    text: fullView.sslResult
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                QQC2.Button {
                    text: i18n("Get certificate"); icon.name: "security-high"
                    enabled: !fullView.sslRunning
                    onClicked: fullView.doRunCertbot()
                }
                PlasmaComponents.BusyIndicator {
                    running: fullView.sslRunning; visible: fullView.sslRunning
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                }
                Item { Layout.fillWidth: true }
                QQC2.Button {
                    text: i18n("Close"); icon.name: "dialog-close"
                    onClicked: sslFormOverlay.visible = false
                }
            }
        }
    }

    // ==================== file overlay (view + edit in Kate) ====================
    Rectangle {
        id: fileOverlay
        anchors.fill: parent
        visible: false
        color: Kirigami.Theme.backgroundColor
        radius: Kirigami.Units.smallSpacing

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading { level: 5; text: i18n("File") }
                PlasmaComponents.Label { id: fileTitle; font.family: "monospace"; opacity: 0.8; Layout.fillWidth: true; elide: Text.ElideLeft }
                PlasmaComponents.ToolButton {
                    icon.name: "document-edit"; text: i18n("Edit in Kate")
                    display: PlasmaComponents.AbstractButton.TextBesideIcon
                    onClicked: ctrl.openInKate(fullView.filePath)
                    PlasmaComponents.ToolTip { text: i18n("Open in Kate over SSH (edit + save)") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    onClicked: ctrl.readFile(fullView.filePath, function (t) { fileArea.text = t; })
                    PlasmaComponents.ToolTip { text: i18n("Reload") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "dialog-close"; onClicked: fileOverlay.visible = false
                    PlasmaComponents.ToolTip { text: i18n("Close") }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                QQC2.TextArea {
                    id: fileArea
                    readOnly: true
                    textFormat: TextEdit.PlainText
                    wrapMode: TextEdit.NoWrap
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    selectByMouse: true
                }
            }
        }
    }

    // ==================== disk overlay (usage + safe cleanup) ====================
    Rectangle {
        id: diskOverlay
        anchors.fill: parent
        visible: false
        color: Kirigami.Theme.backgroundColor
        radius: Kirigami.Units.smallSpacing

        Timer {                          // light auto-refresh while open
            interval: 30000
            running: diskOverlay.visible
            repeat: true
            onTriggered: fullView.loadDisk()
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading { level: 5; text: i18n("Disk usage") }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    opacity: 0.7; elide: Text.ElideRight
                    font: Kirigami.Theme.smallFont
                    text: ctrl.active ? (ctrl.active.label || ctrl.active.host) : ""
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"; onClicked: fullView.loadDisk()
                    PlasmaComponents.ToolTip { text: i18n("Refresh") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "dialog-close"; onClicked: diskOverlay.visible = false
                    PlasmaComponents.ToolTip { text: i18n("Close") }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // ---- server filesystem usage bar ----
            ColumnLayout {
                id: diskBar
                Layout.fillWidth: true
                visible: fullView.diskData && fullView.diskData.disk
                spacing: Kirigami.Units.smallSpacing / 2
                property var d: (fullView.diskData && fullView.diskData.disk) ? fullView.diskData.disk : null
                property real frac: d ? Fmt.pctFraction(d.usePct) : 0
                property color barColor: frac >= 0.9 ? Kirigami.Theme.negativeTextColor
                                       : frac >= 0.75 ? Kirigami.Theme.neutralTextColor
                                       : Kirigami.Theme.positiveTextColor

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        font.bold: true
                        text: i18n("Server disk%1", diskBar.d ? (" — " + diskBar.d.usePct) : "")
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        opacity: 0.75; font: Kirigami.Theme.smallFont
                        text: diskBar.d ? i18n("%1 used · %2 free · %3 total",
                                               Fmt.fmtBytes(diskBar.d.used), Fmt.fmtBytes(diskBar.d.avail), Fmt.fmtBytes(diskBar.d.size)) : ""
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    height: Kirigami.Units.gridUnit * 0.55
                    radius: height / 2
                    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
                    Rectangle {
                        width: Math.round(parent.width * diskBar.frac)
                        height: parent.height
                        radius: height / 2
                        color: diskBar.barColor
                        Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration } }
                    }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }
            PlasmaComponents.Label {
                text: i18n("Docker — system df"); opacity: 0.7; font: Kirigami.Theme.smallFont
            }

            // ---- docker system df rows (+ safe prune) ----
            Repeater {
                model: (fullView.diskData && fullView.diskData.df) ? fullView.diskData.df : []
                delegate: RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    readonly property string pruneKey: fullView.pruneKeyFor(modelData.type)

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        PlasmaComponents.Label { text: modelData.type; font.bold: true; font.family: "monospace" }
                        PlasmaComponents.Label {
                            opacity: 0.7; font: Kirigami.Theme.smallFont
                            text: i18n("%1 · %2 reclaimable · %3/%4 in use",
                                       modelData.size, (modelData.reclaimable || "0B"), modelData.active, modelData.count)
                        }
                    }
                    PlasmaComponents.Label {
                        visible: modelData.type === "Local Volumes"
                        text: i18n("protected"); opacity: 0.5; font: Kirigami.Theme.smallFont
                    }
                    QQC2.Button {
                        visible: parent.pruneKey !== ""
                        text: modelData.type === "Images" ? i18n("Prune dangling") : i18n("Prune")
                        icon.name: "edit-clear-all"
                        onClicked: {
                            var label = modelData.type, key = parent.pruneKey;
                            fullView.confirm(i18n("Prune %1? Removes only unused items — never volumes or in-use data.", label),
                                function () {
                                    fullView.diskResult = i18n("Pruning %1…", label);
                                    ctrl.doPrune(key, function (r) {
                                        fullView.diskResult = (r && r.ok)
                                            ? i18n("%1: reclaimed %2", label, r.reclaimed || "0B")
                                            : i18n("%1: prune failed (%2)", label, r ? r.reason : "error");
                                        fullView.loadDisk();
                                    });
                                });
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: fullView.diskResult !== ""
                wrapMode: Text.WordWrap
                font.family: "monospace"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: fullView.diskResult
            }
        }
    }

    // ==================== file manager (SFTP) ====================
    property bool fmEverOpened: false
    Rectangle {
        id: fmOverlay
        anchors.fill: parent
        visible: false
        onVisibleChanged: if (visible) fullView.fmEverOpened = true
        color: Kirigami.Theme.backgroundColor
        radius: Kirigami.Units.smallSpacing

        Loader {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            // lazy: built on first open, then kept alive so in-flight transfers keep
            // tracking, and the queue survives, even while the overlay is hidden.
            active: fullView.fmEverOpened
            sourceComponent: Component {
                FileManager {
                    ctrl: fullView.ctrl
                    onCloseRequested: fmOverlay.visible = false
                }
            }
        }
    }

    Kirigami.PromptDialog {
        id: confirmDialog
        property var pendingAction
        property string message: ""
        title: i18n("Please confirm")
        subtitle: message
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: if (pendingAction) pendingAction()
    }
}
