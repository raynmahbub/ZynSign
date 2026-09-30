import SwiftUI

/// The observable model behind the Revocation Center.
@MainActor
final class RevocationCenterModel: ObservableObject {

    @Published private(set) var identities: [SigningIdentity] = []
    @Published private(set) var reports: [String: RevocationExposureReport] = [:]
    @Published private(set) var checkingFingerprints: Set<String> = []
    @Published var errorMessage: String?

    private let service: CertificateRevocationService
    private let identityStore: any IdentityStore

    init(service: CertificateRevocationService, identityStore: any IdentityStore) {
        self.service = service
        self.identityStore = identityStore
        refresh()
    }

    func refresh() {
        let listed = (try? identityStore.listIdentities()) ?? []
        identities = listed
        var loaded: [String: RevocationExposureReport] = [:]
        for identity in listed {
            let fingerprint = identity.certificate.sha256Fingerprint.hexDigest
            if let report = try? service.lastReport(fingerprint: fingerprint) {
                loaded[fingerprint] = report
            }
        }
        reports = loaded
    }

    func check(_ identity: SigningIdentity) async {
        let fingerprint = identity.certificate.sha256Fingerprint.hexDigest
        guard !checkingFingerprints.contains(fingerprint) else { return }
        checkingFingerprints.insert(fingerprint)
        errorMessage = nil
        defer { checkingFingerprints.remove(fingerprint) }
        do {
            let certificate = try identityStore.signingCertificate(for: identity.id)
            let report = try await service.check(
                certificateDER: certificate.derData,
                fingerprint: fingerprint
            )
            reports[fingerprint] = report
        } catch {
            errorMessage = "The exposure check could not run for this certificate."
        }
    }
}

/// The badge an exposure verdict renders as.
struct RevocationVerdictBadge: View {
    let verdict: RevocationExposureReport.Verdict

    var body: some View {
        switch verdict {
        case .exposed:
            ZStatusBadge("Exposed", systemImage: "antenna.radiowaves.left.and.right", kind: .warning)
        case .partial:
            ZStatusBadge("Partial", systemImage: "antenna.radiowaves.left.and.right.slash", kind: .warning)
        case .shielded:
            ZStatusBadge("Shielded", systemImage: "shield.checkered", kind: .success)
        case .noEndpoints:
            ZStatusBadge("No Endpoints", systemImage: "slash.circle", kind: .neutral)
        case .notChecked:
            ZStatusBadge("Not Checked", systemImage: "questionmark.circle", kind: .neutral)
        }
    }
}

/// The Revocation Center: checks how reachable each certificate's
/// revocation channels are right now, and explains what the answers mean.
///
/// The center answers an exposure question honestly. It cannot change the
/// device's DNS, and it says so: protection happens at the network level —
/// a resolver or profile that blocks the revocation domains — and this
/// screen measures whether that blocking appears to be in effect.
struct RevocationCenterView: View {
    @StateObject private var model: RevocationCenterModel

    init(service: CertificateRevocationService, identityStore: any IdentityStore) {
        _model = StateObject(wrappedValue: RevocationCenterModel(service: service, identityStore: identityStore))
    }

    var body: some View {
        List {
            Section {
                Label("Exposure, not verdict", systemImage: "info.circle")
                Text("Each check probes the revocation endpoints the certificate itself publishes — its OCSP responders and revocation lists — and reports which ones answer from this device right now.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("What This Screen Measures")
            } footer: {
                Text("ZynSign never changes your network settings. Anti-revoke protection happens at your resolver or DNS profile; a check where every endpoint is unreachable while ordinary browsing works is the pattern that protection produces.")
            }

            if model.identities.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Certificates",
                        systemImage: "signature",
                        description: Text("Import a certificate in Settings → Certificates, then check its revocation exposure here.")
                    )
                }
            }

            ForEach(model.identities, id: \.id) { identity in
                identityRow(identity)
            }
        }
        .navigationTitle("Revocation Center")
        .zThemeTint()
        .refreshable { model.refresh() }
        .alert("Check Failed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func identityRow(_ identity: SigningIdentity) -> some View {
        let fingerprint = identity.certificate.sha256Fingerprint.hexDigest
        let report = model.reports[fingerprint]
        let checking = model.checkingFingerprints.contains(fingerprint)
        return VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.certificate.subjectCommonName ?? identity.displayName)
                        .font(.headline)
                    Text(identity.certificate.issuerCommonName ?? "Unknown issuer")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RevocationVerdictBadge(verdict: report?.verdict ?? .notChecked)
            }
            if let report {
                Text("Checked \(report.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
                outcomeRows(report)
            }
            HStack {
                Button {
                    Task { await model.check(identity) }
                } label: {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(report == nil ? "Check Exposure" : "Check Again", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.callout)
                    }
                }
                .disabled(checking)
                Spacer()
                if identity.certificate.notValidAfter < Date() {
                    ZStatusBadge("Expired", systemImage: "clock.badge.xmark", kind: .error)
                }
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    private func outcomeRows(_ report: RevocationExposureReport) -> some View {
        ForEach(report.outcomes, id: \.endpoint.url) { outcome in
            HStack(spacing: ZSpacing.xs) {
                Image(systemName: outcome.reachable ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(outcome.reachable ? Color.orange : Color.green)
                    .font(.caption)
                Text(outcome.endpoint.url)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let ms = outcome.latencyMs {
                    Spacer()
                    Text("\(ms) ms").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
