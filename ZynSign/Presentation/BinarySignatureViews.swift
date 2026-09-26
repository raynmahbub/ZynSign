import SwiftUI

// MARK: - Code signature inspector

/// The parts of one architecture's code signature, each as an expandable
/// card with a status, a one-line summary, and plain-language details. No
/// binary structure is dumped; digests appear only where they identify
/// something, such as the CDHash.
struct CodeSignatureInspectorSection: View {
    let architecture: BinaryArchitectureReport
    let integrity: ArchitectureIntegrityResult?

    var body: some View {
        if let signature = architecture.signature {
            signed(signature)
        } else {
            ZCard {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    HStack {
                        Label("No Code Signature", systemImage: "seal")
                            .font(.headline)
                        Spacer(minLength: 0)
                        BinaryStatusBadge(presentation: BinaryStatusPresentation(text: "Absent", systemImage: "minus.circle", kind: .neutral), subject: "Signature")
                    }
                    Text("The \(architecture.name) architecture carries no LC_CODE_SIGNATURE command, so there is no CodeDirectory, CMS signature, or entitlement set to inspect. iOS does not run unsigned code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func signed(_ signature: CodeSignatureSummary) -> some View {
        BinaryExpandableCard(
            title: "Signature Present",
            subtitle: "\(signature.form.displayName) · \(signature.blobs.count) component(s)",
            systemImage: "checkmark.seal",
            status: BinaryStatusPresentation(text: "Present", systemImage: "checkmark.seal.fill", kind: .info),
            initiallyExpanded: true
        ) {
            Text(signature.form.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            BinaryFieldRow(label: "Signature size", value: BinaryFormat.bytesDetailed(signature.superBlobByteCount),
                           explanation: "The space the signature's components occupy at the end of the file.")
            ForEach(signature.blobs) { blob in
                BinaryFieldRow(label: blob.title, value: BinaryFormat.bytes(blob.byteCount), explanation: blob.explanation)
            }
        }

        if let primary = signature.primaryCodeDirectory {
            BinaryExpandableCard(
                title: "CodeDirectory",
                subtitle: "\(primary.hashType.displayName) · \(primary.pageCount.formatted()) pages · \(primary.identifier)",
                systemImage: "list.bullet.rectangle",
                status: integrity?.check(.codeDirectory).map { BinaryStatusPresentation($0.status) }
            ) {
                Text("The CodeDirectory is the heart of the signature: a table holding the hash of every page of code and of the signature's other parts, plus the code's identity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                BinaryFieldRow(label: "Identifier", value: primary.identifier)
                BinaryFieldRow(label: "Team ID", value: primary.teamIdentifier ?? "Not recorded")
                if let cdHash = primary.cdHashText {
                    BinaryFieldRow(label: "CDHash", value: cdHash, explanation: "The hash of the CodeDirectory itself, which identifies this exact signature.", monospaced: true)
                }
                if signature.codeDirectories.count > 1 {
                    BinaryFieldRow(label: "CodeDirectories", value: signature.codeDirectories.map(\.hashType.displayName).joined(separator: " + "),
                                   explanation: "Signatures can carry one CodeDirectory per hash algorithm so older and newer systems can each check one.")
                }
                NavigationLink {
                    CodeDirectoryDetailView(signature: signature)
                } label: {
                    Label("Open CodeDirectory Viewer", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }

        cmsCard(signature)

        if let primary = signature.primaryCodeDirectory {
            let results = integrity?.specialSlots.filter { $0.codeDirectorySlot == primary.slotNumber } ?? []
            BinaryExpandableCard(
                title: "Special Slots",
                subtitle: "\(primary.boundSpecialSlotCount) of \(primary.specialSlots.count) slots bound",
                systemImage: "square.grid.3x3.topleft.filled",
                status: integrity?.check(.specialSlots).map { BinaryStatusPresentation($0.status) }
            ) {
                Text("Special slots bind content outside the code — the Info.plist, the resource seal, the requirements, and the entitlements — so changing any of them breaks the signature.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if primary.specialSlots.isEmpty && results.isEmpty {
                    Text("This CodeDirectory declares no special slots.")
                        .font(.subheadline)
                }
                ForEach(slotRows(primary: primary, results: results), id: \.number) { row in
                    SpecialSlotRow(number: row.number, isBound: row.isBound, result: row.result)
                }
            }

            BinaryExpandableCard(
                title: "Page Hashing",
                subtitle: pageHashingSubtitle(primary),
                systemImage: "doc.on.doc",
                status: integrity?.check(.pageHashes).map { BinaryStatusPresentation($0.status) }
            ) {
                Text("The code is divided into pages, and the CodeDirectory records a hash of each. The system checks each page as it loads it, so a single changed byte is caught.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                BinaryFieldRow(label: "Hash algorithm", value: primary.hashType.displayName)
                BinaryFieldRow(label: "Page size", value: primary.pageSize.map { BinaryFormat.memory($0) } ?? "Unpaged (one hash over all code)")
                BinaryFieldRow(label: "Pages", value: primary.pageCount.formatted())
                BinaryFieldRow(label: "Code covered", value: BinaryFormat.bytesDetailed(Int(clamping: primary.codeLimit)),
                               explanation: "Everything before the signature itself is covered.")
                if let check = integrity?.check(.pageHashes) {
                    BinaryFieldRow(label: "Result", value: check.summary, explanation: check.detail)
                }
            }
        }

        BinaryExpandableCard(
            title: "Requirements",
            subtitle: requirementsSubtitle(signature.requirements),
            systemImage: "checklist.checked",
            status: integrity?.check(.requirements).map { BinaryStatusPresentation($0.status) }
        ) {
            Text("Requirements are rules that describe which signatures count as this code — for example, its designated requirement. ZynSign decodes them but does not evaluate the rules.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if signature.requirements.requirementKinds.isEmpty {
                BinaryFieldRow(label: "Requirements", value: requirementsSubtitle(signature.requirements))
            } else {
                ForEach(Array(signature.requirements.requirementKinds.enumerated()), id: \.offset) { item in
                    BinaryFieldRow(label: "Requirement \(item.offset + 1)", value: item.element)
                }
            }
        }

        BinaryExpandableCard(
            title: "Entitlements",
            subtitle: entitlementsSubtitle(signature),
            systemImage: "key",
            status: integrity?.check(.entitlements).map { BinaryStatusPresentation($0.status) }
        ) {
            Text("Entitlements are the capabilities the code claims, such as push notifications or an app group. Only their names are shown; values are never displayed or exported.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            BinaryFieldRow(label: "DER form", value: signature.hasDEREntitlements ? "Present" : "Absent",
                           explanation: "Newer iOS versions read entitlements in the binary DER form.")
            if !signature.entitlements.keys.isEmpty {
                NavigationLink {
                    EntitlementKeysView(keys: signature.entitlements.keys)
                } label: {
                    Label("View \(signature.entitlements.keys.count) Entitlement Names", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func cmsCard(_ signature: CodeSignatureSummary) -> some View {
        let check = integrity?.check(.cmsSignature)
        BinaryExpandableCard(
            title: "CMS Signature",
            subtitle: check?.summary ?? cmsStructuralSubtitle(signature),
            systemImage: "signature",
            status: check.map { BinaryStatusPresentation($0.status) }
        ) {
            Text("The CMS signature is the cryptographic signature over the CodeDirectory, made with the signer's private key and carrying the signer's certificates.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch integrity?.cms {
            case .none:
                BinaryFieldRow(label: "Status", value: "Verification is still running.")
            case .some(.absent), .some(.empty):
                BinaryFieldRow(label: "Status", value: "No CMS signature",
                               explanation: "Ad-hoc and linker-signed code carries no CMS signature, so it names no signer.")
            case .some(.unreadable(let reason)):
                BinaryFieldRow(label: "Status", value: "Not evaluated", explanation: reason)
            case .some(.evaluated(let evaluation)):
                if let signer = evaluation.signer {
                    BinaryFieldRow(label: "Signer", value: signer.commonName ?? "Unnamed certificate")
                    if let team = signer.organizationalUnit {
                        BinaryFieldRow(label: "Signer team", value: team)
                    }
                    if let issuer = signer.issuerCommonName {
                        BinaryFieldRow(label: "Issued by", value: issuer)
                    }
                    BinaryFieldRow(label: "Certificate validity",
                                   value: "\(signer.notValidBefore.formatted(date: .abbreviated, time: .omitted)) – \(signer.notValidAfter.formatted(date: .abbreviated, time: .omitted))",
                                   explanation: "As declared in the certificate. ZynSign does not evaluate whether the certificate is trusted or revoked.")
                    BinaryFieldRow(label: "Key", value: signer.keyDescription)
                } else if let note = evaluation.signerCertificateNote {
                    BinaryFieldRow(label: "Signer", value: "Not identified", explanation: note)
                }
                BinaryFieldRow(label: "Digest", value: evaluation.digestAlgorithmName ?? "Unknown")
                BinaryFieldRow(label: "Message digest", value: bindingText(evaluation.binding))
                BinaryFieldRow(label: "Signature check", value: signatureText(evaluation.signature))
                if let signingTime = evaluation.declaredSigningTime {
                    BinaryFieldRow(label: "Declared signing time", value: BinaryFormat.dateTime(signingTime),
                                   explanation: "Stated by the signer's own clock; it is not a trusted timestamp.")
                }
                BinaryFieldRow(label: "Certificates embedded", value: evaluation.certificateCount.formatted())
                if evaluation.hasUnsignedAttributes {
                    BinaryFieldRow(label: "Unsigned attributes", value: "Present",
                                   explanation: "Usually a timestamp. They are outside the signature and ZynSign does not interpret them.")
                }
            }
            if let check {
                Text(check.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Text

    private struct SlotRowValue {
        let number: Int
        let isBound: Bool
        let result: SpecialSlotVerificationResult?
    }

    private func slotRows(primary: CodeDirectorySummary, results: [SpecialSlotVerificationResult]) -> [SlotRowValue] {
        var rows = primary.specialSlots.map { slot in
            SlotRowValue(number: slot.number, isBound: slot.isBound, result: results.first { $0.number == slot.number })
        }
        for result in results where !rows.contains(where: { $0.number == result.number }) {
            rows.append(SlotRowValue(number: result.number, isBound: false, result: result))
        }
        return rows.sorted { $0.number < $1.number }
    }

    private func pageHashingSubtitle(_ directory: CodeDirectorySummary) -> String {
        let size = directory.pageSize.map { BinaryFormat.memory($0) + " pages" } ?? "Unpaged"
        return "\(directory.pageCount.formatted()) × \(size) · \(directory.hashType.displayName)"
    }

    private func requirementsSubtitle(_ requirements: RequirementsSummary) -> String {
        switch requirements.state {
        case .absent: return "No requirement set"
        case .malformed: return "Malformed"
        case .unsupported: return "Unrecognised requirement kinds"
        case .parsed:
            return requirements.count == 0 ? "Empty requirement set" : requirements.requirementKinds.joined(separator: ", ")
        }
    }

    private func entitlementsSubtitle(_ signature: CodeSignatureSummary) -> String {
        switch signature.entitlements {
        case .absent: return "No entitlements"
        case .malformed: return "Malformed entitlements"
        case .present(let keys): return keys.count == 1 ? "1 entitlement" : "\(keys.count) entitlements"
        }
    }

    private func cmsStructuralSubtitle(_ signature: CodeSignatureSummary) -> String {
        guard let bytes = signature.cmsPayloadByteCount else { return "No CMS signature" }
        return bytes == 0 ? "Empty (ad-hoc)" : "\(BinaryFormat.bytes(bytes)) — verifying"
    }

    private func bindingText(_ binding: CMSSignatureBinding) -> String {
        switch binding {
        case .matches(let slot): return slot == 0 ? "Matches the CodeDirectory" : "Matches an alternate CodeDirectory"
        case .mismatch: return "Does not match any CodeDirectory"
        case .notCompared(let reason): return "Not compared — \(reason)"
        }
    }

    private func signatureText(_ check: CMSSignatureCheck) -> String {
        switch check {
        case .verified: return "Verifies with the embedded signer certificate"
        case .invalid: return "Does not verify"
        case .notPerformed(let reason): return "Not checked — \(reason)"
        }
    }
}

/// One special slot: what it binds, whether it is bound, and what
/// recomputing it established.
struct SpecialSlotRow: View {
    let number: Int
    let isBound: Bool
    let result: SpecialSlotVerificationResult?

    var body: some View {
        let title = CodeDirectorySpecialSlotSummary.title(for: number)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: ZSpacing.xs)
                if let result {
                    BinaryStatusBadge(presentation: BinaryStatusPresentation(
                        text: result.outcome.displayName,
                        systemImage: BinaryStatusPresentation(result.status).systemImage,
                        kind: BinaryStatusPresentation(result.status).kind
                    ), subject: title)
                } else {
                    Text(isBound ? "Bound" : "Not bound")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(result?.outcome.explanation ?? CodeDirectorySpecialSlotSummary.explanation(for: number))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The names of the entitlements a signature claims. Values are deliberately
/// not shown.
struct EntitlementKeysView: View {
    let keys: [String]

    var body: some View {
        List {
            Section {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(minHeight: 36, alignment: .leading)
                }
            } footer: {
                Text("Only entitlement names are shown. Values can include identifiers and group names, so ZynSign never displays or exports them. Whether a provisioning profile allows these entitlements is not evaluated here.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Entitlements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - CodeDirectory viewer

/// Every CodeDirectory of a signature, one at a time, each field with a
/// plain-language explanation.
struct CodeDirectoryDetailView: View {
    let signature: CodeSignatureSummary
    @State private var selectedSlot: UInt32 = 0

    var body: some View {
        let directory = signature.codeDirectories.first { $0.slotNumber == selectedSlot }
            ?? signature.primaryCodeDirectory
        return List {
            if signature.codeDirectories.count > 1 {
                Section {
                    Picker("CodeDirectory", selection: $selectedSlot) {
                        ForEach(signature.codeDirectories) { item in
                            Text("\(item.slotLabel) · \(item.hashType.displayName)").tag(item.slotNumber)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("CodeDirectories")
                } footer: {
                    Text("A signature can carry one CodeDirectory per hash algorithm, so older and newer systems can each check one they understand.")
                }
            }
            if let directory {
                Section("Essentials") {
                    BinaryFieldRow(label: "Version", value: directory.versionText,
                                   explanation: "The format version. Newer versions add fields such as the team ID and the executable segment.")
                    BinaryFieldRow(label: "Hash algorithm", value: directory.hashType.displayName,
                                   explanation: "The algorithm used for every page hash and special slot in this CodeDirectory.")
                    BinaryFieldRow(label: "Page size", value: directory.pageSize.map { BinaryFormat.memory($0) } ?? "Unpaged",
                                   explanation: "How much code each page hash covers. iOS code is usually hashed in 4 KB or 16 KB pages.")
                    BinaryFieldRow(label: "Number of pages", value: directory.pageCount.formatted(),
                                   explanation: "How many page hashes the CodeDirectory holds — one for each page of code.")
                    BinaryFieldRow(label: "Identifier", value: directory.identifier,
                                   explanation: "The code's signing identifier, usually the bundle identifier.")
                    BinaryFieldRow(label: "Team ID", value: directory.teamIdentifier ?? "Not recorded",
                                   explanation: directory.teamIdentifier == nil
                                    ? "This CodeDirectory records no team ID, as is normal for ad-hoc signatures and older versions."
                                    : "The developer team whose certificate signed the code.")
                }
                Section("Coverage") {
                    BinaryFieldRow(label: "Code covered", value: BinaryFormat.bytesDetailed(Int(clamping: directory.codeLimit)),
                                   explanation: "The length of code the page hashes cover: everything before the signature.")
                    BinaryFieldRow(label: "Special slots", value: "\(directory.boundSpecialSlotCount) of \(directory.specialSlots.count) bound",
                                   explanation: "Slots that bind the Info.plist, resource seal, requirements, and entitlements.")
                    if let cdHash = directory.cdHashText {
                        BinaryFieldRow(label: "CDHash", value: cdHash,
                                       explanation: "The hash of this CodeDirectory. It uniquely identifies the signature.", monospaced: true)
                    }
                }
                Section("Behaviour") {
                    BinaryFieldRow(label: "Flags", value: directory.decodedFlags.summary,
                                   explanation: "Options that change how the system treats the signed code.")
                    ForEach(directory.decodedFlags.known) { flag in
                        BinaryFieldRow(label: flag.name, value: "Set", explanation: flag.explanation)
                    }
                    if let runtime = directory.runtimeVersion {
                        BinaryFieldRow(label: "Runtime version", value: runtime.description,
                                       explanation: "The SDK version the hardened runtime's behaviour is based on.")
                    }
                    if let segmentFlags = directory.decodedExecutableSegmentFlags {
                        BinaryFieldRow(label: "Executable segment", value: segmentFlags.summary,
                                       explanation: "Properties of the executable's code segment, such as whether it is the main binary.")
                    }
                }
                Section {
                    BinaryAdvancedDetails {
                        BinaryFieldRow(label: "Slot", value: MachOHexadecimal.text(UInt64(directory.slotNumber)), monospaced: true)
                        BinaryFieldRow(label: "Raw flags", value: MachOHexadecimal.text(UInt64(directory.flags)), monospaced: true)
                        BinaryFieldRow(label: "Hash size", value: "\(directory.hashSize) bytes")
                        BinaryFieldRow(label: "Platform byte", value: "\(directory.platform)")
                        BinaryFieldRow(label: "Blob size", value: BinaryFormat.bytesDetailed(directory.byteCount))
                        if let base = directory.executableSegmentBase, let limit = directory.executableSegmentLimit {
                            BinaryFieldRow(label: "Executable segment range", value: "\(MachOHexadecimal.text(base)) + \(MachOHexadecimal.text(limit))", monospaced: true)
                        }
                        BinaryFieldRow(label: "Scatter table", value: directory.hasScatter ? "Present" : "Absent")
                        BinaryFieldRow(label: "Pre-encryption hashes", value: directory.hasPreEncryptionHashes ? "Present" : "Absent")
                        BinaryFieldRow(label: "Linkage", value: directory.hasLinkage ? "Present" : "Absent")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("CodeDirectory")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let primary = signature.primaryCodeDirectory, !signature.codeDirectories.contains(where: { $0.slotNumber == selectedSlot }) {
                selectedSlot = primary.slotNumber
            }
        }
    }
}

// MARK: - Hash & integrity

/// Page hashes, special slots, the resource seal, and the verification time.
struct HashIntegrityPanel: View {
    let report: BinaryInspectionReport
    let architecture: BinaryArchitectureReport
    let sliceIntegrity: ArchitectureIntegrityResult?
    let verificationFraction: Double?
    let sealedState: BinaryInspectorModel.SealedResourceState?
    let canVerifySealedFiles: Bool
    let verifySealedFiles: () -> Void

    var body: some View {
        ZCard {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                if let integrity = report.integrity {
                    pageHashes(integrity)
                    Divider()
                    specialSlots
                    Divider()
                    resourceIntegrity(integrity)
                    Divider()
                    BinaryFieldRow(label: "Verified", value: BinaryFormat.dateTime(integrity.verifiedAt),
                                   explanation: "When ZynSign hashed and compared this executable on this device.")
                } else {
                    VStack(alignment: .leading, spacing: ZSpacing.xs) {
                        Text("Verifying on this device…")
                            .font(.headline)
                        ProgressView(value: verificationFraction ?? 0)
                            .accessibilityLabel("Verification progress")
                            .accessibilityValue(BinaryFormat.percent(verificationFraction ?? 0))
                        Text("Every page of code is being hashed again and compared with the signature. Results appear here when it finishes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func pageHashes(_ integrity: BinaryIntegrityReport) -> some View {
        let results = sliceIntegrity?.pageHashes ?? []
        let checked = results.reduce(0) { $0 + $1.checkedPageCount }
        let total = results.reduce(0) { $0 + $1.pageCount }
        let mismatched = results.reduce(0) { $0 + $1.mismatchCount }
        let check = sliceIntegrity?.check(.pageHashes)
        return VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                Text("Page hashes verified")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: ZSpacing.xs)
                if let check {
                    BinaryStatusBadge(presentation: BinaryStatusPresentation(check.status), subject: "Page hashes")
                }
            }
            if total > 0 {
                ProgressView(value: Double(max(0, checked - mismatched)), total: Double(max(total, 1)))
                    .tint((mismatched > 0 ? ZStatusBadge.Kind.error : ZStatusBadge.Kind.success).color)
                    .accessibilityHidden(true)
                Text("\((checked - mismatched).formatted()) of \(total.formatted()) pages match in \(architecture.name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let result = results.first(where: { $0.mismatchCount > 0 }) {
                Text("First mismatched pages: " + result.mismatchedPageIndices.prefix(12).map { String($0) }.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let check, check.status == .notPerformed || check.status == .notApplicable {
                Text(check.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var specialSlots: some View {
        let results = (sliceIntegrity?.specialSlots ?? []).filter { $0.status != .notApplicable }
        let primarySlot = sliceIntegrity?.pageHashes.map(\.codeDirectorySlot).min() ?? 0
        let primaryResults = results.filter { $0.codeDirectorySlot == primarySlot }
        let check = sliceIntegrity?.check(.specialSlots)
        return VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                Text("Special slots verified")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: ZSpacing.xs)
                if let check {
                    BinaryStatusBadge(presentation: BinaryStatusPresentation(check.status), subject: "Special slots")
                }
            }
            if primaryResults.isEmpty {
                Text(check?.detail ?? "No special slots are bound.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(primaryResults) { result in
                    HStack {
                        Text(result.title)
                            .font(.footnote)
                        Spacer(minLength: ZSpacing.xs)
                        Text(result.outcome.displayName)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func resourceIntegrity(_ integrity: BinaryIntegrityReport) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                Text("Resource integrity")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: ZSpacing.xs)
                BinaryStatusBadge(presentation: BinaryStatusPresentation(integrity.resourceIntegrity.status), subject: "Resource integrity")
            }
            Text(integrity.resourceIntegrity.summary)
                .font(.footnote.weight(.medium))
            Text(integrity.resourceIntegrity.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if canVerifySealedFiles, case .sealedAndBound = integrity.resourceIntegrity {
                sealedFiles
            }
        }
    }

    @ViewBuilder
    private var sealedFiles: some View {
        switch sealedState {
        case .none:
            Button(action: verifySealedFiles) {
                Label("Verify Sealed Files", systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Re-hashes every file the resource seal lists and compares each with its recorded hash. Large apps take longer.")
        case .some(.running):
            HStack(spacing: ZSpacing.xs) {
                ProgressView().controlSize(.small)
                Text("Re-hashing sealed files…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .some(.failed(let message)):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Try Again", action: verifySealedFiles)
                .frame(minHeight: 44)
        case .some(.finished(let result)):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.summary)
                        .font(.footnote.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: ZSpacing.xs)
                    BinaryStatusBadge(presentation: BinaryStatusPresentation(result.status), subject: "Sealed files")
                }
                ForEach(result.mismatchedPaths, id: \.self) { path in
                    Text("Changed: \(path)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                ForEach(result.missingPaths, id: \.self) { path in
                    Text("Missing: \(path)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                ForEach(result.unreadablePaths, id: \.self) { path in
                    Text("Not checked: \(path)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text("\(result.skippedCount.formatted()) entries were skipped: symbolic links, nested code (verified as its own executable), and entries without a SHA-256 hash. Files the seal does not list are not detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Checked \(BinaryFormat.dateTime(result.verifiedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Signature timeline

/// The signature's construction as a vertical timeline.
struct SignatureTimelineView: View {
    let steps: [BinarySignatureTimelineStep]

    var body: some View {
        ZCard {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { position, step in
                    HStack(alignment: .top, spacing: ZSpacing.sm) {
                        VStack(spacing: 0) {
                            Image(systemName: BinaryStatusPresentation(step.state).systemImage)
                                .font(.title3)
                                .foregroundStyle(iconColor(step.state))
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            if position < steps.count - 1 {
                                Rectangle()
                                    .fill(Color(.separator))
                                    .frame(width: 2)
                                    .frame(maxHeight: .infinity)
                                    .accessibilityHidden(true)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .font(.subheadline.weight(.semibold))
                            Text(step.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let timestamp = step.timestamp {
                                Text(BinaryFormat.dateTime(timestamp))
                                    .font(.caption.weight(.medium))
                                if let note = step.timestampNote {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.bottom, position < steps.count - 1 ? ZSpacing.md : 0)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(spokenLabel(step, position: position))
                }
            }
        }
    }

    private func iconColor(_ state: BinarySignatureTimelineStep.State) -> Color {
        BinaryStatusPresentation(state).kind.color
    }

    private func spokenLabel(_ step: BinarySignatureTimelineStep, position: Int) -> String {
        var label = "Step \(position + 1) of \(steps.count): \(step.title). \(step.state.displayName). \(step.detail)"
        if let timestamp = step.timestamp {
            label += " \(BinaryFormat.dateTime(timestamp))."
            if let note = step.timestampNote { label += " \(note)" }
        }
        return label
    }
}

// MARK: - Verification details

/// The Verification Details table: one row per check with its status, and
/// the reason whenever a check could not be completed.
struct VerificationDetailsView: View {
    let report: BinaryInspectionReport
    let nestedSignatures: BinaryVerificationCheck?

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            if let integrity = report.integrity {
                ForEach(rows(integrity)) { check in
                    VerificationCheckRow(check: check)
                }
                Text("Verified \(BinaryFormat.dateTime(integrity.verifiedAt)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ZCard {
                    HStack(spacing: ZSpacing.sm) {
                        ProgressView()
                        Text("Verification is running. The results will appear here when every page has been compared.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func rows(_ integrity: BinaryIntegrityReport) -> [BinaryVerificationCheck] {
        let order: [BinaryVerificationCheckKind] = [
            .codeDirectory, .pageHashes, .specialSlots, .cmsSignature,
            .requirements, .entitlements, .nestedSignatures, .certificateTrust,
        ]
        var byKind: [BinaryVerificationCheckKind: BinaryVerificationCheck] = [:]
        for check in integrity.checks {
            byKind[check.kind] = check
        }
        if let nestedSignatures {
            byKind[.nestedSignatures] = nestedSignatures
        } else {
            byKind[.nestedSignatures] = BinaryVerificationCheck(
                kind: .nestedSignatures,
                status: .notApplicable,
                summary: "Checked from the main executable",
                detail: "Nested code is verified bundle-wide on the main executable's page."
            )
        }
        return order.compactMap { byKind[$0] }
    }
}

/// One verification check, expandable to its explanation.
struct VerificationCheckRow: View {
    let check: BinaryVerificationCheck
    @State private var isExpanded = false

    var body: some View {
        ZCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    Text(check.detail)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("What this check means: \(check.kind.explanation)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, ZSpacing.xs)
            } label: {
                HStack(alignment: .center, spacing: ZSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.kind.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(check.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: ZSpacing.xs)
                    BinaryStatusBadge(presentation: BinaryStatusPresentation(check.status), subject: check.kind.title)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(check.kind.title): \(check.status.displayName). \(check.summary)")
        .accessibilityHint(isExpanded ? "Collapses the explanation." : "Expands the explanation.")
    }
}
