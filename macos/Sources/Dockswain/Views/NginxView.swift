import SwiftUI

/// Browse /etc/nginx in two tabs: server blocks ("Sites") and the shared include
/// snippets under conf.d ("conf.d" — upstreams, maps, …). Both support enable/disable,
/// view/edit a config inline, and the conf.d tab additionally creates and deletes files.
/// `nginx -t` and reload apply to the whole server. Editing reuses the warm SSH
/// connection (read/write file, sudo-aware via the server's "Use sudo" setting).
struct NginxView: View {
    let openCertbot: () -> Void
    let onBack: () -> Void
    @EnvironmentObject var state: AppState

    enum Tab: String, CaseIterable { case sites = "Sites", confd = "conf.d" }

    @State private var tab: Tab = .sites

    @State private var sites: [NginxSite] = []
    @State private var confd: [ConfdFile] = []
    @State private var dir = "/etc/nginx"
    @State private var confdDir = "/etc/nginx/conf.d"
    @State private var status = "Loading…"
    @State private var confdStatus = "Loading…"
    @State private var confdLoaded = false
    @State private var testResult: (pass: Bool, text: String)?

    @State private var editing: EditTarget?
    @State private var editText = ""
    @State private var creating = false        // new-site form
    @State private var creatingConfd = false    // new conf.d file (name prompt)
    @State private var newConfdName = ""
    @State private var pendingDelete: ConfdFile?
    @State private var busy = false

    /// A file open in the inline editor — a site, an existing snippet, or a new snippet.
    struct EditTarget: Identifiable, Equatable {
        let name: String
        let path: String
        let isNew: Bool
        var id: String { path }
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "Nginx", trailing: AnyView(HStack(spacing: 10) {
                Button { startCreate() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(tab == .sites ? "New website" : "New conf.d file")
                Button { openCertbot() } label: { Image(systemName: "lock.shield") }
                    .buttonStyle(.borderless).help("SSL certificates (certbot)")
                Button { Task { await reloadCurrent() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }), onBack: onBack)

            if creating {
                NewSiteForm(onCancel: { creating = false }, onCreated: {
                    creating = false; openCertbot()
                }, onDone: { creating = false; Task { await load() } })
            } else if creatingConfd { confdNameForm }
            else if let editing { editor(editing) }
            else { main }
        }
        .task { await load() }
    }

    // MARK: - main (tabs + actions)

    private var main: some View {
        VStack(spacing: 0) {
            HStack {
                Button { Task { await runTest() } } label: { Label("Test", systemImage: "checkmark.seal") }
                    .controlSize(.small)
                Button { Task { await reload() } } label: { Label("Reload", systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.small)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 8).padding(.top, 8)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            .onChange(of: tab) { _ in if tab == .confd && !confdLoaded { Task { await loadConfd() } } }

            if let t = testResult {
                Text(t.text).font(.caption2.monospaced())
                    .foregroundStyle(t.pass ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }
            Divider()
            if tab == .sites { sitesBrowser } else { confdBrowser }
        }
    }

    private var sitesBrowser: some View {
        Group {
            if sites.isEmpty {
                placeholder(status)
            } else {
                ScrollView { VStack(spacing: 4) { ForEach(sites) { siteRow($0) } }.padding(8) }
            }
        }
    }

    private var confdBrowser: some View {
        Group {
            if confd.isEmpty {
                placeholder(confdStatus)
            } else {
                ScrollView { VStack(spacing: 4) { ForEach(confd) { confdRow($0) } }.padding(8) }
            }
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "")?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let f = pendingDelete { delete(f) } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let f = pendingDelete { Text("Removes \(f.path) from the server. Run Test + Reload after.") }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack { Spacer(); Text(text).font(.caption).foregroundStyle(.secondary); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Button(s.enabled ? "disable" : "enable") { toggleSite(s) }.controlSize(.small)
            Button { Task { await openEditor(name: s.fileName, path: s.path) } } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("View / edit")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func confdRow(_ f: ConfdFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: f.enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(f.enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(Bytes.human(f.size)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(f.enabled ? "disable" : "enable") { toggleConfd(f) }.controlSize(.small)
            Button { Task { await openEditor(name: f.name, path: f.path) } } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("View / edit")
            Button(role: .destructive) { pendingDelete = f } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - editor (shared by sites + conf.d)

    private func editor(_ t: EditTarget) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { editing = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(t.name).font(.caption).lineLimit(1)
                Spacer()
                Button("Save") { Task { await save(t) } }.controlSize(.small)
            }.padding(8)
            Divider()
            TextEditor(text: $editText)
                .font(.system(size: 11, design: .monospaced))
                .padding(4)
        }
    }

    // MARK: - new conf.d file (name prompt → opens the editor with a template)

    private var confdNameForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { creatingConfd = false } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text("New conf.d file").font(.caption)
                Spacer()
            }
            HStack {
                Text("File name").font(.caption).frame(width: 70, alignment: .leading)
                TextField("upstream.conf", text: $newConfdName).textFieldStyle(.roundedBorder)
            }
            Text("Saved under \(confdDir)/. “.conf” is added if you omit an extension.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { creatingConfd = false }
                Button("Continue") { continueNewConfd() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sanitizedConfdName == nil)
            }
            Spacer()
        }.padding(12)
    }

    /// Validated base name with a guaranteed extension, or nil if invalid.
    private var sanitizedConfdName: String? {
        let raw = newConfdName.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw != ".", raw != "..", !raw.contains("/") else { return nil }
        let ok = raw.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
        guard ok else { return nil }
        return raw.contains(".") ? raw : raw + ".conf"
    }

    private func continueNewConfd() {
        guard let name = sanitizedConfdName else { return }
        creatingConfd = false
        editText = "# \(name)\n# nginx include — e.g. an upstream {} or map {} block.\n\n"
        editing = EditTarget(name: name, path: "\(confdDir)/\(name)", isNew: true)
    }

    // MARK: - actions

    private func startCreate() {
        testResult = nil
        if tab == .sites { creating = true } else { newConfdName = ""; creatingConfd = true }
    }

    private func reloadCurrent() async {
        if tab == .sites { await load() } else { await loadConfd() }
    }

    private func load() async {
        guard let srv = state.selectedServer else { status = "No server"; return }
        // Seed from the configured dir up front so a "New conf.d file" created before the
        // server replies still writes under the right nginx directory (refined below).
        confdDir = "\(state.nginxDir)/conf.d"
        do { let r = try await state.makeBackend().nginxSites(srv); dir = r.dir; sites = r.sites
             confdDir = "\(dir)/conf.d"
             status = sites.isEmpty ? "No sites found in \(dir)." : "" }
        catch { status = error.localizedDescription; sites = [] }
        if tab == .confd || confdLoaded { await loadConfd() }
    }

    private func loadConfd() async {
        guard let srv = state.selectedServer else { confdStatus = "No server"; return }
        do { let r = try await state.makeBackend().nginxConfd(srv); confdDir = r.dir; confd = r.files
             confdLoaded = true
             confdStatus = confd.isEmpty ? "No files in \(confdDir)." : "" }
        catch { confdStatus = error.localizedDescription; confd = [] }
    }

    private func toggleSite(_ s: NginxSite) {
        guard let srv = state.selectedServer else { return }
        Task { try? await state.makeBackend().nginxToggle(s.enabled ? "disable" : "enable", fileName: s.fileName, on: srv); await load() }
    }
    private func toggleConfd(_ f: ConfdFile) {
        guard let srv = state.selectedServer else { return }
        Task {
            do { try await state.makeBackend().nginxConfdToggle(f.enabled ? "disable" : "enable", name: f.name, on: srv) }
            catch { testResult = (false, error.localizedDescription) }
            await loadConfd()
        }
    }
    private func delete(_ f: ConfdFile) {
        guard let srv = state.selectedServer else { return }
        pendingDelete = nil
        Task {
            do { try await state.makeBackend().nginxConfdDelete(f.name, on: srv) }
            catch { testResult = (false, error.localizedDescription) }
            await loadConfd()
        }
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
    private func openEditor(name: String, path: String) async {
        guard let srv = state.selectedServer else { return }
        editText = (try? await state.makeBackend().readFile(path, on: srv)) ?? ""
        editing = EditTarget(name: name, path: path, isNew: false)
    }
    private func save(_ t: EditTarget) async {
        guard let srv = state.selectedServer else { return }
        do { try await state.makeBackend().writeFile(t.path, content: editText, on: srv)
             editing = nil
             await reloadCurrent() }
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
