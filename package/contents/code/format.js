.pragma library

// Map a docker container State to a semantic category the UI colors:
//   ok (green) / warn (amber) / bad (red) / muted (grey)
function stateCategory(state) {
    switch (state) {
    case "running":    return "ok";
    case "paused":
    case "restarting":
    case "created":    return "warn";
    case "exited":
    case "dead":
    case "removing":   return "bad";
    default:           return "muted";
    }
}

// "127.0.0.1:32801->6379/tcp, 127.0.0.1:32802->6380/tcp" -> "32801→6379, 32802→6380"
function shortPorts(ports) {
    if (!ports) return "";
    var seen = {}, out = [];
    ports.split(",").forEach(function (p) {
        p = p.trim();
        var m = p.match(/(?:[\d.:\[\]]*:)?(\d+)->(\d+)/);
        if (m) {
            var k = m[1] + "→" + m[2];
            if (!seen[k]) { seen[k] = 1; out.push(k); }
        } else {
            var m2 = p.match(/(\d+)\/(?:tcp|udp)/);
            if (m2 && !seen[m2[1]]) { seen[m2[1]] = 1; out.push(m2[1]); }
        }
    });
    return out.join(", ");
}

// "exited(6)" -> { state: "exited", count: 6 }
function composeState(status) {
    if (!status) return { state: "unknown", count: 0 };
    var m = status.match(/^([a-zA-Z]+)\((\d+)\)/);
    if (m) return { state: m[1].toLowerCase(), count: parseInt(m[2]) };
    return { state: status.toLowerCase(), count: 0 };
}

// strip docker's leading "/" from a container name if present
function cleanName(name) {
    if (!name) return "";
    return name.charAt(0) === "/" ? name.substring(1) : name;
}

// shorten a long image ref: "docker.io/library/redis:8.6" -> "redis:8.6"
function shortImage(image) {
    if (!image) return "";
    var at = image.indexOf("@");
    if (at > 0) image = image.substring(0, at);
    var parts = image.split("/");
    return parts[parts.length - 1];
}

// bytes -> human binary units: 1632697606144 -> "1.49 TiB"
function fmtBytes(n) {
    n = Number(n) || 0;
    if (n <= 0) return "0 B";
    var u = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (n >= 100 || i === 0 ? n.toFixed(0) : n.toFixed(n >= 10 ? 1 : 2)) + " " + u[i];
}

// "82%" or "82" -> 0.82 clamped to [0,1]; anything unparseable -> 0
function pctFraction(s) {
    var v = parseFloat(("" + s).replace("%", ""));
    if (isNaN(v)) return 0;
    return Math.max(0, Math.min(1, v / 100));
}

// container's primary docker network for grouping. docker ps lists .Networks in a
// non-stable order, and swarm tasks sit on infra nets (ingress/docker_gwbridge) plus
// their app net. deprioritize infra and sort so the choice is deterministic: a swarm
// task always groups under its app network, never flicking to "ingress".
var INFRA_NETS = { "ingress": 1, "docker_gwbridge": 1, "host": 1, "none": 1 };
function primaryNet(networks) {
    if (!networks) return i18nNone();
    var list = ("" + networks).split(",").map(function (s) { return s.trim(); })
                              .filter(function (s) { return s.length; });
    if (list.length === 0) return i18nNone();
    var app = list.filter(function (n) { return !INFRA_NETS[n.toLowerCase()]; });
    return (app.length ? app : list).sort()[0];
}
function i18nNone() { return "—"; }

// ===================== file manager helpers =====================

// FDO icon name for a file row. Directories -> "folder"; otherwise mapped by
// extension to a freedesktop mime icon (Kirigami.Icon resolves these by name).
var _EXT_ICON = {
    // images
    png:"image-x-generic", jpg:"image-x-generic", jpeg:"image-x-generic",
    gif:"image-x-generic", bmp:"image-x-generic", webp:"image-x-generic",
    ico:"image-x-generic", svg:"image-svg+xml",
    // docs
    pdf:"application-pdf", txt:"text-x-generic", log:"text-x-generic",
    md:"text-markdown", rtf:"text-x-generic", csv:"text-csv",
    doc:"application-msword", docx:"application-msword",
    xls:"application-vnd.ms-excel", xlsx:"application-vnd.ms-excel",
    // code / config
    js:"text-x-javascript", ts:"text-x-javascript", json:"application-json",
    qml:"text-x-qml", sh:"text-x-script", bash:"text-x-script",
    py:"text-x-python", rb:"text-x-ruby", go:"text-x-go", rs:"text-x-rust",
    c:"text-x-csrc", h:"text-x-chdr", cpp:"text-x-c++src", hpp:"text-x-c++hdr",
    java:"text-x-java", php:"application-x-php", sql:"text-x-sql",
    yml:"text-x-yaml", yaml:"text-x-yaml", toml:"text-x-generic",
    xml:"text-xml", html:"text-html", htm:"text-html", css:"text-css",
    conf:"text-x-generic", cfg:"text-x-generic", ini:"text-x-generic", env:"text-x-generic",
    // archives
    zip:"application-zip", gz:"application-x-gzip", tgz:"application-x-compressed-tar",
    tar:"application-x-tar", xz:"application-x-xz", bz2:"application-x-bzip",
    rar:"application-x-rar", "7z":"application-x-7z-compressed",
    // media
    mp3:"audio-x-generic", wav:"audio-x-generic", flac:"audio-x-generic", ogg:"audio-x-generic",
    mp4:"video-x-generic", mkv:"video-x-generic", webm:"video-x-generic", mov:"video-x-generic"
};
function extIcon(name, isDir) {
    if (isDir) return "folder";
    var n = ("" + (name || "")).toLowerCase();
    var dot = n.lastIndexOf(".");
    if (dot <= 0) return "text-x-generic";        // no ext or dotfile
    return _EXT_ICON[n.substring(dot + 1)] || "text-x-generic";
}

// split a posix path into breadcrumb segments:
// "/var/www" -> [{label:"/",path:"/"},{label:"var",path:"/var"},{label:"www",path:"/var/www"}]
function pathCrumbs(path) {
    var p = ("" + (path || "/"));
    var abs = p.charAt(0) === "/";
    var parts = p.split("/").filter(function (s) { return s.length; });
    var out = abs ? [{ label: "/", path: "/" }] : [];
    var acc = abs ? "" : ".";
    parts.forEach(function (seg) {
        acc = acc + "/" + seg;
        out.push({ label: seg, path: acc });
    });
    return out;
}

// parent dir of a posix path: "/var/www/x" -> "/var/www"; "/" -> "/"
function parentPath(p) {
    p = ("" + (p || "/")).replace(/\/+$/, "");
    if (p === "" || p === "/") return "/";
    var i = p.lastIndexOf("/");
    return i <= 0 ? "/" : p.substring(0, i);
}

// basename: "/var/www/x.txt" -> "x.txt"
function baseName(p) {
    p = ("" + (p || "")).replace(/\/+$/, "");
    var i = p.lastIndexOf("/");
    return i < 0 ? p : p.substring(i + 1);
}

// join dir + name safely: ("/var/www","x") -> "/var/www/x"; ("/","x") -> "/x"
function joinPath(dir, name) {
    var d = ("" + (dir || "")).replace(/\/+$/, "");
    return d + "/" + name;
}

// epoch seconds -> short local datetime via Qt. qtObj is passed in by the caller to
// keep this a pure .pragma library. cb is Qt.formatDateTime; returns "" for 0.
function fmtMtime(epoch, qtObj) {
    var e = Number(epoch) || 0;
    if (e <= 0) return "";
    var d = new Date(e * 1000);
    return qtObj ? qtObj.formatDateTime(d, "yyyy-MM-dd HH:mm") : ("" + d);
}
