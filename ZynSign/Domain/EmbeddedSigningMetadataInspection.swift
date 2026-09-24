import Foundation

/// The read-only state of an entitlements blob found in an existing
/// signature.
enum EmbeddedEntitlementsState: Equatable {
    /// The slice carries no entitlements slot.
    case absent
    /// The slot's blob framed and decoded into a typed entitlement set.
    case present(CodeSigningEntitlements)
    /// The slot exists but its blob framing or payload failed to decode.
    /// The failure is recorded, never repaired: inspection does not rewrite
    /// signatures.
    case malformed
}

/// The read-only state of a CodeResources digest found in an existing
/// CodeDirectory.
enum EmbeddedCodeResourcesSealState: Equatable {
    /// No embedded signature or CodeDirectory was available to inspect.
    case noCodeDirectory
    /// The CodeDirectory declares no special slot 3.
    case notSealed
    /// Slot 3 exists; its declared digest bytes. Nonzero bytes establish
    /// only that a digest is present, never that it is correct for any
    /// resource tree.
    case sealed(digest: Data)
}

/// A read-only view of the signing metadata embedded in one parsed Mach-O
/// slice.
///
/// This inspector extends the existing ZS-022 parsing surface: it consumes
/// an already-parsed `MachOSlice` plus the artifact bytes that produced it,
/// and classifies the metadata-related entries — the entitlements blob, the
/// requirements blob, and the CodeDirectory's special slots — without
/// mutating a single byte. It performs no digest computation, no signature
/// verification, and no policy decision: a `present` entitlement set is
/// decoded data, not an authorization, and a `sealed` CodeResources digest
/// is a declared value, not a verified one.
struct EmbeddedSigningMetadataInspection: Equatable {

    let entitlements: EmbeddedEntitlementsState
    let requirements: CodeSigningRequirements
    let codeResourcesSeal: EmbeddedCodeResourcesSealState
}

/// Extracts and classifies embedded signing metadata from a parsed slice.
///
/// The inspector is deliberately total: every failure mode is a recorded
/// state on the result rather than a thrown error, because a caller
/// deciding what to do with an existing signature must see "malformed" as
/// an observed fact instead of losing the remaining slots to an exception.
struct EmbeddedSigningMetadataInspector {

    init() {}

    /// Inspects one slice.
    ///
    /// - Parameters:
    ///   - slice: A parsed slice of `artifact`.
    ///   - artifact: The exact bytes the slice was parsed from. Read-only:
    ///     no range is written and no signature is rewritten.
    func inspect(slice: MachOSlice, artifact: Data) -> EmbeddedSigningMetadataInspection {
        guard artifact.startIndex == 0,
              let embedded = slice.embeddedSignature else {
            return EmbeddedSigningMetadataInspection(
                entitlements: .absent,
                requirements: .none,
                codeResourcesSeal: .noCodeDirectory
            )
        }

        let entries = embedded.superBlob.entries
        return EmbeddedSigningMetadataInspection(
            entitlements: entitlementsState(entries: entries, artifact: artifact),
            requirements: requirementsState(entries: entries, artifact: artifact),
            codeResourcesSeal: codeResourcesState(entries: entries)
        )
    }

    // MARK: - Per-slot classification

    private func entitlementsState(
        entries: [MachOSignatureEntry],
        artifact: Data
    ) -> EmbeddedEntitlementsState {
        guard let entry = entries.first(where: { $0.slot == .entitlements }) else {
            return .absent
        }
        guard entry.magic == EntitlementsBlob.magic,
              entry.fileRange.lowerBound >= artifact.startIndex,
              entry.fileRange.upperBound <= artifact.endIndex else {
            return .malformed
        }
        do {
            let blob = try EntitlementsBlob(existingBlob: artifact.subdata(in: entry.fileRange))
            let entitlements = try blob.parseEntitlements()
            return .present(entitlements)
        } catch {
            return .malformed
        }
    }

    private func requirementsState(
        entries: [MachOSignatureEntry],
        artifact: Data
    ) -> CodeSigningRequirements {
        guard let entry = entries.first(where: { $0.slot == .requirements }) else {
            return .none
        }
        guard entry.magic == RequirementsSet.magic,
              entry.fileRange.lowerBound >= artifact.startIndex,
              entry.fileRange.upperBound <= artifact.endIndex else {
            return CodeSigningRequirements(disposition: .malformed, set: nil)
        }
        do {
            return try RequirementsSet.parse(artifact.subdata(in: entry.fileRange))
        } catch {
            return CodeSigningRequirements(disposition: .malformed, set: nil)
        }
    }

    private func codeResourcesState(entries: [MachOSignatureEntry]) -> EmbeddedCodeResourcesSealState {
        guard let entry = entries.first(where: { $0.slot == .codeDirectory }),
              let directory = entry.codeDirectory else {
            return .noCodeDirectory
        }
        guard let slot = directory.specialSlots.first(where: { $0.kind == .codeResources }) else {
            return .notSealed
        }
        return .sealed(digest: slot.hash)
    }
}
