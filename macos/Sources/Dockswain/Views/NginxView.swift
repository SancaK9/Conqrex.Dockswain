import SwiftUI

/// Browse /etc/nginx: a dedicated nginx.conf row, then each vhost with an enable/
/// disable switch, an SSL status shield (green when the config has a TLS block, red
/// when not — click to issue/renew via certbot), and view / edit buttons. Editing
/// reuses the warm SSH connection (read/write file). Also runs `nginx -t` + reload.
struct NginxView: View {
    /// Jump to the certbot screen, optionally prefilled with a site's domains.
    let openCertbot: (String) -> Void
    let onBack: () -> Void
    @EnvironmentObject var state: AppState

    /// A file we can view (read-only) or edit, identified by its remote path.
    /// `isNew` means it doesn't exist yet (don't read it; save creates it).
    private struct FileTarget: Identifiable, Equatable {
        let title: String
        let path: String
        var isNew: Bool = false
        var id: String { path }
    }

    @State private var sites: [NginxSite] = []
    @State private var dir = "/etc/nginx"
    @State private var hasConf = false
    @State private var status = "Loading…"
    @State private var testResult: (pass: Bool, text: String)?
    @State private var editing: FileTarget?
    @State private var viewing: FileTarget?
    @State private var fileText = ""
    @State private var creating = false
    @State private var busy = false

    // conf.d snippets (upstreams, maps, includes) — shown inline below the sites.
    @State private var confd: [ConfdFile] = []
    @State private var confdDir = "/etc/nginx/conf.d"
    @State private var confdStatus = "Loading…"
    @State private var creatingConfd = false
    @State private var newConfdName = ""
    @State private var pendingDelete: ConfdFile?

    @State private var certs: [Cert] = []        // installed certbot certs (inline list)

    private var confPath: String { dir + "/nginx.conf" }

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "Nginx \(dir)", trailing: AnyView(HStack(spacing: 10) {
                Button { creating = true } label: { Label("New site", systemImage: "plus") }
                    .controlSize(.small).help("Create a new nginx website config")
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload list")
            }), onBack: onBack)

            if creating {
                NewSiteForm(onCancel: { creating = false }, onCreated: { domains in
                    creating = false; openCertbot(domains)
                }, onDone: { creating = false; Task { await load() } })
            } else if creatingConfd { confdNameForm }
            else if let viewing { viewer(viewing) }
            else if let editing { editor(editing) }
            else { browser }
        }
        .task { await load() }
    }

    // Single scrolling page (the Linux layout): nginx.conf, Sites, conf.d, then the
    // certificates list — with a Test / Reload bar pinned at the bottom.
    private var browser: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    if hasConf { confRow }

                    sectionHeader("Sites")
                    if sites.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    } else {
                        ForEach(sites) { siteRow($0) }
                    }

                    HStack {
                        Text("conf.d").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button { newConfdName = ""; creatingConfd = true } label: {
                            Label("New file", systemImage: "plus")
                        }.controlSize(.mini)
                    }.padding(.top, 6)
                    if confd.isEmpty {
                        Text(confdStatus).font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
                    } else {
                        ForEach(confd) { confdRow($0) }
                    }

                    if !certs.isEmpty {
                        sectionHeader("Certificates")
                        ForEach(certs) { certRow($0) }
                    }
                }.padding(8)
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

            if let t = testResult {
                Divider()
                Text(t.text).font(.caption2.monospaced())
                    .foregroundStyle(t.pass ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4)
            }
            Divider()
            HStack {
                Button { Task { await runTest() } } label: { Label("Test (nginx -t)", systemImage: "checkmark.seal") }
                    .controlSize(.small)
                Button { Task { await reload() } } label: { Label("Reload nginx", systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.small)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }.padding(8)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack { Text(title).font(.caption2).foregroundStyle(.secondary); Spacer() }.padding(.top, 4)
    }

    // One certbot certificate: a green/red shield by validity, name, and expiry.
    private func certRow(_ c: Cert) -> some View {
        let ok = c.isValid
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .font(.system(size: 10)).foregroundStyle(ok ? Color.green : Color.red)
                Text(c.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                Spacer()
                if !c.valid.isEmpty {
                    Text(c.valid).font(.caption2).foregroundStyle(ok ? Color.secondary : Color.red)
                }
            }
            Text("expires \(c.expiry)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func confdRow(_ f: ConfdFile) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { f.enabled }, set: { _ in toggleConfd(f) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1).opacity(f.enabled ? 1 : 0.55)
                Text(Bytes.human(f.size)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await openViewer(FileTarget(title: f.name, path: f.path)) } } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }.buttonStyle(.borderless).help("View")
            Button { Task { await openEditor(FileTarget(title: f.name, path: f.path)) } } label: {
                Image(systemName: "pencil")
            }.buttonStyle(.borderless).help("Edit")
            Button(role: .destructive) { pendingDelete = f } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    // New conf.d file: ask for a name, then open the editor seeded with a template.
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
                    .keyboardShortcut(.defaultAction).disabled(sanitizedConfdName == nil)
            }
            Spacer()
        }.padding(12)
    }

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
        fileText = "# \(name)\n# nginx include — e.g. an upstream {} or map {} block.\n\n"
        editing = FileTarget(title: name, path: "\(confdDir)/\(name)", isNew: true)
    }

    // nginx.conf — view / edit the main config.
    private var confRow: some View {
        HStack(spacing: 8) {
            Text("nginx.conf").font(.system(size: 12, weight: .bold, design: .monospaced))
            Spacer()
            Button { Task { await openViewer(FileTarget(title: "nginx.conf", path: confPath)) } } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }.buttonStyle(.borderless).help("View")
            Button { Task { await openEditor(FileTarget(title: "nginx.conf", path: confPath)) } } label: {
                Image(systemName: "pencil")
            }.buttonStyle(.borderless).help("Edit")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func siteRow(_ s: NginxSite) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { s.enabled }, set: { _ in toggle(s) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(s.fileName).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1).opacity(s.enabled ? 1 : 0.55)
                if !s.serverName.isEmpty {
                    Text(s.serverName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            if s.tls {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Has an SSL/TLS certificate block")
            }
            // SSL status shield: green = TLS block present, red = none. Click to issue/renew.
            Button { openCertbot(s.serverName.isEmpty ? s.fileName : s.serverName) } label: {
                Image(systemName: s.tls ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .foregroundStyle(s.tls ? .green : .red)
            }
            .buttonStyle(.borderless).disabled(!s.enabled)
            .help(!s.enabled ? "Enable & reload the site first to request SSL"
                  : s.tls ? "Renew / reissue SSL (certbot)" : "Get SSL certificate (certbot)")

            Button { Task { await openViewer(FileTarget(title: s.fileName, path: s.path)) } } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }.buttonStyle(.borderless).help("View")
            Button { Task { await openEditor(FileTarget(title: s.fileName, path: s.path)) } } label: {
                Image(systemName: "pencil")
            }.buttonStyle(.borderless).help("Edit")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func viewer(_ t: FileTarget) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { viewing = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(t.title).font(.caption.monospaced()).lineLimit(1)
                Spacer()
                Button { Task { viewing = nil; await openEditor(t) } } label: { Label("Edit", systemImage: "pencil") }
                    .controlSize(.small)
            }.padding(8)
            Divider()
            ScrollView {
                Text(fileText).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    private func editor(_ t: FileTarget) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { editing = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(t.title).font(.caption.monospaced()).lineLimit(1)
                Spacer()
                Button("Save") { Task { await save(t) } }.controlSize(.small)
            }.padding(8)
            Divider()
            TextEditor(text: $fileText)
                .font(.system(size: 11, design: .monospaced))
                .padding(4)
        }
    }

    // MARK: - actions

    private func load() async {
        guard let srv = state.selectedServer else { status = "No server"; return }
        confdDir = "\(state.nginxDir)/conf.d"
        let backend = state.makeBackend()
        do { let r = try await backend.nginxSites(srv)
             dir = r.dir; hasConf = r.hasConf; sites = r.sites
             confdDir = "\(dir)/conf.d"
             status = sites.isEmpty ? "No sites found in \(dir)." : "" }
        catch { status = error.localizedDescription; sites = []; hasConf = false }
        await loadConfd()
        certs = (try? await backend.certbotList(srv)) ?? []
    }
    private func loadConfd() async {
        guard let srv = state.selectedServer else { confdStatus = "No server"; return }
        do { let r = try await state.makeBackend().nginxConfd(srv); confdDir = r.dir; confd = r.files
             confdStatus = confd.isEmpty ? "No files in \(confdDir)." : "" }
        catch { confdStatus = error.localizedDescription; confd = [] }
    }
    private func toggle(_ s: NginxSite) {
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
    private func openViewer(_ t: FileTarget) async {
        guard let srv = state.selectedServer else { return }
        fileText = (try? await state.makeBackend().readFile(t.path, on: srv)) ?? ""
        viewing = t
    }
    private func openEditor(_ t: FileTarget) async {
        guard let srv = state.selectedServer else { return }
        fileText = (try? await state.makeBackend().readFile(t.path, on: srv)) ?? ""
        editing = t
    }
    private func save(_ t: FileTarget) async {
        guard let srv = state.selectedServer else { return }
        do {
            try await state.makeBackend().writeFile(t.path, content: fileText, on: srv)
            editing = nil
            await load()
        } catch { testResult = (false, error.localizedDescription) }
    }
}

/// Generate and create a new nginx server block: a reverse proxy (proxy_pass with
/// the WebSocket upgrade headers) or a static site (root + try_files).
private struct NewSiteForm: View {
    let onCancel: () -> Void
    let onCreated: (String) -> Void   // created, then jump to certbot with these domains
    let onDone: () -> Void            // created, stay in nginx
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
        let sn = serverName.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                try await state.makeBackend().nginxNew(name: name.trimmingCharacters(in: .whitespaces),
                                                       config: config(), on: srv)
                thenSSL ? onCreated(sn) : onDone()
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
