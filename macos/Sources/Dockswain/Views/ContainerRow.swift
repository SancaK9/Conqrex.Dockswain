import SwiftUI

/// One container row: state dot, name/image, and hover-revealed actions
/// (start/stop, restart, logs, exec, remove) — the macOS take on ContainerDelegate.qml.
struct ContainerRow: View {
    let container: Container
    let stat: ContainerStat?
    let onLogs: () -> Void

    @EnvironmentObject var state: AppState
    @State private var hovering = false
    @State private var confirmingRemove = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(container.image).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)

            if let stat, container.isRunning {
                Text(stat.cpu).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            actions
                .opacity(hovering ? 1 : 0.25)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
        .confirmationDialog("Remove \(container.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { state.perform("rm", on: container) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This force-removes the container (docker rm -f).")
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if container.isRunning {
                iconButton("stop.fill", "Stop") { state.perform("stop", on: container) }
            } else {
                iconButton("play.fill", "Start") { state.perform("start", on: container) }
            }
            iconButton("arrow.clockwise", "Restart") { state.perform("restart", on: container) }
            iconButton("doc.plaintext", "Logs", action: onLogs)
            iconButton("terminal", "Exec shell") { state.openExecTerminal(container) }
            iconButton("trash", "Remove") { confirmingRemove = true }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private var stateColor: Color {
        switch container.state.lowercased() {
        case "running": return .green
        case "paused": return .yellow
        case "exited", "dead": return .red
        case "created", "restarting": return .orange
        default: return .gray
        }
    }
}
