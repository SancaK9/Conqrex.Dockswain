import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support
import "../code/format.js" as Fmt

// One server's live connection: its own executable engine, models, state and poll
// timers. Instantiated once per open tab, so several servers stay connected at once.
// Shared view state (filter / group / favorites) is read from mainRoot.
Item {
    id: session

    property var mainRoot                 // the root PlasmoidItem (shared view state)
    property var server: null             // {label,user,host,port,key,auth}
    property int serverIndex: -1
    property bool isActive: false         // is this the currently visible tab?

    // --- per-server connection / docker state ---
    property bool reachable: false
    property bool dockerOk: false
    property string reason: ""
    property string lastUpdated: ""
    property bool loading: false
    property int runningCount: 0
    property int totalCount: 0
    property int exitedHiddenCount: 0
    property var statsMap: ({})
    property var allContainers: []
    property var networkCounts: ({})

    property ListModel containerModel: ListModel {}
    property ListModel composeModel: ListModel {}

    readonly property bool showStats: Plasmoid.configuration.showStats
    readonly property bool showCompose: Plasmoid.configuration.showCompose

    // --- shell helpers ---
    function shq(s) { return "'" + ("" + s).replace(/'/g, "'\\''") + "'"; }
    readonly property string scriptPath:
        Qt.resolvedUrl("../code/dockswain.sh").toString().replace(/^file:\/\//, "")

    function envPrefix() {
        var p = "";
        var dc = Plasmoid.configuration.dockerCmd;
        if (dc && dc !== "docker") p += "CNQ_DOCKER_CMD=" + shq(dc) + " ";
        p += "CNQ_SSH_TIMEOUT=" + (Plasmoid.configuration.sshConnectTimeout || 5) + " ";
        p += "CNQ_AUTH=" + ((server && server.auth) ? server.auth : "key") + " ";
        p += "CNQ_NGINX_DIR=" + shq(Plasmoid.configuration.nginxDir || "/etc/nginx") + " ";
        p += "CNQ_EDITOR=" + shq(Plasmoid.configuration.editor || "kate") + " ";
        var st = Plasmoid.configuration.sftpTool;
        if (st && st !== "auto") p += "CNQ_SFTP_TOOL=" + shq(st) + " ";
        return p;
    }
    function helperCmd(sub, extra) {
        if (!server) return "";
        var target = server.user ? (server.user + "@" + server.host) : server.host;
        var c = envPrefix() + "bash " + shq(scriptPath) + " " + sub + " "
              + shq(target) + " " + (server.port || 22) + " " + shq(server.key || "");
        return extra ? (c + " " + extra) : c;
    }
    // script invocation WITHOUT the ssh target, for local-* subcommands that run
    // on this machine (the executable engine already runs locally).
    function localCmd(sub, extra) {
        var c = envPrefix() + "bash " + shq(scriptPath) + " " + sub;
        return extra ? (c + " " + extra) : c;
    }
    function sshArgs() {
        var a = "-o ConnectTimeout=" + (Plasmoid.configuration.sshConnectTimeout || 5)
              + " -o ControlMaster=auto -o ControlPath=\"$XDG_RUNTIME_DIR/cnq-ssh-%r@%h:%p\""
              + " -o ControlPersist=60 -o ServerAliveInterval=15"
              + " -o StrictHostKeyChecking=accept-new -p " + (server.port || 22);
        if (server.auth !== "password" && server.key)
            a += " -o IdentitiesOnly=yes -i " + shq(server.key);
        return a;
    }

    Plasma5Support.DataSource {
        id: engine
        engine: "executable"
        connectedSources: []
        property var cbs: ({})
        onNewData: (source, data) => {
            var cb = cbs[source];
            if (cb) { delete cbs[source]; cb(("" + (data["stdout"] || "")), data["exit code"]); }
            disconnectSource(source);
        }
        function run(cmd, cb) { if (cmd) { cbs[cmd] = cb || function () {}; connectSource(cmd); } }
    }

    // --- data flow ---
    function refresh() {
        if (!server) { reason = "no_server"; return; }
        loading = true;
        engine.run(helperCmd("list"), function (out) { loading = false; applyList(out); });
        if (showCompose) refreshCompose();
    }
    function applyList(out) {
        try {
            var d = JSON.parse(out.trim());
            if (d && d.ok) {
                reachable = true; dockerOk = true; reason = "";
                mergeContainers(d.containers || []);
                lastUpdated = Qt.formatTime(new Date(),
                    Plasmoid.configuration.timeFormat24h ? "HH:mm" : "h:mm AP");
                if (showStats) refreshStats();
            } else {
                reachable = d ? (d.reachable !== false) : false;
                dockerOk = false;
                reason = d ? (d.reason || "error") : "parse_error";
                allContainers = []; containerModel.clear(); recount();
            }
        } catch (e) {
            reason = "parse_error"; dockerOk = false;
            allContainers = []; containerModel.clear(); recount();
        }
    }
    function rowOf(c) {
        var st = statsMap[c.id];
        return {
            cid: c.id, cname: Fmt.cleanName(c.name), cimage: c.image,
            cstate: c.state, cstatus: c.status, cports: Fmt.shortPorts(c.ports),
            cnet: c.networks || "", cnet1: Fmt.primaryNet(c.networks),
            cfav: !!(mainRoot && mainRoot.favConts[Fmt.cleanName(c.name)]),
            ccpu: st ? st.cpu : "", cmem: st ? st.mem : ""
        };
    }
    function isLive(state) { return state === "running" || state === "restarting" || state === "paused"; }
    function mergeContainers(list) { allContainers = list; applyFilter(); }

    function applyFilter() {
        var hideExited     = mainRoot ? mainRoot.hideExited : true;
        var groupByNetwork = mainRoot ? mainRoot.groupByNetwork : false;
        var favNets        = mainRoot ? mainRoot.favNets : ({});
        var favConts       = mainRoot ? mainRoot.favConts : ({});
        var q = ("" + (mainRoot ? mainRoot.searchText : "")).trim().toLowerCase();
        var vis = allContainers.filter(function (c) {
            if (hideExited && !isLive(c.state)) return false;
            if (q !== "") {
                var hay = (Fmt.cleanName(c.name) + " " + c.image + " " + c.state).toLowerCase();
                if (hay.indexOf(q) < 0) return false;
            }
            return true;
        });
        vis.sort(function (a, b) {
            if (groupByNetwork) {
                var na = Fmt.primaryNet(a.networks), nb = Fmt.primaryNet(b.networks);
                var fna = favNets[na] ? 0 : 1, fnb = favNets[nb] ? 0 : 1;
                if (fna !== fnb) return fna - fnb;
                if (na !== nb) return na.localeCompare(nb);
            }
            var fca = favConts[Fmt.cleanName(a.name)] ? 0 : 1;
            var fcb = favConts[Fmt.cleanName(b.name)] ? 0 : 1;
            if (fca !== fcb) return fca - fcb;
            var ra = a.state === "running" ? 0 : 1, rb = b.state === "running" ? 0 : 1;
            if (ra !== rb) return ra - rb;
            return Fmt.cleanName(a.name).localeCompare(Fmt.cleanName(b.name));
        });
        var nc = {};
        vis.forEach(function (c) { var n = Fmt.primaryNet(c.networks); nc[n] = (nc[n] || 0) + 1; });
        networkCounts = nc;
        mergeVisible(vis);
        recount();
    }
    function mergeVisible(vis) {
        var byId = {};
        vis.forEach(function (c) { byId[c.id] = c; });
        for (var i = containerModel.count - 1; i >= 0; i--) {
            if (!byId[containerModel.get(i).cid]) containerModel.remove(i);
        }
        for (var k = 0; k < vis.length; k++) {
            var c = vis[k], cur = -1;
            for (var m = k; m < containerModel.count; m++) {
                if (containerModel.get(m).cid === c.id) { cur = m; break; }
            }
            if (cur === -1) containerModel.insert(k, rowOf(c));
            else { if (cur !== k) containerModel.move(cur, k, 1); containerModel.set(k, rowOf(c)); }
        }
    }
    function recount() {
        var n = 0, ex = 0;
        for (var i = 0; i < allContainers.length; i++) {
            var s = allContainers[i].state;
            if (s === "running") n++;
            if (!isLive(s)) ex++;
        }
        runningCount = n;
        totalCount = allContainers.length;
        exitedHiddenCount = (mainRoot && mainRoot.hideExited) ? ex : 0;
    }
    function refreshStats() {
        engine.run(helperCmd("stats"), function (out) {
            try {
                var d = JSON.parse(out.trim());
                if (d && d.ok) {
                    statsMap = d.stats || {};
                    for (var j = 0; j < containerModel.count; j++) {
                        var st = statsMap[containerModel.get(j).cid];
                        containerModel.setProperty(j, "ccpu", st ? st.cpu : "");
                        containerModel.setProperty(j, "cmem", st ? st.mem : "");
                    }
                }
            } catch (e) {}
        });
    }
    function refreshCompose() {
        engine.run(helperCmd("compose"), function (out) {
            try {
                var d = JSON.parse(out.trim());
                composeModel.clear();
                if (d && d.ok) {
                    (d.projects || []).forEach(function (p) {
                        var cs = Fmt.composeState(p.status);
                        composeModel.append({
                            pname: p.name, pstatus: p.status, pstate: cs.state,
                            pfiles: (p.configFiles || []).join(","), pswarm: false
                        });
                    });
                    (d.stacks || []).forEach(function (s) {
                        composeModel.append({
                            pname: s.name, pstatus: i18n("%1 services · swarm", s.services || "?"),
                            pstate: "running", pfiles: "", pswarm: true
                        });
                    });
                }
            } catch (e) {}
        });
    }

    // --- disk + prune + actions + files/nginx + terminal ---
    function refreshDisk(cb) {
        engine.run(helperCmd("disk"), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function doPrune(what, cb) {
        engine.run(helperCmd("prune", shq(what)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function containerLogs(cb) {
        engine.run(helperCmd("container-logs"), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function truncateLog(id, cb) {
        engine.run(helperCmd("truncate-log", shq(id)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function doAction(act, id) {
        engine.run(helperCmd("action", act + " " + shq(id)), function () { refresh(); });
    }
    function doComposeAction(act, filesCsv) {
        engine.run(helperCmd("compose-action", act + " " + shq(filesCsv)), function () { refreshCompose(); });
    }
    function doStackAction(act, name) {
        engine.run(helperCmd("stack-action", act + " " + shq(name)), function () { refreshCompose(); });
    }
    function fetchLogs(id, cb, tail) {
        var t = tail || Plasmoid.configuration.logTail || 500;
        engine.run(helperCmd("logs", shq(id) + " " + t), function (out) {
            try { var d = JSON.parse(out.trim()); cb(d && d.ok ? d.text : "(" + (d ? d.reason : "error") + ")"); }
            catch (e) { cb("(could not read logs)"); }
        });
    }
    function openInKate(path) {
        if (!server || !path) return;
        engine.run(helperCmd("edit", shq(path)));
    }
    function readFile(path, cb) {
        engine.run(helperCmd("readfile", shq(path)), function (out) {
            try { var d = JSON.parse(out.trim()); cb(d && d.ok ? d.text : "(" + (d ? d.reason : "error") + ")"); }
            catch (e) { cb("(could not read file)"); }
        });
    }
    function nginxInfo(cb) {
        engine.run(helperCmd("nginx-info"), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function nginxTest(cb) {
        engine.run(helperCmd("nginx-test"), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, output: "(error)" }); }
        });
    }
    function nginxReload(cb) {
        engine.run(helperCmd("nginx-reload"), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, output: "(error)" }); }
        });
    }
    function nginxSite(act, name, cb) {
        engine.run(helperCmd("nginx-site", act + " " + shq(name)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false }); }
        });
    }
    // create a new server{} block. type = "proxy" | "static";
    // target = proxy_pass URL (proxy) or root dir (static), domains is space-separated.
    function nginxCreate(name, domains, type, target, enable, mkroot, cb) {
        var extra = shq(name) + " " + shq(domains) + " " + shq(type) + " " + shq(target)
                  + " " + (enable ? 1 : 0) + " " + (mkroot ? 1 : 0);
        engine.run(helperCmd("nginx-create", extra), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    // get/install a Let's Encrypt cert for the (space-separated) domains via certbot --nginx
    function nginxCertbot(domains, redirect, cb) {
        engine.run(helperCmd("nginx-certbot", shq(domains) + " " + (redirect ? 1 : 0)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, output: "(error)" }); }
        });
    }
    // list installed certs and their expiry dates
    function nginxCerts(cb) {
        engine.run(helperCmd("nginx-certs"), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, certbot: true, certs: [] }); }
        });
    }

    // --- SFTP file manager: remote ops (over the warm master) ---
    function sftpList(path, cb) {
        engine.run(helperCmd("sftp-list", shq(path)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function sftpHome(cb) {
        engine.run(helperCmd("sftp-home"), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function sftpMkdir(path, cb) {
        engine.run(helperCmd("sftp-mkdir", shq(path)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function sftpRename(oldP, newP, cb) {
        engine.run(helperCmd("sftp-rename", shq(oldP) + " " + shq(newP)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function sftpDelete(path, isDir, cb) {
        engine.run(helperCmd("sftp-delete", shq(path) + " " + (isDir ? 1 : 0)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }

    // --- local FS ops (run on this machine, no ssh target) ---
    function localList(path, cb) {
        engine.run(localCmd("local-list", shq(path)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function localMkdir(path, cb) {
        engine.run(localCmd("local-mkdir", shq(path)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function localRename(oldP, newP, cb) {
        engine.run(localCmd("local-rename", shq(oldP) + " " + shq(newP)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function localDelete(path, isDir, cb) {
        engine.run(localCmd("local-delete", shq(path) + " " + (isDir ? 1 : 0)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }

    // --- transfers (async, id-based, polled) ---
    // dir: "up" (local->remote) | "down" (remote->local); sync: ""|newer|new-only|size|existing
    function xfer(id, dir, src, dst, recursive, sync, cb) {
        var extra = shq(id) + " " + dir + " " + shq(src) + " " + shq(dst)
                  + " " + (recursive ? 1 : 0) + " " + shq(sync || "");
        engine.run(helperCmd("xfer", extra), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function xferStatus(id, cb) {
        engine.run(helperCmd("xfer-status", shq(id)), function (out) {
            try { cb(JSON.parse(out.trim())); } catch (e) { cb({ ok: false, reason: "parse_error" }); }
        });
    }
    function xferCancel(id, cb) {
        engine.run(helperCmd("xfer-cancel", shq(id)), function (out) {
            try { if (cb) cb(JSON.parse(out.trim())); } catch (e) { if (cb) cb({ ok: false }); }
        });
    }
    function xferClear(id, cb) {
        engine.run(helperCmd("xfer-clear", shq(id)), function (out) {
            try { if (cb) cb(JSON.parse(out.trim())); } catch (e) { if (cb) cb({ ok: false }); }
        });
    }

    function term() { return Plasmoid.configuration.terminal || "konsole"; }
    function targetStr() { return server.user ? (server.user + "@" + server.host) : server.host; }
    function openShell() {
        if (!server) return;
        engine.run(term() + " -p tabtitle=" + shq(server.label || targetStr())
                 + " --hold -e ssh " + sshArgs() + " " + shq(targetStr()));
    }
    function openExec(id, name) {
        if (!server) return;
        var remote = "docker exec -it " + id + " sh -lc 'bash || sh'";
        engine.run(term() + " -p tabtitle=" + shq("exec " + (name || id))
                 + " -e ssh -t " + sshArgs() + " " + shq(targetStr()) + " " + shq(remote));
    }
    function followLogs(id, name) {
        if (!server) return;
        var remote = "docker logs -f --tail 200 " + id;
        engine.run(term() + " -p tabtitle=" + shq("logs " + (name || id))
                 + " --hold -e ssh -t " + sshArgs() + " " + shq(targetStr()) + " " + shq(remote));
    }

    onServerChanged: {
        allContainers = []; containerModel.clear(); composeModel.clear(); recount();
        reachable = false; dockerOk = false; reason = ""; statsMap = ({});
        if (server) refresh();
    }
    Component.onCompleted: if (server) refresh();

    // keep this tab's filtered view in sync with shared view state, even in background
    Connections {
        target: session.mainRoot
        ignoreUnknownSignals: true
        function onHideExitedChanged() { session.applyFilter(); }
        function onSearchTextChanged() { session.applyFilter(); }
        // the visible tab is re-sorted by FullView's Loader rebuild (while detached),
        // so only background tabs re-sort here
        function onGroupByNetworkChanged() { if (!session.isActive) session.applyFilter(); }
        function onFavNetsChanged() { session.applyFilter(); }
        function onFavContsChanged() { session.applyFilter(); }
    }

    // list poll runs for every open tab (concurrent / live)
    Timer {
        interval: Math.max(5, Plasmoid.configuration.pollInterval) * 1000
        running: session.server !== null
        repeat: true; triggeredOnStart: true
        onTriggered: session.refresh()
    }
    // stats poll only for the visible tab (docker stats is slow)
    Timer {
        interval: Math.max(15, Plasmoid.configuration.statsInterval) * 1000
        running: session.server !== null && session.isActive && session.showStats
        repeat: true; triggeredOnStart: true
        onTriggered: session.refreshStats()
    }
}
