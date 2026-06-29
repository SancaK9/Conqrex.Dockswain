import SwiftUI

/// docker compose projects with up/down and a peek at the compose file.
struct ComposeView: View {
    let onBack: () -> Void
    @EnvironmentObject var state: AppState

    @State private var projects: [ComposeProject] = []
    @State private var status = "Loading…"
    @State private var busy: String?            // project name currently acting
    @State private var viewing: ComposeProject?
    @State private var fileText = ""
    @State private var confirmingDown: ComposeProject?

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "Compose", trailing: AnyView(
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            ), onBack: onBack)

            if let viewing {
                fileViewer(viewing)
            } else if projects.isEmpty {
                centered(status)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(projects) { p in projectRow(p) }
                    }.padding(10)
                }
            }
        }
        .task { await load() }
        .confirmationDialog("Bring \(confirmingDown?.name ?? "") down?",
                            isPresented: Binding(get: { confirmingDown != nil },
                                                 set: { if !$0 { confirmingDown = nil } })) {
            Button("Compose down", role: .destructive) {
                if let p = confirmingDown { act("down", p) }; confirmingDown = nil
            }
            Button("Cancel", role: .cancel) { confirmingDown = nil }
        } message: {
            Text("This stops and removes the project's containers (docker compose down).")
        }
    }

    private func projectRow(_ p: ComposeProject) -> some View {
        HStack(spacing: 8) {
            Circle().fill(p.isRunning ? .green : .gray).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 12, weight: .medium))
                Text(p.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if busy == p.name {
                ProgressView().controlSize(.small)
            } else {
                if !p.configFiles.isEmpty {
                    Button("up") { act("up", p) }.controlSize(.small)
                    Button("down") {
                        if state.confirmDestructive { confirmingDown = p } else { act("down", p) }
                    }.controlSize(.small)
                    Button { Task { await openFile(p) } } label: { Image(systemName: "doc.text") }
                        .buttonStyle(.borderless).help("View compose file")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func fileViewer(_ p: ComposeProject) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { viewing = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(p.configFiles.first ?? "").font(.caption).lineLimit(1)
                Spacer()
            }.padding(8)
            Divider()
            ScrollView {
                Text(fileText).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    private func act(_ action: String, _ p: ComposeProject) {
        guard let s = state.selectedServer else { return }
        busy = p.name
        Task {
            defer { busy = nil }
            do { try await state.makeBackend().composeAction(action, configFiles: p.configFiles, on: s); await load() }
            catch { status = error.localizedDescription }
        }
    }

    private func openFile(_ p: ComposeProject) async {
        guard let s = state.selectedServer, let f = p.configFiles.first else { return }
        fileText = (try? await state.makeBackend().readFile(f, on: s)) ?? "(could not read)"
        viewing = p
    }

    private func load() async {
        guard let s = state.selectedServer else { status = "No server"; return }
        do { projects = try await state.makeBackend().composeProjects(s); status = "No compose projects." }
        catch { status = error.localizedDescription; projects = [] }
    }

    private func centered(_ t: String) -> some View {
        VStack { Spacer(); Text(t).font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).padding(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
