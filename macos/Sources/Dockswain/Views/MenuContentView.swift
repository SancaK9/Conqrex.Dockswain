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
            if !state.servers.isEmpty { tabBar }
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
            Text(state.selectedServer.map { $0.label.isEmpty ? $0.target : $0.label } ?? "Dockswain")
                .font(.headline).lineLimit(1)
            Spacer()
            if state.isLoading { ProgressView().controlSize(.small) }
            Button { panel.togglePin() } label: {
                Image(systemName: panel.pinnedOpen ? "pin.fill" : "pin")
                    .foregroundStyle(panel.pinnedOpen ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(panel.pinnedOpen ? "Pinned open — click outside won't close it" : "Pin open (keep panel open when clicking elsewhere)")
            Button { state.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
                .disabled(state.selectedServer == nil)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
    }

    // MARK: - Tabs (one open server per tab)

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(state.sessions) { session in tabChip(session) }
                addTabMenu
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
        }
    }

    private func tabChip(_ session: ServerSession) -> some View {
        let isActive = state.activeID == session.id
        let label = session.server.label.isEmpty ? session.server.target : session.server.label
        return HStack(spacing: 4) {
            Circle().fill(session.containers.contains { $0.isRunning } ? .green : .gray)
                .frame(width: 6, height: 6)
            Text(label).font(.caption).lineLimit(1)
            if !session.badge.isEmpty {
                Text(session.badge).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Button { state.closeTab(session.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }.buttonStyle(.borderless).help("Close tab")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isActive ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(isActive ? Color.accentColor : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { state.setActive(session.id) }
    }

    @ViewBuilder
    private var addTabMenu: some View {
        if state.unopenedServers.isEmpty {
            EmptyView()
        } else {
            Menu {
                ForEach(state.unopenedServers) { s in
                    Button(s.label.isEmpty ? s.target : s.label) { state.open(s) }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Open another server in a new tab")
        }
    }

    private var toolbar: some View {
        HStack(alignment: .top, spacing: 6) {
            toolButton("rectangle.3.group", "Compose", "Compose projects") { screen = .compose }
            toolButton("internaldrive", "Disk", "Disk usage & cleanup") { screen = .disk }
            toolButton("folder", "Files", "File manager (SFTP)") { screen = .files }
            toolButton("globe", "Nginx", "Nginx sites & SSL") { screen = .nginx }
            Spacer()
            toolButton("point.3.connected.trianglepath.dotted", "Group",
                       "Group by network", active: state.groupByNetwork) { state.groupByNetwork.toggle() }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
        .disabled(state.selectedServer == nil)
    }

    /// Icon + small caption label so each tool is self-explanatory.
    private func toolButton(_ symbol: String, _ title: String, _ help: String,
                            active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(title).font(.system(size: 9))
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .frame(width: 52)
        }
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
