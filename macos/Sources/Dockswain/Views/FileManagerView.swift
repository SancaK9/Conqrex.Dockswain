import SwiftUI
import AppKit

/// SFTP file manager. Responsive like the Linux build: when the panel is wide it
/// shows both panes side by side (Local | Remote) with transfer arrows between;
/// when narrow it shows one pane with a Local/Remote toggle. Local listing is
/// native (FileManager); remote is over SSH; transfers reuse the warm master (scp).
struct FileManagerView: View {
    let onBack: () -> Void
    @EnvironmentObject var state: AppState
    @EnvironmentObject var xfer: TransferManager
    @EnvironmentObject var editor: ExternalEditManager

    enum Side: String, CaseIterable { case local = "Local", remote = "Remote" }
    @State private var side: Side = .remote          // active pane in narrow mode

    /// rsync sync mode for queued transfers (empty = plain overwrite copy).
    enum SyncMode: String, CaseIterable, Identifiable {
        case overwrite = "", newer = "newer", size = "size", skip = "new-only", update = "existing"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overwrite: return "Overwrite"
            case .newer:     return "Newer only"
            case .size:      return "If size differs"
            case .skip:      return "Skip existing"
            case .update:    return "Update existing"
            }
        }
    }
    @State private var syncMode: SyncMode = .overwrite
    @State private var lastFinished = 0

    @State private var localPath = LocalFS.home()
    @State private var localEntries: [FileEntry] = []
    @State private var localSel: FileEntry?

    @State private var remotePath = "/"
    @State private var remoteEntries: [FileEntry] = []
    @State private var remoteSel: FileEntry?
    @State private var remoteHome = "/root"

    // Bookmarked folders per side (the Linux PlacesStrip favorites), persisted.
    @State private var localFavs: [String] = UserDefaults.standard.stringArray(forKey: "favPaths.local") ?? []
    @State private var remoteFavs: [String] = UserDefaults.standard.stringArray(forKey: "favPaths.remote") ?? []

    @State private var status = ""
    @State private var busy = false
    @State private var confirmDelete: (entry: FileEntry, side: Side)?

    private let wideThreshold: CGFloat = 640

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= wideThreshold
            VStack(spacing: 0) {
                FeatureHeader(title: "Files", trailing: AnyView(
                    HStack(spacing: 8) {
                        if !wide {
                            Picker("", selection: $side) {
                                ForEach(Side.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                        }
                        Button { state.showHiddenFiles.toggle() } label: {
                            Image(systemName: state.showHiddenFiles ? "eye" : "eye.slash")
                        }.buttonStyle(.borderless)
                        .help(state.showHiddenFiles ? "Hide dotfiles" : "Show hidden files (dotfiles)")
                    }
                ), onBack: onBack)

                if wide { wideBody } else { narrowBody }

                if !editor.sessions.isEmpty { editStrip }
                if !xfer.transfers.isEmpty { transferQueue }

                if !status.isEmpty {
                    Divider()
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
        }
        .task {
            if let m = SyncMode(rawValue: state.syncDefaultFilter) { syncMode = m }
            if !state.defaultLocalDir.isEmpty, FileManager.default.fileExists(atPath: state.defaultLocalDir) {
                localPath = state.defaultLocalDir
            }
            await loadRemoteHome(); reload(.local)
        }
        .onChange(of: xfer.transfers) { _ in
            // When a transfer finishes, refresh both panes so the new file shows up.
            let finished = xfer.transfers.filter { $0.isFinished }.count
            if finished > lastFinished { reload(.local); Task { await loadRemote() } }
            lastFinished = finished
        }
        .confirmationDialog("Delete \(confirmDelete?.entry.name ?? "")?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let c = confirmDelete { delete(c.entry, side: c.side) }; confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
    }

    // MARK: - Layouts

    private var wideBody: some View {
        HStack(spacing: 0) {
            pane(.local)
            VStack(spacing: 10) {
                Spacer()
                Button { transfer(up: true) } label: { Image(systemName: "arrow.right") }
                    .help("Upload selected → remote").disabled(localSel == nil)
                Button { transfer(up: false) } label: { Image(systemName: "arrow.left") }
                    .help("Download selected → local").disabled(remoteSel == nil)
                syncMenu
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .frame(width: 44)
            .background(Color.primary.opacity(0.03))
            Divider()
            pane(.remote)
        }
    }

    private var narrowBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if side == .local {
                    Button { transfer(up: true) } label: { Label("Upload → remote", systemImage: "arrow.right.circle") }
                        .controlSize(.small).disabled(localSel == nil)
                    Text("to \(remotePath)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Button { transfer(up: false) } label: { Label("Download → local", systemImage: "arrow.left.circle") }
                        .controlSize(.small).disabled(remoteSel == nil)
                    Text("to \(localPath)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                syncMenu
            }.padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            pane(side)
        }
    }

    /// Compact rsync sync-mode chooser (Linux build's SyncBar). Only affects rsync;
    /// with scp the copy is a plain overwrite regardless.
    private var syncMenu: some View {
        Menu {
            ForEach(SyncMode.allCases) { m in
                Button { syncMode = m } label: {
                    if syncMode == m { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(syncMode == .overwrite ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Sync mode: \(syncMode.label)")
    }

    // MARK: - External edit sessions

    private var editStrip: some View {
        VStack(spacing: 3) {
            Divider()
            ForEach(editor.sessions) { sess in
                HStack(spacing: 8) {
                    Image(systemName: "pencil.and.outline").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sess.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(editStatus(sess)).font(.caption2)
                            .foregroundStyle(sess.error == nil ? Color.secondary : Color.red).lineLimit(1)
                    }
                    Spacer()
                    Button("Stop") { editor.stop(sess.id) }.controlSize(.mini)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
            }
        }
        .padding(.bottom, 3)
        .background(Color.primary.opacity(0.03))
    }

    private func editStatus(_ s: ExternalEditManager.Session) -> String {
        if let e = s.error { return "save failed: \(e)" }
        if let at = s.savedAt {
            let f = DateFormatter()
            f.dateFormat = state.timeFormat24h ? "HH:mm:ss" : "h:mm:ss a"
            return "auto-saving · last saved \(f.string(from: at))"
        }
        return "editing externally · auto-saves on change"
    }

    // MARK: - Transfer queue

    private var transferQueue: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("Transfers").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if xfer.transfers.contains(where: { $0.isFinished }) {
                    Button("Clear done") { xfer.clearFinished() }
                        .controlSize(.mini).buttonStyle(.borderless)
                }
            }.padding(.horizontal, 8).padding(.top, 5)
            ScrollView {
                VStack(spacing: 3) { ForEach(xfer.transfers) { transferRow($0) } }
                    .padding(.horizontal, 8).padding(.vertical, 5)
            }
            .frame(maxHeight: 132)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func transferRow(_ t: Transfer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: t.up ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(statusText(t)).font(.caption2.monospaced())
                        .foregroundStyle(statusColor(t))
                }
                if t.state == .running {
                    if t.indeterminate { ProgressView().progressViewStyle(.linear) }
                    else { ProgressView(value: min(max(t.pct, 0), 100), total: 100).progressViewStyle(.linear) }
                }
            }
            if t.state == .running {
                Button { xfer.cancel(t.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel")
            } else {
                Button { xfer.clear(t.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from list")
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
    }

    private func statusText(_ t: Transfer) -> String {
        switch t.state {
        case .running:   return t.indeterminate ? (t.rate.isEmpty ? "…" : t.rate)
                                                 : "\(Int(t.pct))%\(t.rate.isEmpty ? "" : " · \(t.rate)")"
        case .done:      return "done"
        case .cancelled: return "cancelled"
        case .error:     return t.detail.isEmpty ? "failed" : t.detail
        }
    }
    private func statusColor(_ t: Transfer) -> Color {
        switch t.state {
        case .running:   return .secondary
        case .done:      return .green
        case .cancelled: return .orange
        case .error:     return .red
        }
    }

    // MARK: - One pane

    private func pane(_ s: Side) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(s.rawValue).font(.caption.bold()).foregroundStyle(.secondary)
                Button { navigateUp(s) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).help("Up")
                breadcrumb(s).frame(maxWidth: .infinity, alignment: .leading)
                Button { toggleFav(s) } label: {
                    Image(systemName: favs(s).contains(path(s)) ? "star.fill" : "star")
                        .foregroundStyle(favs(s).contains(path(s)) ? Color.yellow : Color.secondary)
                }.buttonStyle(.borderless).help("Bookmark this folder")
                Button { newFolder(s) } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.borderless).help("New folder")
                Button { reload(s) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }.padding(.horizontal, 8).padding(.vertical, 6)
            placesStrip(s)
            Divider()
            ScrollView {
                LazyVStack(spacing: 1) { ForEach(entries(s)) { e in fileRow(e, side: s) } }.padding(6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Clickable path segments (Linux build's BreadcrumbBar). Tap any ancestor to
    /// jump straight there instead of pressing Up repeatedly.
    private func breadcrumb(_ s: Side) -> some View {
        let segs = crumbs(for: path(s))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(segs, id: \.path) { seg in
                    if seg.path != "/" {
                        Image(systemName: "chevron.compact.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    Button { navigate(to: seg.path, side: s) } label: {
                        Text(seg.name).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(seg.path == path(s) ? Color.primary : Color.secondary)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    /// Break a POSIX path into (name, absolute-path) crumbs, root first.
    private func crumbs(for p: String) -> [(name: String, path: String)] {
        var out: [(String, String)] = [(name: "/", path: "/")]
        var acc = ""
        for part in p.split(separator: "/") {
            acc += "/" + part
            out.append((name: String(part), path: acc))
        }
        return out
    }

    /// Standard places (Home, /) plus this side's bookmarked folders — the Linux
    /// build's PlacesStrip. Tap a chip to jump there; bookmarks persist per side.
    private func placesStrip(_ s: Side) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                placeChip("Home", "house", path: homePath(s), side: s)
                placeChip("/", "externaldrive", path: "/", side: s)
                ForEach(favs(s), id: \.self) { p in
                    placeChip((p as NSString).lastPathComponent.isEmpty ? p : (p as NSString).lastPathComponent,
                              "star.fill", path: p, side: s, removable: true)
                }
            }.padding(.horizontal, 8).padding(.bottom, 5)
        }
    }

    private func placeChip(_ label: String, _ icon: String, path p: String,
                           side s: Side, removable: Bool = false) -> some View {
        let active = path(s) == p
        return HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(label).font(.system(size: 10)).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(active ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { navigate(to: p, side: s) }
        .help(p)
        .contextMenu { if removable { Button("Remove bookmark") { removeFav(p, side: s) } } }
    }

    private func fileRow(_ e: FileEntry, side s: Side) -> some View {
        let selected = sel(s)?.id == e.id
        return HStack(spacing: 8) {
            Image(systemName: e.isDir ? "folder.fill" : (e.type == "link" ? "link" : "doc"))
                .foregroundStyle(e.isDir ? Color.accentColor : .secondary).frame(width: 16)
            Text(e.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            if !e.isDir { Text(Bytes.human(e.size)).font(.caption2.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { setSel(e, side: s) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { openEntry(e, side: s) })
        .contextMenu {
            if s == .remote && !e.isDir {
                Button("Open in editor") { openExternally(e) }
            }
            Button("Rename") { rename(e, side: s) }
            Button("Delete", role: .destructive) { confirmDelete = (e, s) }
        }
    }

    /// Pull the remote file to a temp copy, open it in the system text editor, and
    /// auto-save it back to the server on every change (Linux build's `edit`).
    private func openExternally(_ e: FileEntry) {
        guard let srv = state.selectedServer else { return }
        let p = (remotePath as NSString).appendingPathComponent(e.name)
        Task { await editor.open(remotePath: p, name: e.name, app: state.editorApp,
                                 backend: state.makeBackend(), server: srv) }
    }

    // MARK: - Per-side accessors

    private func path(_ s: Side) -> String { s == .local ? localPath : remotePath }
    private func entries(_ s: Side) -> [FileEntry] {
        (s == .local ? localEntries : remoteEntries)
            .filter { state.showHiddenFiles || !$0.name.hasPrefix(".") }
            .sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }
    private func sel(_ s: Side) -> FileEntry? { s == .local ? localSel : remoteSel }
    private func setSel(_ e: FileEntry, side s: Side) { if s == .local { localSel = e } else { remoteSel = e } }

    // MARK: - Navigation

    private func openEntry(_ e: FileEntry, side s: Side) {
        guard e.isDir else { return }
        let next = (path(s) as NSString).appendingPathComponent(e.name)
        if s == .local { localPath = next; localSel = nil; reload(.local) }
        else { remotePath = next; remoteSel = nil; Task { await loadRemote() } }
    }
    private func navigateUp(_ s: Side) {
        let parent = (path(s) as NSString).deletingLastPathComponent
        let p = parent.isEmpty ? "/" : parent
        if s == .local { localPath = p; localSel = nil; reload(.local) }
        else { remotePath = p; remoteSel = nil; Task { await loadRemote() } }
    }
    private func reload(_ s: Side) { if s == .local { localEntries = LocalFS.list(localPath) } else { Task { await loadRemote() } } }

    private func loadRemoteHome() async {
        guard let srv = state.selectedServer else { status = "No server"; return }
        if let h = try? await state.makeBackend().sftpHome(srv) { remotePath = h; remoteHome = h }
        await loadRemote()
    }

    // MARK: - Places / bookmarks

    private func homePath(_ s: Side) -> String { s == .local ? LocalFS.home() : remoteHome }
    private func favs(_ s: Side) -> [String] { s == .local ? localFavs : remoteFavs }

    private func navigate(to p: String, side s: Side) {
        if s == .local { localPath = p; localSel = nil; reload(.local) }
        else { remotePath = p; remoteSel = nil; Task { await loadRemote() } }
    }
    private func toggleFav(_ s: Side) {
        let p = path(s)
        if favs(s).contains(p) { removeFav(p, side: s) }
        else { setFavs(favs(s) + [p], side: s) }
    }
    private func removeFav(_ p: String, side s: Side) { setFavs(favs(s).filter { $0 != p }, side: s) }
    private func setFavs(_ list: [String], side s: Side) {
        if s == .local { localFavs = list; UserDefaults.standard.set(list, forKey: "favPaths.local") }
        else { remoteFavs = list; UserDefaults.standard.set(list, forKey: "favPaths.remote") }
    }
    private func loadRemote() async {
        guard let srv = state.selectedServer else { return }
        busy = true; defer { busy = false }
        do { remoteEntries = try await state.makeBackend().sftpList(remotePath, on: srv) }
        catch { status = error.localizedDescription; remoteEntries = [] }
    }

    // MARK: - Mutations

    private func newFolder(_ s: Side) {
        guard let name = prompt("New folder name:"), !name.isEmpty else { return }
        let p = (path(s) as NSString).appendingPathComponent(name)
        Task {
            do {
                if s == .local { try LocalFS.mkdir(p); reload(.local) }
                else { try await state.makeBackend().sftpMkdir(p, on: state.selectedServer!); await loadRemote() }
            } catch { status = error.localizedDescription }
        }
    }
    private func rename(_ e: FileEntry, side s: Side) {
        guard let name = prompt("Rename \(e.name) to:", default: e.name), !name.isEmpty else { return }
        let from = (path(s) as NSString).appendingPathComponent(e.name)
        let to = (path(s) as NSString).appendingPathComponent(name)
        Task {
            do {
                if s == .local { try LocalFS.rename(from, to: to); reload(.local) }
                else { try await state.makeBackend().sftpRename(from, to: to, on: state.selectedServer!); await loadRemote() }
            } catch { status = error.localizedDescription }
        }
    }
    private func delete(_ e: FileEntry, side s: Side) {
        let p = (path(s) as NSString).appendingPathComponent(e.name)
        Task {
            do {
                if s == .local { try LocalFS.delete(p); reload(.local) }
                else { try await state.makeBackend().sftpDelete(p, recursive: e.isDir, on: state.selectedServer!); await loadRemote() }
            } catch { status = error.localizedDescription }
        }
    }

    /// Queue a transfer of the selected entry. Runs in the background (streamed
    /// progress, cancellable) via the shared TransferManager — non-blocking, so
    /// several can run at once and the panes stay usable.
    private func transfer(up: Bool) {
        guard let srv = state.selectedServer else { return }
        let sel = up ? localSel : remoteSel
        guard let sel else { return }
        let src: String, dst: String
        if up {
            src = (localPath as NSString).appendingPathComponent(sel.name)
            dst = (remotePath as NSString).appendingPathComponent(sel.name)
        } else {
            src = (remotePath as NSString).appendingPathComponent(sel.name)
            dst = (localPath as NSString).appendingPathComponent(sel.name)
        }
        xfer.start(up: up, name: sel.name, src: src, dst: dst, recursive: sel.isDir,
                   syncMode: syncMode.rawValue, backend: state.makeBackend(), server: srv)
    }

    private func prompt(_ message: String, default def: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = def
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
