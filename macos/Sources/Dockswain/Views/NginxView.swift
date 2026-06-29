import SwiftUI

/// Browse /etc/nginx sites: enable/disable, view/edit a config inline, run
/// `nginx -t`, and reload. Editing reuses the warm SSH connection (read/write file).
struct NginxView: View {
    let openCertbot: () -> Void
    let onBack: () -> Void
    @EnvironmentObject var state: AppState

    @State private var sites: [NginxSite] = []
    @State private var dir = "/etc/nginx"
    @State private var status = "Loading…"
    @State private var testResult: (pass: Bool, text: String)?
    @State private var editing: NginxSite?
    @State private var editText = ""
    @State private var creating = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "Nginx", trailing: AnyView(HStack(spacing: 10) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New website")
                Button { openCertbot() } label: { Image(systemName: "lock.shield") }
                    .buttonStyle(.borderless).help("SSL certificates (certbot)")
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }), onBack: onBack)

            if creating {
                NewSiteForm(onCancel: { creating = false }, onCreated: {
                    creating = false; openCertbot()
                }, onDone: { creating = false; Task { await load() } })
            } else if let editing { editor(editing) }
            else { browser }
        }
        .task { await load() }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Button { Task { await runTest() } } label: { Label("Test", systemImage: "checkmark.seal") }
                    .controlSize(.small)
                Button { Task { await reload() } } label: { Label("Reload", systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.small)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }.padding(8)
            if let t = testResult {
                Text(t.text).font(.caption2.monospaced())
                    .foregroundStyle(t.pass ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }
            Divider()
            if sites.isEmpty {
                VStack { Spacer(); Text(status).font(.caption).foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { VStack(spacing: 4) { ForEach(sites) { siteRow($0) } }.padding(8) }
            }
        }
    }

    private func siteRow(_ s: NginxSite) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(s.enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(s.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if s.tls { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.green) }
                }
                if !s.serverName.isEmpty {
                    Text(s.serverName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if s.dir == "sites-available" {
                Button(s.enabled ? "disable" : "enable") { toggle(s) }.controlSize(.small)
            }
            Button { Task { await openEditor(s) } } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("View / edit")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func editor(_ s: NginxSite) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { editing = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(s.fileName).font(.caption).lineLimit(1)
                Spacer()
                Button("Save") { Task { await save(s) } }.controlSize(.small)
            }.padding(8)
            Divider()
            TextEditor(text: $editText)
                .font(.system(size: 11, design: .monospaced))
                .padding(4)
        }
    }

    // MARK: - actions

    private func load() async {
        guard let srv = state.selectedServer else { status = "No server"; return }
        do { let r = try await state.makeBackend().nginxSites(srv); dir = r.dir; sites = r.sites
             status = sites.isEmpty ? "No sites found in \(dir)." : "" }
        catch { status = error.localizedDescription; sites = [] }
    }
    private func toggle(_ s: NginxSite) {
        guard let srv = state.selectedServer else { return }
        Task { try? await state.makeBackend().nginxToggle(s.enabled ? "disable" : "enable", fileName: s.fileName, on: srv); await load() }
    }
    private func runTest() async {
        guard let srv = state.selectedServer else { return }
        busy = true; defer { busy = false }
        if let (pass, text) = try? await state.makeBackend().nginxTest(srv) { testResult = (pass, text) }
    }
    private func reload() async {
        guard let srv = state.selectedServer else { return }
        busy = true; defer { busy = false }
        do { try await state.makeBackend().nginxReload(srv); testResult = (true, "Reloaded.") }
        catch { testResult = (false, error.localizedDescription) }
    }
    private func openEditor(_ s: NginxSite) async {
        guard let srv = state.selectedServer else { return }
        editText = (try? await state.makeBackend().readFile(s.path, on: srv)) ?? ""
        editing = s
    }
    private func save(_ s: NginxSite) async {
        guard let srv = state.selectedServer else { return }
        do { try await state.makeBackend().writeFile(s.path, content: editText, on: srv); editing = nil; await load() }
        catch { testResult = (false, error.localizedDescription) }
    }
}

/// Generate and create a new nginx server block: a reverse proxy (proxy_pass with
/// the WebSocket upgrade headers) or a static site (root + try_files).
private struct NewSiteForm: View {
    let onCancel: () -> Void
    let onCreated: () -> Void      // created, then jump to certbot (Get SSL)
    let onDone: () -> Void         // created, stay in nginx
    @EnvironmentObject var state: AppState

    enum Kind: String, CaseIterable { case proxy = "Reverse proxy", staticSite = "Static site" }
    @State private var name = ""
    @State private var serverName = ""
    @State private var kind: Kind = .proxy
    @State private var proxyTarget = "http://127.0.0.1:3000"
    @State private var root = "/var/www/html"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                field("File name", $name, "example.com")
                field("server_name", $serverName, "example.com www.example.com")
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if kind == .proxy { field("proxy_pass", $proxyTarget, "http://127.0.0.1:3000") }
                else { field("root", $root, "/var/www/html") }

                if let error { Text(error).font(.caption).foregroundStyle(.red) }

                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button("Create") { create(thenSSL: false) }.disabled(invalid)
                    Button("Create + Get SSL") { create(thenSSL: true) }.disabled(invalid)
                        .keyboardShortcut(.defaultAction)
                }.padding(.top, 4)

                Text("Written to sites-available + symlink, or conf.d/*.conf. Run Test + Reload after.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(12)
        }
    }

    private var invalid: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty || serverName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func config() -> String {
        let sn = serverName.trimmingCharacters(in: .whitespaces)
        if kind == .proxy {
            return """
            server {
                listen 80;
                server_name \(sn);
                location / {
                    proxy_pass \(proxyTarget.trimmingCharacters(in: .whitespaces));
                    proxy_http_version 1.1;
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                    proxy_set_header Upgrade $http_upgrade;
                    proxy_set_header Connection "upgrade";
                }
            }
            """
        } else {
            return """
            server {
                listen 80;
                server_name \(sn);
                root \(root.trimmingCharacters(in: .whitespaces));
                index index.html;
                location / { try_files $uri $uri/ =404; }
            }
            """
        }
    }

    private func create(thenSSL: Bool) {
        guard let srv = state.selectedServer else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await state.makeBackend().nginxNew(name: name.trimmingCharacters(in: .whitespaces),
                                                       config: config(), on: srv)
                thenSSL ? onCreated() : onDone()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 90, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}
