import SwiftUI

/// Inline log viewer with auto-follow (re-fetches on an interval and pins to the
/// bottom), the macOS analogue of the Linux build's auto-following log pane.
struct LogsView: View {
    let container: Container
    let onBack: () -> Void

    @EnvironmentObject var state: AppState
    @State private var text: String = "Loading logs…"
    @State private var follow = true
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(container.name).font(.headline).lineLimit(1)
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.switch).controlSize(.mini)
            }
            .padding(10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }
                .onChange(of: text) { _ in
                    if follow { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
        .onAppear { startFollowing() }
        .onDisappear { task?.cancel() }
        .onChange(of: follow) { on in
            if on { startFollowing() } else { task?.cancel() }
        }
    }

    private func startFollowing() {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                let fresh = await state.fetchLogs(container)
                if !Task.isCancelled { text = fresh.isEmpty ? "(no output)" : fresh }
                if !follow { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
