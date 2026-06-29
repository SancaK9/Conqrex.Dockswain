import SwiftUI

/// Let's Encrypt certificates via `certbot --nginx`: list existing certs and issue
/// a new one for one or more domains, with an optional HTTP→HTTPS redirect.
struct CertbotView: View {
    let onBack: () -> Void
    @EnvironmentObject var state: AppState

    @State private var certs: [Cert] = []
    @State private var status = "Loading…"
    @State private var domains = ""
    @State private var redirect = true
    @State private var busy = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "SSL (certbot)", trailing: AnyView(
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            ), onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ISSUE A CERTIFICATE").font(.caption2.bold()).foregroundStyle(.secondary)
                    TextField("example.com, www.example.com", text: $domains).textFieldStyle(.roundedBorder)
                    Toggle("Redirect HTTP → HTTPS", isOn: $redirect).font(.caption)
                    HStack {
                        Button { Task { await issue() } } label: {
                            if busy { ProgressView().controlSize(.small) } else { Text("Get certificate") }
                        }.disabled(busy || domains.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }
                    if let r = result {
                        Text(r.text).font(.caption2.monospaced())
                            .foregroundStyle(r.ok ? .green : .red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()
                    Text("CERTIFICATES").font(.caption2.bold()).foregroundStyle(.secondary)
                    if certs.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(certs) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.system(size: 12, weight: .medium))
                                Text(c.domains).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                Text("Expires: \(c.expiry)").font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        }
                    }
                }.padding(12)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let s = state.selectedServer else { status = "No server"; return }
        do { certs = try await state.makeBackend().certbotList(s); status = certs.isEmpty ? "No certificates." : "" }
        catch { status = error.localizedDescription; certs = [] }
    }

    private func issue() async {
        guard let s = state.selectedServer else { return }
        let list = domains.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let out = try await state.makeBackend().certbotIssue(domains: list, redirect: redirect, on: s)
            result = (true, out.isEmpty ? "Certificate installed." : out)
            await load()
        } catch { result = (false, error.localizedDescription) }
    }
}
