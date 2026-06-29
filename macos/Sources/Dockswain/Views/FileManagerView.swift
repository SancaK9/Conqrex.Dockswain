import SwiftUI
import AppKit

/// SFTP file manager. Responsive like the Linux build: when the panel is wide it
/// shows both panes side by side (Local | Remote) with transfer arrows between;
/// when narrow it shows one pane with a Local/Remote toggle. Local listing is
/// native (FileManager); remote is over SSH; transfers reuse the warm master (scp).
struct FileManagerView: View {
    let onBack: () -> Void
    @EnvironmentObject var state: AppState

    enum Side: String, CaseIterable { case local = "Local", remote = "Remote" }
    @State private var side: Side = .remote          // active pane in narrow mode

    @State private var localPath = LocalFS.home()
    @State private var localEntries: [FileEntry] = []
    @State private var localSel: FileEntry?

    @State private var remotePath = "/"
    @State private var remoteEntries: [FileEntry] = []
    @State private var remoteSel: FileEntry?

    @State private var status = ""
    @State private var busy = false
    @State private var confirmDelete: (entry: FileEntry, side: Side)?

    private let wideThreshold: CGFloat = 640

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= wideThreshold
            VStack(spacing: 0) {
                FeatureHeader(title: "Files", trailing: AnyView(
                    Group {
                        if !wide {
                            Picker("", selection: $side) {
                                ForEach(Side.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                        }
                    }
                ), onBack: onBack)

                if wide { wideBody } else { narrowBody }

                if !status.isEmpty {
                    Divider()
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
        }
        .task { await loadRemoteHome(); reload(.local) }
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
                    .help("Upload selected → remote").disabled(localSel == nil || busy)
                Button { transfer(up: false) } label: { Image(systemName: "arrow.left") }
                    .help("Download selected → local").disabled(remoteSel == nil || busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .frame(width: 40)
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
                        .controlSize(.small).disabled(localSel == nil || busy)
                    Text("to \(remotePath)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Button { transfer(up: false) } label: { Label("Download → local", systemImage: "arrow.left.circle") }
                        .controlSize(.small).disabled(remoteSel == nil || busy)
                    Text("to \(localPath)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }.padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            pane(side)
        }
    }

    // MARK: - One pane

    private func pane(_ s: Side) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(s.rawValue).font(.caption.bold()).foregroundStyle(.secondary)
                Button { navigateUp(s) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).help("Up")
                Text(path(s)).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { newFolder(s) } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.borderless).help("New folder")
                Button { reload(s) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }.padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 1) { ForEach(entries(s)) { e in fileRow(e, side: s) } }.padding(6)
            }
        }
        .frame(maxWidth: .infinity)
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
            Button("Rename") { rename(e, side: s) }
            Button("Delete", role: .destructive) { confirmDelete = (e, s) }
        }
    }

    // MARK: - Per-side accessors

    private func path(_ s: Side) -> String { s == .local ? localPath : remotePath }
    private func entries(_ s: Side) -> [FileEntry] {
        (s == .local ? localEntries : remoteEntries).sorted { a, b in
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
        if let h = try? await state.makeBackend().sftpHome(srv) { remotePath = h }
        await loadRemote()
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

    private func transfer(up: Bool) {
        guard let srv = state.selectedServer else { return }
        busy = true; status = "Transferring…"
        Task {
            defer { busy = false }
            do {
                if up, let sel = localSel {
                    let src = (localPath as NSString).appendingPathComponent(sel.name)
                    let dst = (remotePath as NSString).appendingPathComponent(sel.name)
                    try await state.makeBackend().upload(local: src, remote: dst, recursive: sel.isDir, on: srv)
                    status = "Uploaded \(sel.name)"; await loadRemote()
                } else if !up, let sel = remoteSel {
                    let src = (remotePath as NSString).appendingPathComponent(sel.name)
                    let dst = (localPath as NSString).appendingPathComponent(sel.name)
                    try await state.makeBackend().download(remote: src, local: dst, recursive: sel.isDir, on: srv)
                    status = "Downloaded \(sel.name)"; reload(.local)
                }
            } catch { status = error.localizedDescription }
        }
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
