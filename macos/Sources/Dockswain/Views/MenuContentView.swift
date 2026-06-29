import SwiftUI
import AppKit

/// Root popup content. Swaps between the container list, a log view and settings
/// (instead of sheets, which are unreliable inside a MenuBarExtra window).
struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var panel: PanelController

    enum Screen: Equatable {
        case list
        case logs(Container)
        case settings
    }
    @State private var screen: Screen = .list

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .list:
                listScreen
            case .logs(let c):
                LogsView(container: c) { screen = .list }
            case .settings:
                SettingsView { screen = .list }
            }
        }
    }

    // MARK: - List screen

    private var listScreen: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
            if state.servers.isEmpty {
                Text("Dockswain").font(.headline)
            } else {
                Picker("", selection: Binding(
                    get: { state.selectedServerID },
                    set: { state.selectedServerID = $0 }
                )) {
                    ForEach(state.servers) { s in
                        Text(s.label.isEmpty ? s.target : s.label).tag(Optional(s.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            if state.isLoading {
                ProgressView().controlSize(.small)
            }
            Button { state.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
                .disabled(state.selectedServer == nil)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if state.servers.isEmpty {
            emptyState(title: "No servers yet",
                       subtitle: "Add a server in Settings to start managing Docker over SSH.")
        } else if !state.statusMessage.isEmpty && state.containers.isEmpty {
            emptyState(title: "Not connected", subtitle: state.statusMessage)
        } else if state.containers.isEmpty {
            emptyState(title: "No containers", subtitle: "This server has no containers.")
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(state.containers) { c in
                        ContainerRow(container: c,
                                     stat: state.statsByID[c.shortId],
                                     onLogs: { screen = .logs(c) })
                    }
                }
                .padding(8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let v = serverInfo {
                Text(v).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()

            // dock position: left edge / floating / right edge
            dockButton(.left, "sidebar.left", "Dock to left edge")
            dockButton(.floating, "macwindow", "Free-floating window")
            dockButton(.right, "sidebar.right", "Dock to right edge")

            Divider().frame(height: 14)

            Button { state.openSSHTerminal() } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless).help("Open SSH terminal")
            .disabled(state.selectedServer == nil)

            Button { screen = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")

            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Quit Dockswain")
        }
        .padding(10)
    }

    private func dockButton(_ d: PanelController.Dock, _ symbol: String, _ help: String) -> some View {
        Button { panel.setDock(d) } label: {
            Image(systemName: symbol)
                .foregroundStyle(panel.dock == d ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var serverInfo: String? {
        guard let s = state.selectedServer else { return nil }
        var parts = [s.target]
        if !state.serverVersion.isEmpty { parts.append("· Docker \(state.serverVersion)") }
        return parts.joined(separator: " ")
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "ferry").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
