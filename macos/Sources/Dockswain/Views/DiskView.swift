import SwiftUI

/// Docker data-root disk usage, `docker system df` breakdown, safe one-click
/// cleanups, and per-container log sizes with truncate.
struct DiskView: View {
    let onBack: () -> Void
    @EnvironmentObject var state: AppState

    @State private var info: DiskInfo?
    @State private var df: [DfEntry] = []
    @State private var logs: [ContainerLogFile] = []
    @State private var logsTotal: Int64 = 0
    @State private var status = "Loading…"
    @State private var busy = false
    @State private var confirm: (title: String, action: () -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "Disk & cleanup", trailing: AnyView(
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            ), onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let info { diskBar(info) } else { Text(status).font(.caption).foregroundStyle(.secondary) }

                    if !df.isEmpty {
                        sectionTitle("docker system df")
                        ForEach(df) { e in dfRow(e) }
                        cleanupButtons
                    }

                    if !logs.isEmpty {
                        sectionTitle("Container logs · \(Bytes.human(logsTotal)) total")
                        ForEach(logs) { l in logRow(l) }
                    }
                }
                .padding(12)
            }
        }
        .task { await load() }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(
            get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Confirm", role: .destructive) { confirm?.action(); confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        }
    }

    private func diskBar(_ i: DiskInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let frac = i.size > 0 ? Double(i.used) / Double(i.size) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(frac > 0.9 ? Color.red : frac > 0.75 ? Color.orange : Color.accentColor)
                        .frame(width: geo.size.width * frac)
                }
            }.frame(height: 10)
            Text("\(Bytes.human(i.used)) used · \(Bytes.human(i.avail)) free · \(Bytes.human(i.size)) total (\(i.usePct))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func dfRow(_ e: DfEntry) -> some View {
        HStack {
            Text(e.type).font(.caption).frame(width: 90, alignment: .leading)
            Text(e.size).font(.caption.monospaced())
            Spacer()
            Text("reclaimable \(e.reclaimable)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var cleanupButtons: some View {
        HStack {
            cleanup("Build cache", "builder")
            cleanup("Dangling images", "images")
            cleanup("Stopped", "containers")
        }.padding(.top, 4)
    }

    private func cleanup(_ label: String, _ what: String) -> some View {
        Button(label) {
            confirm = ("Prune \(label.lowercased())?", { runPrune(what) })
        }.controlSize(.small).disabled(busy)
    }

    private func logRow(_ l: ContainerLogFile) -> some View {
        HStack {
            Text(l.name).font(.caption).lineLimit(1)
            Spacer()
            Text(l.size >= 0 ? Bytes.human(l.size) : (l.size == -2 ? "no json-log" : "unreadable"))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
            if l.size > 0 {
                Button { confirm = ("Truncate \(l.name) log (\(Bytes.human(l.size)))?", { truncate(l) }) } label: {
                    Image(systemName: "scissors")
                }.buttonStyle(.borderless).help("Truncate to 0")
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func runPrune(_ what: String) {
        guard let s = state.selectedServer else { return }
        busy = true
        Task { defer { busy = false }
            _ = try? await state.makeBackend().prune(what, on: s); await load() }
    }
    private func truncate(_ l: ContainerLogFile) {
        guard let s = state.selectedServer else { return }
        Task { try? await state.makeBackend().truncateLog(container: l.id.prefix(12).description, on: s); await load() }
    }

    private func load() async {
        guard let s = state.selectedServer else { status = "No server"; return }
        let b = state.makeBackend()
        do {
            let (i, d) = try await b.disk(s); info = i; df = d
        } catch { status = error.localizedDescription }
        if let r = try? await b.containerLogFiles(s) { logs = r.logs; logsTotal = r.total }
    }
}
