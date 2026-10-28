import Foundation

/// The read-only state of an entitlements blob found in an existing
/// signature.
enum EmbeddedEntitlementsState: Equatable {
    /// The slice carries no entitlements slot.
    case absent
    /// A slot's blob framed and decoded into a typed entitlement set. The slot
    /// that carried it is `EmbeddedSigningMetadataInspection.entitlementsSource`:
    /// the XML slot (5) when the signature has one, otherwise the DER slot (7)
    /// that iOS 15 and later carry.
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

/// Which slot an inspected entitlement set was read from.
///
/// The two slots encode the same dictionary when one tool produced both, but
/// they are independent blobs in the file, so the source is a fact worth
/// recording rather than assuming.
enum EmbeddedEntitlementsSource: Equatable {
    /// The XML property-list entitlement slot (5).
    case xml
    /// The DER entitlement slot (7), which iOS 15 and later carry.
    case der
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

    /// The slot `entitlements` was decoded from, or `nil` when there was
    /// nothing to decode. Recorded so a screen can say which slot it read
    /// instead of calling every claim "XML".
    var entitlementsSource: EmbeddedEntitlementsSource? = nil

    /// Whether the signature carries both entitlement slots and the two decode
    /// to different claim sets.
    ///
    /// A signature ZynSign produces encodes both slots from one dictionary, so a
    /// disagreement means the file was assembled by something else — or edited
    /// after signing. It is reported as a fact about the slots, never as an
    /// integrity verdict: the claims shown are the XML ones, and the finding
    /// says the DER slot differs.
    var entitlementSlotsDisagree: Bool = false
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
        let entitlements = entitlementsState(entries: entries, artifact: artifact)
        return EmbeddedSigningMetadataInspection(
            entitlements: entitlements.state,
            requirements: requirementsState(entries: entries, artifact: artifact),
            codeResourcesSeal: codeResourcesState(entries: entries),
            entitlementsSource: entitlements.source,
            entitlementSlotsDisagree: entitlements.disagrees
        )
    }

    // MARK: - Per-slot classification

    /// Reads whichever entitlement slot the signature carries.
    ///
    /// The XML slot wins when both are present: every device ZynSign targets
    /// understands it. When both exist the DER claims are decoded too, and a
    /// difference between the two slots is recorded on the result rather than
    /// resolved silently. A signature that carries only the DER slot — what an
    /// iOS 15+ signer may write, and what some upstream tools ship — is decoded
    /// instead of being reported as unknown.
    private func entitlementsState(
        entries: [MachOSignatureEntry],
        artifact: Data
    ) -> (state: EmbeddedEntitlementsState, source: EmbeddedEntitlementsSource?, disagrees: Bool) {
        let xmlEntry = entries.first { $0.slot == .entitlements }
        let derEntry = entries.first { $0.slot == .derEntitlements }

        if let entry = xmlEntry {
            guard entry.magic == EntitlementsBlob.magic,
                  entry.fileRange.lowerBound >= artifact.startIndex,
                  entry.fileRange.upperBound <= artifact.endIndex else {
                return (.malformed, .xml, false)
            }
            let claims: CodeSigningEntitlements
            do {
                let blob = try EntitlementsBlob(existingBlob: artifact.subdata(in: entry.fileRange))
                claims = try blob.parseEntitlements()
            } catch {
                return (.malformed, .xml, false)
            }
            // A second slot is compared, not shown: the XML claims are the ones
            // returned, because that is the slot every device reads.
            let derSlotClaims = derEntry.flatMap { derClaims(in: $0, artifact: artifact) }
            return (.present(claims), .xml, derSlotClaims.map { $0 != claims } ?? false)
        }

        if let entry = derEntry {
            guard entry.magic == DEREntitlementsBlob.magic,
                  entry.fileRange.lowerBound >= artifact.startIndex,
                  entry.fileRange.upperBound <= artifact.endIndex else {
                return (.malformed, .der, false)
            }
            do {
                let blob = try DEREntitlementsBlob(existingBlob: artifact.subdata(in: entry.fileRange))
                return (.present(try DEREntitlementsDecoder().decode(blob.payload)), .der, false)
            } catch {
                return (.malformed, .der, false)
            }
        }
        return (.absent, nil, false)
    }

    /// The DER slot's claims, when that slot is both framed and decodable. A slot
    /// that cannot be read is not evidence of disagreement, so it answers `nil`.
    private func derClaims(in entry: MachOSignatureEntry, artifact: Data) -> CodeSigningEntitlements? {
        guard entry.magic == DEREntitlementsBlob.magic,
              entry.fileRange.lowerBound >= artifact.startIndex,
              entry.fileRange.upperBound <= artifact.endIndex,
              let blob = try? DEREntitlementsBlob(existingBlob: artifact.subdata(in: entry.fileRange)),
              let claims = try? DEREntitlementsDecoder().decode(blob.payload) else {
            return nil
        }
        return claims
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
