import SwiftUI
import AppKit

/// SFTP file manager. The panel is narrow, so it shows one pane at a time (Local /
/// Remote) with a transfer button that moves the selected item between the two
/// current paths. Local listing is native (FileManager); remote is over SSH; the
/// transfer reuses the warm SSH master (scp), so no second password.
struct FileManagerView: View {
    let onBack: () -> Void
    @EnvironmentObject var state: AppState

    enum Side: String, CaseIterable { case local = "Local", remote = "Remote" }
    @State private var side: Side = .remote

    @State private var localPath = LocalFS.home()
    @State private var localEntries: [FileEntry] = []
    @State private var localSel: FileEntry?

    @State private var remotePath = "/"
    @State private var remoteEntries: [FileEntry] = []
    @State private var remoteSel: FileEntry?
    @State private var remoteReady = false

    @State private var status = ""
    @State private var busy = false
    @State private var confirmDelete: FileEntry?

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "Files", trailing: AnyView(
                Picker("", selection: $side) {
                    ForEach(Side.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            ), onBack: onBack)

            pathBar
            transferBar
            Divider()
            list
            if !status.isEmpty {
                Divider()
                Text(status).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
        .task { await loadRemoteHome(); reloadLocal() }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let e = confirmDelete { delete(e) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
    }

    private var curPath: String { side == .local ? localPath : remotePath }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button { up() } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).help("Up")
            Text(curPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { newFolder() } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.borderless).help("New folder")
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            if busy { ProgressView().controlSize(.small) }
        }.padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var transferBar: some View {
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
        }.padding(.horizontal, 8).padding(.bottom, 6)
    }

    private var entries: [FileEntry] {
        let e = side == .local ? localEntries : remoteEntries
        return e.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(entries) { e in fileRow(e) }
            }.padding(6)
        }
    }

    private func fileRow(_ e: FileEntry) -> some View {
        let selected = (side == .local ? localSel : remoteSel)?.id == e.id
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
        .onTapGesture { select(e) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(e) })
        .contextMenu {
            Button("Rename") { rename(e) }
            Button("Delete", role: .destructive) { confirmDelete = e }
        }
    }

    // MARK: - selection / navigation

    private func select(_ e: FileEntry) {
        if side == .local { localSel = e } else { remoteSel = e }
    }
    private func open(_ e: FileEntry) {
        guard e.isDir else { return }
        let base = curPath
        let next = (base as NSString).appendingPathComponent(e.name)
        if side == .local { localPath = next; localSel = nil; reloadLocal() }
        else { remotePath = next; remoteSel = nil; Task { await loadRemote() } }
    }
    private func up() {
        let parent = (curPath as NSString).deletingLastPathComponent
        let p = parent.isEmpty ? "/" : parent
        if side == .local { localPath = p; localSel = nil; reloadLocal() }
        else { remotePath = p; remoteSel = nil; Task { await loadRemote() } }
    }
    private func reload() { if side == .local { reloadLocal() } else { Task { await loadRemote() } } }

    // MARK: - loads

    private func reloadLocal() { localEntries = LocalFS.list(localPath) }
    private func loadRemoteHome() async {
        guard let s = state.selectedServer else { status = "No server"; return }
        if let h = try? await state.makeBackend().sftpHome(s) { remotePath = h; remoteReady = true }
        await loadRemote()
    }
    private func loadRemote() async {
        guard let s = state.selectedServer else { return }
        busy = true; defer { busy = false }
        do { remoteEntries = try await state.makeBackend().sftpList(remotePath, on: s) }
        catch { status = error.localizedDescription; remoteEntries = [] }
    }

    // MARK: - mutations

    private func newFolder() {
        guard let name = prompt("New folder name:") , !name.isEmpty else { return }
        let path = (curPath as NSString).appendingPathComponent(name)
        Task {
            do {
                if side == .local { try LocalFS.mkdir(path); reloadLocal() }
                else { try await state.makeBackend().sftpMkdir(path, on: state.selectedServer!); await loadRemote() }
            } catch { status = error.localizedDescription }
        }
    }
    private func rename(_ e: FileEntry) {
        guard let name = prompt("Rename \(e.name) to:", default: e.name), !name.isEmpty else { return }
        let from = (curPath as NSString).appendingPathComponent(e.name)
        let to = (curPath as NSString).appendingPathComponent(name)
        Task {
            do {
                if side == .local { try LocalFS.rename(from, to: to); reloadLocal() }
                else { try await state.makeBackend().sftpRename(from, to: to, on: state.selectedServer!); await loadRemote() }
            } catch { status = error.localizedDescription }
        }
    }
    private func delete(_ e: FileEntry) {
        let path = (curPath as NSString).appendingPathComponent(e.name)
        Task {
            do {
                if side == .local { try LocalFS.delete(path); reloadLocal() }
                else { try await state.makeBackend().sftpDelete(path, recursive: e.isDir, on: state.selectedServer!); await loadRemote() }
            } catch { status = error.localizedDescription }
        }
    }

    private func transfer(up: Bool) {
        guard let s = state.selectedServer else { return }
        busy = true; status = "Transferring…"
        Task {
            defer { busy = false }
            do {
                if up, let sel = localSel {
                    let src = (localPath as NSString).appendingPathComponent(sel.name)
                    let dst = (remotePath as NSString).appendingPathComponent(sel.name)
                    try await state.makeBackend().upload(local: src, remote: dst, recursive: sel.isDir, on: s)
                    status = "Uploaded \(sel.name)"; await loadRemote()
                } else if !up, let sel = remoteSel {
                    let src = (remotePath as NSString).appendingPathComponent(sel.name)
                    let dst = (localPath as NSString).appendingPathComponent(sel.name)
                    try await state.makeBackend().download(remote: src, local: dst, recursive: sel.isDir, on: s)
                    status = "Downloaded \(sel.name)"; reloadLocal()
                }
            } catch { status = error.localizedDescription }
        }
    }

    /// Simple modal text prompt (NSAlert with an input field).
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
