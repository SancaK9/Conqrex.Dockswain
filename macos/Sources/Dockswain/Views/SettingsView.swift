import SwiftUI

/// Settings screen: manage servers, the docker command, and the refresh interval.
/// Passwords are written straight to the Keychain and never kept in the Server struct.
struct SettingsView: View {
    let onBack: () -> Void
    @EnvironmentObject var state: AppState

    @State private var editing: Server?          // nil = list view
    @State private var isNew = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { editing == nil ? onBack() : (editing = nil) }) {
                    Image(systemName: "chevron.left")
                }.buttonStyle(.borderless)
                Text(editing == nil ? "Settings" : (isNew ? "Add server" : "Edit server"))
                    .font(.headline)
                Spacer()
                if editing == nil {
                    Button { startAdd() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Add server")
                }
            }
            .padding(10)
            Divider()

            if let server = editing {
                ServerForm(server: server, isNew: isNew,
                           onSave: { save($0) },
                           onCancel: { editing = nil })
            } else {
                listBody
            }
        }
    }

    private var listBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Servers
                Text("SERVERS").font(.caption).foregroundStyle(.secondary)
                if state.servers.isEmpty {
                    Text("No servers. Use + to add one, or import from ~/.ssh/config below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(state.servers) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.label.isEmpty ? s.target : s.label).font(.system(size: 12, weight: .medium))
                            Text("\(s.target):\(s.port) · \(s.auth.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { startEdit(s) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) { state.removeServer(s) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }

                Button {
                    state.importFromSSHConfig()
                } label: {
                    Label("Import from ~/.ssh/config", systemImage: "square.and.arrow.down")
                }.buttonStyle(.borderless)

                Divider().padding(.vertical, 4)

                // General
                Text("GENERAL").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Docker command")
                    Spacer()
                    TextField("docker", text: $state.dockerCmd).frame(width: 140)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Refresh every")
                    Spacer()
                    Stepper("\(Int(state.refreshInterval))s", value: $state.refreshInterval, in: 2...60, step: 1)
                        .frame(width: 110)
                }
                Toggle("Show live CPU/memory stats (slower)", isOn: $state.statsEnabled)
                Toggle("Group containers by network", isOn: $state.groupByNetwork)
                HStack {
                    Text("Toggle shortcut")
                    Spacer()
                    ShortcutRecorder()
                }
                HStack {
                    Text("Nginx directory")
                    Spacer()
                    TextField("/etc/nginx", text: $state.nginxDir).frame(width: 160)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(12)
        }
    }

    private func startAdd() {
        editing = Server(label: "", user: "", host: "", port: 22, auth: .key, keyPath: "")
        isNew = true
    }

    private func startEdit(_ s: Server) {
        editing = s
        isNew = false
    }

    private func save(_ pair: (Server, String?)) {
        let (server, password) = pair
        if isNew { state.addServer(server) } else { state.updateServer(server) }
        if server.auth == .password, let password, !password.isEmpty {
            Keychain.set(password, account: server.secretAccount)
        }
        editing = nil
    }
}

/// Add/edit form for one server, with an inline "Test connection".
private struct ServerForm: View {
    @State var server: Server
    let isNew: Bool
    let onSave: ((Server, String?)) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var state: AppState
    @State private var password: String = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                field("Label", text: $server.label, placeholder: "My server")
                field("User", text: $server.user, placeholder: "root")
                field("Host", text: $server.host, placeholder: "example.com or 10.0.0.5")
                HStack {
                    Text("Port").frame(width: 70, alignment: .leading)
                    TextField("22", value: $server.port, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }

                Picker("Auth", selection: $server.auth) {
                    Text("SSH key").tag(Server.Auth.key)
                    Text("Password").tag(Server.Auth.password)
                }.pickerStyle(.segmented)

                if server.auth == .key {
                    field("Key path", text: $server.keyPath,
                          placeholder: "~/.ssh/id_ed25519 (blank = ssh agent/config)")
                } else {
                    HStack {
                        Text("Password").frame(width: 70, alignment: .leading)
                        SecureField(Keychain.has(account: server.secretAccount) ? "•••••• (stored)" : "Required",
                                    text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Stored in the macOS Keychain. No extra tools needed.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if let testResult {
                    Text(testResult).font(.caption)
                        .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                }

                HStack {
                    Button {
                        Task { await test() }
                    } label: {
                        if testing { ProgressView().controlSize(.small) } else { Text("Test connection") }
                    }
                    .disabled(testing || server.host.isEmpty)
                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button("Save") { onSave((normalized(), password)) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(server.host.isEmpty)
                }
                .padding(.top, 4)
            }
            .padding(12)
        }
    }

    private func normalized() -> Server {
        var s = server
        s.keyPath = (s.keyPath as NSString).expandingTildeInPath == s.keyPath
            ? s.keyPath
            : (s.keyPath as NSString).expandingTildeInPath
        return s
    }

    private func test() async {
        testing = true
        defer { testing = false }
        // store the typed password temporarily so probe can use it
        let s = normalized()
        if s.auth == .password, !password.isEmpty {
            Keychain.set(password, account: s.secretAccount)
        }
        switch await state.testConnection(s) {
        case .success(let msg): testResult = "✓ " + msg
        case .failure(let err): testResult = "✗ " + err.localizedDescription
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

/// Records a global shortcut for toggling the panel. While recording, a local event
/// monitor captures the next modifier+key combo (Esc cancels). The combo is stored
/// and the global hotkey re-registered immediately.
struct ShortcutRecorder: View {
    @State private var recording = false
    @State private var display = ""
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press keys…  (Esc to cancel)"
                             : (display.isEmpty ? "Click to set" : display)) {
                recording ? stop() : start()
            }
            .frame(minWidth: 150)
            if !display.isEmpty && !recording {
                Button { clear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Clear shortcut")
            }
        }
        .onAppear {
            if let (code, mods) = HotKey.stored { display = HotKey.describe(keyCode: code, modifiers: mods) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            if e.keyCode == 53 { stop(); return nil }              // Esc cancels
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return nil }                // require a modifier
            HotKey.stored = (UInt32(e.keyCode), mods)
            HotKey.shared.reload()
            display = HotKey.describe(keyCode: UInt32(e.keyCode), modifiers: mods)
            stop()
            return nil                                             // swallow the event
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func clear() {
        HotKey.stored = nil
        HotKey.shared.reload()
        display = ""
    }
}
