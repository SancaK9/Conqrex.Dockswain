import QtQuick
import QtQml
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

// Thin manager: owns the open tabs, the shared view state (filter/group/favorites),
// and a pool of ServerSession objects (one live connection per open tab). Per-server
// data/actions are proxied/forwarded to the active session, so FullView and CompactView
// keep reading root.X.
PlasmoidItem {
    id: root

    // Keep the popup open when it loses focus while "pinned", so the user can drag
    // files from Dolphin into the file manager without the panel popup auto-closing.
    property bool pinned: false
    hideOnWindowDeactivate: !pinned

    // --- servers + tabs ----------------------------------------------------
    property var servers: {
        try { return JSON.parse(Plasmoid.configuration.serversJson || "[]"); }
        catch (e) { return []; }
    }
    property var openTabs: loadOpenTabs()    // array of server indices, persisted
    property int activeTab: 0

    function loadOpenTabs() {
        var arr = [];
        try { arr = JSON.parse(Plasmoid.configuration.openTabsJson || "[]"); } catch (e) { arr = []; }
        arr = (arr || []).filter(function (i) { return i >= 0 && i < servers.length; });
        if (arr.length === 0 && servers.length > 0)
            arr = [Math.min(Math.max(0, Plasmoid.configuration.activeServer), servers.length - 1)];
        return arr;
    }
    function persistTabs() { Plasmoid.configuration.openTabsJson = JSON.stringify(openTabs); }

    function openServerTab(serverIdx) {
        if (serverIdx < 0 || serverIdx >= servers.length) return;
        for (var i = 0; i < openTabs.length; i++)
            if (openTabs[i] === serverIdx) { setActiveTab(i); return; }
        var t = openTabs.slice(); t.push(serverIdx); openTabs = t; persistTabs();
        setActiveTab(openTabs.length - 1);
    }
    function closeTab(tabIdx) {
        if (tabIdx < 0 || tabIdx >= openTabs.length) return;
        var t = openTabs.slice(); t.splice(tabIdx, 1); openTabs = t; persistTabs();
        if (activeTab >= openTabs.length) activeTab = Math.max(0, openTabs.length - 1);
        syncActive();
    }
    function setActiveTab(i) { if (i >= 0 && i < openTabs.length) activeTab = i; }

    // drop tabs whose server was removed/reordered in settings
    onServersChanged: {
        if (openTabs === undefined) return;                  // not initialised yet (init order)
        var t = openTabs.filter(function (i) { return i >= 0 && i < servers.length; });
        if (t.length === 0 && servers.length > 0) t = [0];
        if (t.length !== openTabs.length) { openTabs = t; persistTabs(); }
        if (activeTab >= openTabs.length) activeTab = Math.max(0, openTabs.length - 1);
    }

    // --- session pool (one live ServerSession per open tab) ----------------
    Instantiator {
        id: sessionPool
        model: root.openTabs.length
        delegate: ServerSession {
            mainRoot: root
            serverIndex: root.openTabs[index]
            server: root.servers[root.openTabs[index]] || null
            isActive: index === root.activeTab
        }
        onObjectAdded: (index, object) => root.syncActive()
        onObjectRemoved: (index, object) => root.syncActive()
    }
    property var activeSession: null
    function syncActive() {
        activeSession = (activeTab >= 0 && activeTab < sessionPool.count)
                      ? sessionPool.objectAt(activeTab) : null;
    }
    onActiveTabChanged: syncActive()
    Component.onCompleted: syncActive()

    // --- shared view state -------------------------------------------------
    property bool hideExited: Plasmoid.configuration.hideExitedDefault
    property bool groupByNetwork: Plasmoid.configuration.groupByNetwork
    property string searchText: ""
    property var favNets: parseCsvSet(Plasmoid.configuration.favNetworks)
    property var favConts: parseCsvSet(Plasmoid.configuration.favContainers)
    function parseCsvSet(s) {
        var m = {};
        ("" + (s || "")).split(",").forEach(function (x) { var t = x.trim(); if (t) m[t] = 1; });
        return m;
    }
    function toggleFavNet(n) {
        if (!n || n === "—") return;
        var m = Object.assign({}, favNets);
        if (m[n]) delete m[n]; else m[n] = 1;
        favNets = m;                                   // new ref -> favNetsChanged -> sessions re-filter
        Plasmoid.configuration.favNetworks = Object.keys(m).join(",");
    }
    function toggleFavCont(n) {
        if (!n) return;
        var m = Object.assign({}, favConts);
        if (m[n]) delete m[n]; else m[n] = 1;
        favConts = m;
        Plasmoid.configuration.favContainers = Object.keys(m).join(",");
    }

    // --- favorite file paths (JSON: paths can contain commas, so not CSV) ----
    // shape: { "local":[...], "remote:<host>:<port>":[...] }
    property var favPaths: parseFavPaths(Plasmoid.configuration.favPathsJson)
    function parseFavPaths(s) {
        try { var o = JSON.parse(s || "{}"); return (o && typeof o === "object") ? o : {}; }
        catch (e) { return {}; }
    }
    function favScopeKey(side) {
        if (side === "local") return "local";
        var s = active;
        return s ? ("remote:" + s.host + ":" + (s.port || 22)) : "remote:?";
    }
    function favPathsFor(side) { return favPaths[favScopeKey(side)] || []; }
    function isFavPath(side, path) { return favPathsFor(side).indexOf(path) >= 0; }
    function toggleFavPath(side, path) {
        if (!path) return;
        var k = favScopeKey(side);
        var o = JSON.parse(JSON.stringify(favPaths));   // deep clone -> new ref
        var arr = o[k] || [];
        var i = arr.indexOf(path);
        if (i >= 0) arr.splice(i, 1); else arr.push(path);
        o[k] = arr;
        favPaths = o;                                   // new ref -> favPathsChanged
        Plasmoid.configuration.favPathsJson = JSON.stringify(o);
    }

    readonly property url iconSource: Qt.resolvedUrl("../icons/conqrex-dockswain.svg")
    readonly property bool showStats: Plasmoid.configuration.showStats
    readonly property bool showCompose: Plasmoid.configuration.showCompose

    function shq(s) { return "'" + ("" + s).replace(/'/g, "'\\''") + "'"; }

    // --- proxies to the active session -------------------------------------
    property ListModel emptyModel: ListModel {}
    readonly property var active: activeSession ? activeSession.server : null
    readonly property bool reachable: activeSession ? activeSession.reachable : false
    readonly property bool dockerOk: activeSession ? activeSession.dockerOk : false
    readonly property string reason: activeSession ? activeSession.reason : ""
    readonly property bool loading: activeSession ? activeSession.loading : false
    readonly property string lastUpdated: activeSession ? activeSession.lastUpdated : ""
    readonly property int runningCount: activeSession ? activeSession.runningCount : 0
    readonly property int totalCount: activeSession ? activeSession.totalCount : 0
    readonly property int exitedHiddenCount: activeSession ? activeSession.exitedHiddenCount : 0
    readonly property var containerModel: activeSession ? activeSession.containerModel : emptyModel
    readonly property var composeModel: activeSession ? activeSession.composeModel : emptyModel
    readonly property var networkCounts: activeSession ? activeSession.networkCounts : emptyMap
    property var emptyMap: ({})

    // --- forwarders to the active session ----------------------------------
    function refresh()             { if (activeSession) activeSession.refresh(); }
    function applyFilter()         { if (activeSession) activeSession.applyFilter(); }
    function doAction(a, id)       { if (activeSession) activeSession.doAction(a, id); }
    function doComposeAction(a, f) { if (activeSession) activeSession.doComposeAction(a, f); }
    function doStackAction(a, n)   { if (activeSession) activeSession.doStackAction(a, n); }
    function fetchLogs(id, cb, t)  { if (activeSession) activeSession.fetchLogs(id, cb, t); }
    function refreshDisk(cb)       { if (activeSession) activeSession.refreshDisk(cb); }
    function doPrune(w, cb)        { if (activeSession) activeSession.doPrune(w, cb); }
    function containerLogs(cb)     { if (activeSession) activeSession.containerLogs(cb); }
    function truncateLog(id, cb)   { if (activeSession) activeSession.truncateLog(id, cb); }
    function openInKate(p)         { if (activeSession) activeSession.openInKate(p); }
    function readFile(p, cb)       { if (activeSession) activeSession.readFile(p, cb); }
    function nginxInfo(cb)         { if (activeSession) activeSession.nginxInfo(cb); }
    function nginxTest(cb)         { if (activeSession) activeSession.nginxTest(cb); }
    function nginxReload(cb)       { if (activeSession) activeSession.nginxReload(cb); }
    function nginxSite(a, n, cb)   { if (activeSession) activeSession.nginxSite(a, n, cb); }
    function nginxCreate(n, d, t, tg, e, m, cb) { if (activeSession) activeSession.nginxCreate(n, d, t, tg, e, m, cb); }
    function nginxCertbot(d, r, cb){ if (activeSession) activeSession.nginxCertbot(d, r, cb); }
    function nginxCerts(cb)        { if (activeSession) activeSession.nginxCerts(cb); }
    function nginxConfd(cb)        { if (activeSession) activeSession.nginxConfd(cb); else noSession(cb); }
    function nginxConfdToggle(a, n, cb) { if (activeSession) activeSession.nginxConfdToggle(a, n, cb); else noSession(cb); }
    function nginxConfdDelete(n, cb)    { if (activeSession) activeSession.nginxConfdDelete(n, cb); else noSession(cb); }
    function nginxConfdNew(n, cb)       { if (activeSession) activeSession.nginxConfdNew(n, cb); else noSession(cb); }
    function openShell()           { if (activeSession) activeSession.openShell(); }
    function openExec(id, n)       { if (activeSession) activeSession.openExec(id, n); }
    function followLogs(id, n)     { if (activeSession) activeSession.followLogs(id, n); }
    function targetStr()           { return activeSession ? activeSession.targetStr() : ""; }
    // file manager forwarders. With no active session, fire the callback with a
    // failure so callers (FilePane.load) clear their spinner instead of hanging.
    function noSession(cb)             { if (cb) cb({ ok: false, reason: "no_session" }); }
    function sftpList(p, cb)            { if (activeSession) activeSession.sftpList(p, cb); else noSession(cb); }
    function sftpHome(cb)              { if (activeSession) activeSession.sftpHome(cb); else noSession(cb); }
    function sftpMkdir(p, cb)           { if (activeSession) activeSession.sftpMkdir(p, cb); else noSession(cb); }
    function sftpRename(o, n, cb)       { if (activeSession) activeSession.sftpRename(o, n, cb); else noSession(cb); }
    function sftpDelete(p, d, cb)       { if (activeSession) activeSession.sftpDelete(p, d, cb); else noSession(cb); }
    function localList(p, cb)          { if (activeSession) activeSession.localList(p, cb); else noSession(cb); }
    function localMkdir(p, cb)         { if (activeSession) activeSession.localMkdir(p, cb); else noSession(cb); }
    function localRename(o, n, cb)     { if (activeSession) activeSession.localRename(o, n, cb); else noSession(cb); }
    function localDelete(p, d, cb)     { if (activeSession) activeSession.localDelete(p, d, cb); else noSession(cb); }
    function xfer(id, dir, s, t, r, sm, cb) { if (activeSession) activeSession.xfer(id, dir, s, t, r, sm, cb); else noSession(cb); }
    function xferStatus(id, cb)        { if (activeSession) activeSession.xferStatus(id, cb); else noSession(cb); }
    function xferCancel(id, cb)        { if (activeSession) activeSession.xferCancel(id, cb); }
    function xferClear(id, cb)         { if (activeSession) activeSession.xferClear(id, cb); }

    // --- representations ---------------------------------------------------
    toolTipMainText: i18n("Dockswain")
    toolTipSubText: !active ? i18n("No server configured")
                  : !reachable ? i18n("%1 — unreachable", active.label || targetStr())
                  : !dockerOk ? i18n("%1 — docker error (%2)", active.label || targetStr(), reason)
                  : i18n("%1 — %2/%3 running", active.label || targetStr(), runningCount, totalCount)

    compactRepresentation: CompactView {
        reachable: root.reachable
        dockerOk: root.dockerOk
        runningCount: root.runningCount
        totalCount: root.totalCount
        iconSource: root.iconSource
        onToggleRequested: root.expanded = !root.expanded
    }

    fullRepresentation: FullView { ctrl: root }
}
