import Foundation

/// What the caller knows about the executable being verified, beyond its
/// bytes.
struct BinaryVerificationContext: Equatable {
    /// Architecture names by slice index, for table text.
    let architectureNames: [Int: String]
    /// The bundle content the signature may bind.
    let resources: BinaryBoundResources
    /// Whether an entitlement set is normally expected: the main executable
    /// and app extensions of a certificate-signed app carry one; frameworks
    /// and libraries normally do not.
    let expectsEntitlements: Bool
}

/// Re-computes and compares what an existing embedded code signature
/// declares, on this device, from the executable's own bytes.
///
/// For every signed architecture it:
///
/// - checks each CodeDirectory is present and uses a hash type ZynSign can
///   compute;
/// - hashes every page of code again, with the CodeDirectory's own algorithm
///   and page size, and compares each result with the recorded page hash;
/// - hashes the content each special slot binds — the Info.plist and resource
///   seal from the bundle, the requirements and entitlements from the
///   signature itself — and compares it with the bound digest;
/// - hands the CMS signature to the injected `CodeSignatureCMSVerifying`, which
///   compares its message digest with the CodeDirectories and checks the
///   signature with the platform primitive;
/// - decodes the requirement set and the entitlements.
///
/// It never evaluates certificate trust, revocation, or provisioning, and it
/// never concludes that iOS will install or launch the app. A check that
/// cannot be completed is recorded as `notPerformed` with the reason. The
/// verifier reads the bytes it is given and writes nothing.
struct BinarySignatureVerifier {

    /// How often, in pages, progress is reported and cancellation checked.
    static let progressInterval = 256

    private let digest: any MessageDigest
    private let cmsVerifier: any CodeSignatureCMSVerifying
    private let now: () -> Date

    init(
        digest: any MessageDigest,
        cmsVerifier: any CodeSignatureCMSVerifying,
        now: @escaping () -> Date = { Date() }
    ) {
        self.digest = digest
        self.cmsVerifier = cmsVerifier
        self.now = now
    }

    /// Verifies every architecture of `image`.
    ///
    /// - Parameters:
    ///   - image: The image parsed from `bytes`.
    ///   - bytes: The exact bytes `image` was parsed from, starting at index
    ///     zero.
    ///   - context: Architecture names, bound bundle content, and
    ///     expectations.
    ///   - progress: Called with the pages hashed so far and the total.
    /// - Throws: `CancellationError` when the task is cancelled. Every other
    ///   outcome is recorded in the report.
    func verify(
        image: MachOImage,
        bytes: Data,
        context: BinaryVerificationContext,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> BinaryIntegrityReport {
        let slices = image.slices
        var tracker = PageProgress(
            total: slices.reduce(0) { total, slice in
                total + (slice.embeddedSignature?.superBlob.entries
                    .compactMap(\.codeDirectory)
                    .reduce(0) { $0 + $1.codeSlotCount } ?? 0)
            },
            report: progress
        )
        var results: [ArchitectureIntegrityResult] = []
        results.reserveCapacity(slices.count)
        for (index, slice) in slices.enumerated() {
            try Task.checkCancellation()
            results.append(try verifySlice(slice, index: index, bytes: bytes, context: context, tracker: &tracker))
        }
        tracker.finish()

        let checks = BinaryIntegrityAggregation.aggregate(results, architectureNames: context.architectureNames)
        return BinaryIntegrityReport(
            architectures: results,
            checks: checks,
            resourceIntegrity: resourceIntegrity(results: results, resources: context.resources),
            verifiedAt: now()
        )
    }

    // MARK: - One slice

    private func verifySlice(
        _ slice: MachOSlice,
        index: Int,
        bytes: Data,
        context: BinaryVerificationContext,
        tracker: inout PageProgress
    ) throws -> ArchitectureIntegrityResult {
        guard let embedded = slice.embeddedSignature else {
            return ArchitectureIntegrityResult(
                architectureIndex: index,
                isSigned: false,
                pageHashes: [],
                specialSlots: [],
                cms: .absent,
                checks: unsignedChecks()
            )
        }

        let entries = embedded.superBlob.entries
        let directories = entries
            .compactMap { entry -> (entry: MachOSignatureEntry, directory: MachOCodeDirectory)? in
                guard let directory = entry.codeDirectory else { return nil }
                return (entry: entry, directory: directory)
            }
            .sorted { $0.entry.slotNumber < $1.entry.slotNumber }
        let summary = CodeSignatureSummary.make(slice: slice, bytes: bytes)
        let form = summary?.form ?? .incomplete

        var pageResults: [PageHashVerificationResult] = []
        var slotResults: [SpecialSlotVerificationResult] = []
        for item in directories {
            pageResults.append(try verifyPages(of: item.directory, slot: item.entry.slotNumber, slice: slice, bytes: bytes, tracker: &tracker))
            slotResults.append(contentsOf: verifySpecialSlots(
                of: item.directory,
                slot: item.entry.slotNumber,
                entries: entries,
                bytes: bytes,
                resources: context.resources,
                expectsResourceBinding: form == .certificate
            ))
        }

        let cms = assessCMS(entries: entries, directories: directories.map { $0.entry }, bytes: bytes)
        let metadata = EmbeddedSigningMetadataInspector().inspect(slice: slice, artifact: bytes)

        let checks: [BinaryVerificationCheck] = [
            codeDirectoryCheck(directories: directories.map { $0.directory }),
            pageHashCheck(pageResults),
            specialSlotCheck(slotResults),
            cmsCheck(cms, form: form),
            requirementsCheck(metadata.requirements, form: form),
            entitlementsCheck(metadata.entitlements, hasDER: entries.contains { $0.slot == .derEntitlements }, form: form, expected: context.expectsEntitlements),
            certificateTrustCheck(cms),
        ]
        return ArchitectureIntegrityResult(
            architectureIndex: index,
            isSigned: true,
            pageHashes: pageResults,
            specialSlots: slotResults,
            cms: cms,
            checks: checks
        )
    }

    // MARK: - Page hashes

    private func verifyPages(
        of directory: MachOCodeDirectory,
        slot: UInt32,
        slice: MachOSlice,
        bytes: Data,
        tracker: inout PageProgress
    ) throws -> PageHashVerificationResult {
        let pageSize: Int? = directory.pageSizeExponent == 0 ? nil : 1 << Int(directory.pageSizeExponent)
        func notPerformed(_ reason: String) -> PageHashVerificationResult {
            tracker.skip(directory.codeSlotCount)
            return .notPerformed(
                codeDirectorySlot: slot,
                hashType: directory.hashType,
                pageSize: pageSize,
                pageCount: directory.codeSlotCount,
                reason: reason
            )
        }
        guard let algorithm = directory.hashType.digestAlgorithm else {
            return notPerformed("The CodeDirectory uses a hash type ZynSign does not compute (\(directory.hashType.displayName)).")
        }
        guard directory.scatter == nil else {
            return notPerformed("The CodeDirectory uses a scatter table, a legacy layout ZynSign does not re-hash.")
        }
        guard bytes.startIndex == 0,
              let limit = Int(exactly: directory.effectiveCodeLimit),
              limit <= slice.fileRange.count else {
            return notPerformed("The code limit the CodeDirectory declares does not fit inside the architecture slice.")
        }

        let sliceStart = slice.fileRange.lowerBound
        let pageBytes = pageSize ?? max(limit, 1)
        var mismatched: [Int] = []
        var mismatchCount = 0
        var checked = 0
        for pageIndex in 0..<directory.codeSlotCount {
            let start = pageIndex * pageBytes
            let end = min(start + pageBytes, limit)
            guard start < end, pageIndex < directory.codeHashes.count else {
                mismatchCount += 1
                if mismatched.count < PageHashVerificationResult.maximumReportedMismatches {
                    mismatched.append(pageIndex)
                }
                continue
            }
            let page = bytes[(sliceStart + start)..<(sliceStart + end)]
            let computed: Digest
            do {
                computed = try digest.digest(page, algorithm: algorithm)
            } catch {
                return notPerformed("The \(directory.hashType.displayName) digest could not be computed on this device.")
            }
            checked += 1
            if Data(computed.bytes.prefix(directory.hashSize)) != directory.codeHashes[pageIndex] {
                mismatchCount += 1
                if mismatched.count < PageHashVerificationResult.maximumReportedMismatches {
                    mismatched.append(pageIndex)
                }
            }
            if tracker.advance() {
                try Task.checkCancellation()
            }
        }
        return PageHashVerificationResult(
            codeDirectorySlot: slot,
            hashType: directory.hashType,
            pageSize: pageSize,
            pageCount: directory.codeSlotCount,
            checkedPageCount: checked,
            mismatchedPageIndices: mismatched,
            mismatchCount: mismatchCount,
            notPerformedReason: nil
        )
    }

    // MARK: - Special slots

    private func verifySpecialSlots(
        of directory: MachOCodeDirectory,
        slot: UInt32,
        entries: [MachOSignatureEntry],
        bytes: Data,
        resources: BinaryBoundResources,
        expectsResourceBinding: Bool
    ) -> [SpecialSlotVerificationResult] {
        var results: [SpecialSlotVerificationResult] = []
        let declared = directory.specialSlots.sorted { $0.slotNumber > $1.slotNumber }
        let declaredNumbers = Set(declared.map { -$0.slotNumber })
        for special in declared {
            let number = -special.slotNumber
            let outcome = slotOutcome(
                number: number,
                special: special,
                directory: directory,
                entries: entries,
                bytes: bytes,
                resources: resources
            )
            results.append(SpecialSlotVerificationResult(codeDirectorySlot: slot, number: number, outcome: outcome))
        }

        // Content the signature carries or the bundle holds, in a slot this
        // CodeDirectory does not even declare, is unprotected.
        for entry in entries {
            let number: Int
            switch entry.slot {
            case .requirements: number = 2
            case .entitlements: number = 5
            case .derEntitlements: number = 7
            default: continue
            }
            if !declaredNumbers.contains(number) {
                results.append(SpecialSlotVerificationResult(codeDirectorySlot: slot, number: number, outcome: .contentNotBound))
            }
        }
        if expectsResourceBinding {
            if case .available = resources.infoPlist, !declaredNumbers.contains(1) {
                results.append(SpecialSlotVerificationResult(codeDirectorySlot: slot, number: 1, outcome: .contentNotBound))
            }
            if case .available = resources.codeResources, !declaredNumbers.contains(3) {
                results.append(SpecialSlotVerificationResult(codeDirectorySlot: slot, number: 3, outcome: .contentNotBound))
            }
        }
        return results.sorted { $0.number < $1.number }
    }

    private func slotOutcome(
        number: Int,
        special: MachOSpecialHashSlot,
        directory: MachOCodeDirectory,
        entries: [MachOSignatureEntry],
        bytes: Data,
        resources: BinaryBoundResources
    ) -> SpecialSlotOutcome {
        let isBound = special.hasNonzeroBytes
        let content: BoundResourceContent
        switch number {
        case 1:
            content = resources.infoPlist
        case 3:
            content = resources.codeResources
        case 4, 6:
            return isBound
                ? .notChecked("ZynSign does not know which content this reserved slot binds, so it was not compared.")
                : .unbound
        case 2, 5, 7, 8, 9, 10, 11:
            if let entry = entries.first(where: { $0.slotNumber == UInt32(number) }),
               entry.fileRange.lowerBound >= bytes.startIndex,
               entry.fileRange.upperBound <= bytes.endIndex {
                content = .available(bytes.subdata(in: entry.fileRange))
            } else {
                content = .missing
            }
        default:
            return isBound
                ? .notChecked("ZynSign does not recognise this special slot, so it was not compared.")
                : .unbound
        }

        switch content {
        case .available(let data):
            guard isBound else { return .contentNotBound }
            guard let algorithm = directory.hashType.digestAlgorithm else {
                return .notChecked("The CodeDirectory uses a hash type ZynSign does not compute.")
            }
            do {
                let computed = try digest.digest(data, algorithm: algorithm)
                return Data(computed.bytes.prefix(directory.hashSize)) == special.hash ? .matches : .mismatch
            } catch {
                return .notChecked("The digest could not be computed on this device.")
            }
        case .missing:
            return isBound ? .boundButContentMissing : .unbound
        case .unreadable(let reason):
            return isBound ? .notChecked(reason) : .unbound
        case .notApplicable:
            return isBound
                ? .notChecked("This executable is not inside a bundle of its own, so there is no content to compare with this slot.")
                : .unbound
        }
    }

    // MARK: - CMS

    private func assessCMS(
        entries: [MachOSignatureEntry],
        directories: [MachOSignatureEntry],
        bytes: Data
    ) -> CodeSignatureCMSAssessment {
        guard let entry = entries.first(where: { $0.slot == .cms }) else { return .absent }
        let payloadStart = entry.fileRange.lowerBound + 8
        guard payloadStart <= entry.fileRange.upperBound,
              entry.fileRange.upperBound <= bytes.endIndex else {
            return .unreadable("The CMS blob's declared range does not fit inside the signature.")
        }
        guard payloadStart < entry.fileRange.upperBound else { return .empty }
        let payload = bytes.subdata(in: payloadStart..<entry.fileRange.upperBound)
        let contents = directories.map {
            CodeSignatureCMSContent(codeDirectorySlot: $0.slotNumber, bytes: bytes.subdata(in: $0.fileRange))
        }
        return cmsVerifier.assess(cmsPayload: payload, codeDirectories: contents)
    }

    // MARK: - Checks

    private func unsignedChecks() -> [BinaryVerificationCheck] {
        let notApplicable = "This architecture carries no code signature."
        return [
            BinaryVerificationCheck(kind: .codeDirectory, status: .warning, summary: "No code signature", detail: notApplicable),
            BinaryVerificationCheck(kind: .pageHashes, status: .notApplicable, summary: "Not signed", detail: notApplicable),
            BinaryVerificationCheck(kind: .specialSlots, status: .notApplicable, summary: "Not signed", detail: notApplicable),
            BinaryVerificationCheck(kind: .cmsSignature, status: .notApplicable, summary: "Not signed", detail: notApplicable),
            BinaryVerificationCheck(kind: .requirements, status: .notApplicable, summary: "Not signed", detail: notApplicable),
            BinaryVerificationCheck(kind: .entitlements, status: .notApplicable, summary: "Not signed", detail: notApplicable),
            BinaryVerificationCheck(kind: .certificateTrust, status: .notApplicable, summary: "Not signed", detail: notApplicable),
        ]
    }

    private func codeDirectoryCheck(directories: [MachOCodeDirectory]) -> BinaryVerificationCheck {
        guard let primary = directories.first else {
            return BinaryVerificationCheck(
                kind: .codeDirectory,
                status: .failed,
                summary: "No CodeDirectory",
                detail: "The signature carries no CodeDirectory, so nothing in it binds the code."
            )
        }
        let hashNames = directories.map(\.hashType.displayName).joined(separator: " + ")
        if directories.contains(where: { $0.hashType.digestAlgorithm == nil }) {
            return BinaryVerificationCheck(
                kind: .codeDirectory,
                status: .warning,
                summary: "Unrecognised hash type",
                detail: "A CodeDirectory uses a hash type ZynSign does not compute (\(hashNames))."
            )
        }
        let versionMajor = (primary.version >> 16) & 0xFF
        let versionMinor = (primary.version >> 8) & 0xFF
        let summary = directories.count == 1
            ? "Version \(versionMajor).\(versionMinor) · \(hashNames) · \(primary.codeSlotCount.formatted()) pages"
            : "\(directories.count) CodeDirectories · \(hashNames)"
        return BinaryVerificationCheck(
            kind: .codeDirectory,
            status: .passed,
            summary: summary,
            detail: "Every CodeDirectory was read by ZynSign's bounded parser: its version is supported, its page coverage agrees with its code limit, and its hash type is one ZynSign computes."
        )
    }

    private func pageHashCheck(_ results: [PageHashVerificationResult]) -> BinaryVerificationCheck {
        guard !results.isEmpty else {
            return BinaryVerificationCheck(
                kind: .pageHashes,
                status: .notPerformed,
                summary: "No page hashes",
                detail: "The signature carries no CodeDirectory whose page hashes could be compared."
            )
        }
        let status = BinaryCheckStatus.worst(results.map(\.status))
        let checked = results.reduce(0) { $0 + $1.checkedPageCount }
        let mismatches = results.reduce(0) { $0 + $1.mismatchCount }
        switch status {
        case .failed:
            let first = results.first { $0.mismatchCount > 0 }?.mismatchedPageIndices.prefix(5).map { String($0) } ?? []
            return BinaryVerificationCheck(
                kind: .pageHashes,
                status: .failed,
                summary: "\(mismatches.formatted()) of \(checked.formatted()) page hashes do not match",
                detail: "The code changed after it was signed. First mismatched pages: \(first.joined(separator: ", ")). Re-signing records new page hashes."
            )
        case .notPerformed:
            let reason = results.first { $0.notPerformedReason != nil }?.notPerformedReason ?? "The page hashes could not be compared."
            return BinaryVerificationCheck(
                kind: .pageHashes,
                status: .notPerformed,
                summary: "Page hashes not compared",
                detail: reason
            )
        default:
            let total = results.reduce(0) { $0 + $1.pageCount }
            return BinaryVerificationCheck(
                kind: .pageHashes,
                status: .passed,
                summary: "\(checked.formatted()) of \(total.formatted()) page hashes match",
                detail: "Every page of code was hashed again on this device with the CodeDirectory's own algorithm and page size, and every result equals the recorded hash."
            )
        }
    }

    private func specialSlotCheck(_ results: [SpecialSlotVerificationResult]) -> BinaryVerificationCheck {
        let relevant = results.filter { $0.status != .notApplicable }
        guard !relevant.isEmpty else {
            return BinaryVerificationCheck(
                kind: .specialSlots,
                status: .notApplicable,
                summary: "No special slots bound",
                detail: "The signature binds no Info.plist, resource seal, requirements, or entitlements, which is normal for linker-signed code."
            )
        }
        let status = BinaryCheckStatus.worst(relevant.map(\.status))
        let matched = relevant.filter { $0.outcome == .matches }.count
        let titles = Array(Set(relevant.filter { $0.status == status }.map(\.title))).sorted()
        switch status {
        case .passed:
            return BinaryVerificationCheck(
                kind: .specialSlots,
                status: .passed,
                summary: "\(matched) of \(relevant.count) bound slots match",
                detail: "Each bound slot's content was hashed again and equals the digest the signature recorded: " + Array(Set(relevant.map(\.title))).sorted().joined(separator: ", ") + "."
            )
        case .failed:
            return BinaryVerificationCheck(
                kind: .specialSlots,
                status: .failed,
                summary: "Changed or missing: " + titles.joined(separator: ", "),
                detail: "Content the signature binds no longer matches what was signed, or is missing."
            )
        case .warning:
            return BinaryVerificationCheck(
                kind: .specialSlots,
                status: .warning,
                summary: "Not bound: " + titles.joined(separator: ", "),
                detail: "This content exists but the signature does not bind it, so a change to it would go unnoticed."
            )
        default:
            let reason = relevant.compactMap { result -> String? in
                if case .notChecked(let reason) = result.outcome { return reason }
                return nil
            }.first ?? "Some bound content could not be compared."
            return BinaryVerificationCheck(
                kind: .specialSlots,
                status: .notPerformed,
                summary: "Not compared: " + titles.joined(separator: ", "),
                detail: reason
            )
        }
    }

    private func cmsCheck(_ assessment: CodeSignatureCMSAssessment, form: CodeSignatureForm) -> BinaryVerificationCheck {
        switch assessment {
        case .absent, .empty:
            let summary = form == .linkerSigned ? "No CMS signature — linker-signed" : "No CMS signature — ad-hoc"
            return BinaryVerificationCheck(
                kind: .cmsSignature,
                status: .warning,
                summary: summary,
                detail: "An ad-hoc signature carries no CMS signature, so it names no signer. The code's integrity was still checked above."
            )
        case .unreadable(let reason):
            return BinaryVerificationCheck(kind: .cmsSignature, status: .notPerformed, summary: "CMS signature not evaluated", detail: reason)
        case .evaluated(let evaluation):
            let signerName = evaluation.signer?.commonName ?? "the embedded signer certificate"
            switch (evaluation.binding, evaluation.signature) {
            case (.mismatch, _):
                return BinaryVerificationCheck(
                    kind: .cmsSignature,
                    status: .failed,
                    summary: "Message digest does not match",
                    detail: "The CMS message digest equals no CodeDirectory in the signature, so the signature does not cover this code."
                )
            case (_, .invalid):
                return BinaryVerificationCheck(
                    kind: .cmsSignature,
                    status: .failed,
                    summary: "Signature does not verify",
                    detail: "The CMS signature does not verify with the public key of \(signerName)."
                )
            case (.matches, .verified):
                return BinaryVerificationCheck(
                    kind: .cmsSignature,
                    status: .passed,
                    summary: "Verifies with \(signerName)",
                    detail: "The CMS message digest equals the CodeDirectory's digest, and the signature over it verifies with the embedded signer certificate's public key. Certificate trust is not part of this check."
                )
            case (.matches, .notPerformed(let reason)):
                return BinaryVerificationCheck(
                    kind: .cmsSignature,
                    status: .notPerformed,
                    summary: "Digest bound; signature not checked",
                    detail: "The CMS message digest equals the CodeDirectory's digest, but the signature itself was not checked: \(reason)"
                )
            case (.notCompared(let reason), _):
                return BinaryVerificationCheck(kind: .cmsSignature, status: .notPerformed, summary: "CMS signature not evaluated", detail: reason)
            }
        }
    }

    private func requirementsCheck(_ requirements: CodeSigningRequirements, form: CodeSignatureForm) -> BinaryVerificationCheck {
        let summary = RequirementsSummary(requirements)
        switch summary.state {
        case .absent:
            return BinaryVerificationCheck(
                kind: .requirements,
                status: form == .certificate ? .warning : .notApplicable,
                summary: "No requirement set",
                detail: form == .certificate
                    ? "The signature carries no requirement set. Signing tools normally embed one."
                    : "Ad-hoc and linker-signed code often carries no requirement set."
            )
        case .parsed:
            let text = summary.count == 0
                ? "Empty requirement set"
                : "\(summary.count) requirement(s): " + summary.requirementKinds.joined(separator: ", ")
            return BinaryVerificationCheck(
                kind: .requirements,
                status: .passed,
                summary: text,
                detail: "The requirement set decodes. ZynSign does not evaluate requirement expressions; an empty set means the system derives the designated requirement itself."
            )
        case .unsupported:
            return BinaryVerificationCheck(
                kind: .requirements,
                status: .warning,
                summary: "Unrecognised requirement kinds",
                detail: "The requirement set decodes but uses requirement kinds ZynSign does not model."
            )
        case .malformed:
            return BinaryVerificationCheck(
                kind: .requirements,
                status: .failed,
                summary: "Malformed requirement set",
                detail: "The requirement set's framing does not decode."
            )
        }
    }

    private func entitlementsCheck(
        _ state: EmbeddedEntitlementsState,
        hasDER: Bool,
        form: CodeSignatureForm,
        expected: Bool
    ) -> BinaryVerificationCheck {
        switch state {
        case .absent:
            let isConcern = expected && form == .certificate
            return BinaryVerificationCheck(
                kind: .entitlements,
                status: isConcern ? .warning : .notApplicable,
                summary: "No entitlements",
                detail: isConcern
                    ? "A certificate-signed app normally declares at least its application identifier as an entitlement."
                    : "Frameworks, libraries, and ad-hoc signed code often carry no entitlements."
            )
        case .present(let entitlements):
            let derNote = hasDER
                ? "The DER form newer iOS versions read is also present."
                : "No DER form is present; newer iOS versions read the DER form."
            return BinaryVerificationCheck(
                kind: .entitlements,
                status: .passed,
                summary: "\(entitlements.count) entitlement(s) decode",
                detail: "The entitlements decode as a property list. \(derNote) Whether a provisioning profile allows them is not evaluated here."
            )
        case .malformed:
            return BinaryVerificationCheck(
                kind: .entitlements,
                status: .failed,
                summary: "Malformed entitlements",
                detail: "The entitlements blob does not decode."
            )
        }
    }

    private func certificateTrustCheck(_ assessment: CodeSignatureCMSAssessment) -> BinaryVerificationCheck {
        guard let evaluation = assessment.evaluation, evaluation.signer != nil else {
            return BinaryVerificationCheck(
                kind: .certificateTrust,
                status: .notApplicable,
                summary: "No signer certificate",
                detail: "There is no signer certificate to evaluate."
            )
        }
        return BinaryVerificationCheck(
            kind: .certificateTrust,
            status: .notPerformed,
            summary: "Not evaluated",
            detail: "ZynSign does not evaluate certificate trust: whether the signer certificate chains to Apple, was valid when used, or has been revoked. Passing checks above do not imply trust."
        )
    }

    // MARK: - Resource integrity

    private func resourceIntegrity(
        results: [ArchitectureIntegrityResult],
        resources: BinaryBoundResources
    ) -> ResourceIntegrityStatus {
        guard let signed = results.first(where: \.isSigned) else {
            return .notSealed
        }
        let primarySlot = signed.pageHashes.map(\.codeDirectorySlot).min() ?? 0
        guard let seal = signed.specialSlots.first(where: { $0.number == 3 && $0.codeDirectorySlot == primarySlot }) else {
            return .notSealed
        }
        switch seal.outcome {
        case .matches:
            var count: Int?
            if case .available(let data) = resources.codeResources, let manifest = SealedResourceManifest.read(data) {
                count = manifest.entries.count + manifest.omittedEntryCount
            }
            return .sealedAndBound(sealedFileCount: count)
        case .mismatch:
            return .sealMismatch
        case .boundButContentMissing:
            return .sealMissing
        case .unbound:
            return .notSealed
        case .contentNotBound:
            return .notChecked("The bundle contains a resource seal, but this signature does not bind it, so the resource list is not protected.")
        case .notChecked(let reason):
            return .notChecked(reason)
        }
    }
}

/// Counts pages across every CodeDirectory for progress reporting.
private struct PageProgress {
    let total: Int
    let report: ((Int, Int) -> Void)?
    private(set) var completed = 0

    init(total: Int, report: ((Int, Int) -> Void)?) {
        self.total = total
        self.report = report
    }

    /// Records one page. Returns `true` on each progress interval, when the
    /// caller should also check for cancellation.
    mutating func advance() -> Bool {
        completed += 1
        guard completed % BinarySignatureVerifier.progressInterval == 0 else { return false }
        report?(completed, total)
        return true
    }

    mutating func skip(_ pages: Int) {
        completed += max(0, pages)
    }

    func finish() {
        report?(total, total)
    }
}
