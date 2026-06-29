import SwiftUI
import AppKit

/// Root popup content. Swaps between the container list and the feature screens
/// (instead of sheets, which are unreliable inside a MenuBarExtra window).
struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var panel: PanelController

    enum Screen: Equatable {
        case list
        case logs(Container)
        case settings
        case compose
        case disk
        case files
        case nginx
        case certbot
    }
    @State private var screen: Screen = .list

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .list:           listScreen
            case .logs(let c):    LogsView(container: c) { screen = .list }
            case .settings:       SettingsView { screen = .list }
            case .compose:        ComposeView { screen = .list }
            case .disk:           DiskView { screen = .list }
            case .files:          FileManagerView { screen = .list }
            case .nginx:          NginxView(openCertbot: { screen = .certbot }) { screen = .list }
            case .certbot:        CertbotView { screen = .nginx }
            }
        }
    }

    // MARK: - List screen

    private var listScreen: some View {
        VStack(spacing: 0) {
            header
            toolbar
            if !state.servers.isEmpty && state.selectedServer != nil { filterBar }
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
            if state.isLoading { ProgressView().controlSize(.small) }
            Button { state.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
                .disabled(state.selectedServer == nil)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            toolButton("rectangle.3.group", "Compose projects") { screen = .compose }
            toolButton("internaldrive", "Disk usage & cleanup") { screen = .disk }
            toolButton("folder", "File manager (SFTP)") { screen = .files }
            toolButton("globe", "Nginx sites") { screen = .nginx }
            Spacer()
            Button { state.groupByNetwork.toggle() } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(state.groupByNetwork ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.borderless).help("Group by network")
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
        .disabled(state.selectedServer == nil)
    }

    private func toolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless).help(help)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Filter", text: $state.searchText).textFieldStyle(.plain).font(.caption)
            if !state.searchText.isEmpty {
                Button { state.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Toggle("Running", isOn: $state.runningOnly).toggleStyle(.checkbox).font(.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
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
                LazyVStack(spacing: 4, pinnedViews: [.sectionHeaders]) {
                    if state.groupByNetwork {
                        ForEach(state.networkGroups, id: \.network) { group in
                            Section {
                                ForEach(group.items) { row($0) }
                            } header: {
                                HStack {
                                    Text(group.network).font(.caption.bold()).foregroundStyle(.secondary)
                                    Text("\(group.items.count)").font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.bar)
                            }
                        }
                    } else {
                        ForEach(state.displayedContainers) { row($0) }
                    }
                }
                .padding(8)
            }
        }
    }

    private func row(_ c: Container) -> some View {
        ContainerRow(container: c, stat: state.statsByID[c.shortId], onLogs: { screen = .logs(c) })
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let v = serverInfo {
                Text(v).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if state.hiddenCount > 0 {
                Text("· \(state.hiddenCount) hidden").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()

            dockButton(.left, "sidebar.left", "Dock to left edge")
            dockButton(.floating, "macwindow", "Free-floating window")
            dockButton(.right, "sidebar.right", "Dock to right edge")
            Divider().frame(height: 14)

            Button { state.openSSHTerminal() } label: { Image(systemName: "terminal") }
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
        .buttonStyle(.borderless).help(help)
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

/// Reusable back-header used by the feature screens.
struct FeatureHeader: View {
    let title: String
    var trailing: AnyView? = nil
    let onBack: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            Text(title).font(.headline)
            Spacer()
            if let trailing { trailing }
        }
        .padding(10)
        Divider()
    }
}
