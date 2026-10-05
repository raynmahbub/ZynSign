import Foundation

extension VerifyExportedArtifact {

    /// Decodes, parses, and holds the embedded provisioning profile against
    /// what the bundle declares and against the current instant.
    ///
    /// The profile is read from the artifact, not remembered from the signing
    /// run: the bytes embedded in the container are the only profile this
    /// check knows about.
    func verifyEmbeddedProfile(
        reader: any ArchiveReader,
        bundlePath: ArchivePath,
        declaredBundleIdentifier: String,
        collector: inout ArtifactVerificationCollector
    ) throws {
        guard let context = readEmbeddedProfile(reader: reader, bundlePath: bundlePath, collector: &collector) else {
            return
        }
        recordProfileAuthenticity(context.payload.authenticity, collector: &collector)
        recordEmbeddedProfileSummary(context.profile, collector: &collector)
        recordProfileIdentifier(
            context.profile.applicationIdentifier?.bundleIdentifierComponent,
            declaredBundleIdentifier: declaredBundleIdentifier,
            collector: &collector
        )
        recordProfileValidity(context.profile, collector: &collector)
    }

    private struct EmbeddedProfileContext {
        let payload: ProvisioningProfilePayload
        let profile: ProvisioningProfile
    }

    private func readEmbeddedProfile(
        reader: any ArchiveReader,
        bundlePath: ArchivePath,
        collector: inout ArtifactVerificationCollector
    ) -> EmbeddedProfileContext? {
        guard let profilePath = ArchivePath(rawValue: bundlePath.rawValue + "/embedded.mobileprovision") else {
            collector.record(.embeddedProfile, .warning, "The bundle's profile location cannot be named.")
            return nil
        }
        guard let profileBytes = try? reader.readEntryData(at: profilePath, maximumBytes: limits.maximumProfileBytes) else {
            collector.record(.embeddedProfile, .error, "The bundle embeds no readable provisioning profile.")
            return nil
        }
        guard let profileDecoder else {
            collector.record(
                .embeddedProfile,
                .unsupported,
                "The embedded provisioning profile was found, but no profile decoder is composed in this build."
            )
            return nil
        }
        guard let payload = decodedProfilePayload(profileBytes, using: profileDecoder, collector: &collector) else {
            return nil
        }
        guard let profile = parsedProfile(payload, collector: &collector) else { return nil }
        return EmbeddedProfileContext(payload: payload, profile: profile)
    }

    private func decodedProfilePayload(
        _ bytes: Data,
        using decoder: any ProvisioningProfilePayloadDecoder,
        collector: inout ArtifactVerificationCollector
    ) -> ProvisioningProfilePayload? {
        do {
            return try decoder.decodePayload(from: ProvisioningProfileInput(bytes: bytes))
        } catch {
            collector.record(
                .embeddedProfile,
                .error,
                "The embedded provisioning profile's container could not be decoded."
            )
            return nil
        }
    }

    private func parsedProfile(
        _ payload: ProvisioningProfilePayload,
        collector: inout ArtifactVerificationCollector
    ) -> ProvisioningProfile? {
        do {
            return try profileParser.parse(payload)
        } catch {
            collector.record(
                .embeddedProfile,
                .error,
                "The embedded provisioning profile's payload could not be parsed."
            )
            return nil
        }
    }

    private func recordProfileAuthenticity(
        _ authenticity: ProvisioningProfileAuthenticityStatus,
        collector: inout ArtifactVerificationCollector
    ) {
        switch authenticity {
        case .authenticated:
            collector.record(.embeddedProfileAuthenticity, .note, "The embedded profile's container signature was evaluated and matched.")
        case .notEvaluated:
            collector.record(
                .embeddedProfileAuthenticity,
                .warning,
                "The embedded profile decoded, but its container signature was not evaluated."
            )
        case .rejected:
            collector.record(
                .embeddedProfileAuthenticity,
                .error,
                "The embedded profile's container signature was rejected."
            )
        }
    }

    private func recordEmbeddedProfileSummary(
        _ profile: ProvisioningProfile,
        collector: inout ArtifactVerificationCollector
    ) {
        let profileName = profile.profileName.map { "named \($0) " } ?? ""
        let deviceCount = profile.provisionedDevices?.count ?? 0
        collector.record(
            .embeddedProfile,
            .note,
            "The embedded profile \(profileName)declares \(deviceCount) provisioned device\(deviceCount == 1 ? "" : "s")."
        )
    }

    private func recordProfileIdentifier(
        _ component: ProvisioningApplicationIdentifierComponent?,
        declaredBundleIdentifier: String,
        collector: inout ArtifactVerificationCollector
    ) {
        switch component {
        case .exact(let identifier):
            recordExactProfileIdentifier(identifier.rawValue, declaredBundleIdentifier: declaredBundleIdentifier, collector: &collector)
        case .wildcard(let prefix):
            recordWildcardProfileIdentifier(prefix, declaredBundleIdentifier: declaredBundleIdentifier, collector: &collector)
        case .none:
            collector.record(
                .embeddedProfileIdentifier,
                .warning,
                "The embedded profile's application identifier could not be compared with the bundle's identifier."
            )
        }
    }

    private func recordExactProfileIdentifier(
        _ identifier: String,
        declaredBundleIdentifier: String,
        collector: inout ArtifactVerificationCollector
    ) {
        guard identifier == declaredBundleIdentifier else {
            collector.record(
                .embeddedProfileIdentifier,
                .error,
                "The embedded profile authorizes \(identifier), which is not the bundle's identifier \(declaredBundleIdentifier)."
            )
            return
        }
        collector.record(.embeddedProfileIdentifier, .note, "The embedded profile authorizes this bundle identifier.")
    }

    private func recordWildcardProfileIdentifier(
        _ prefix: String,
        declaredBundleIdentifier: String,
        collector: inout ArtifactVerificationCollector
    ) {
        guard declaredBundleIdentifier == prefix || declaredBundleIdentifier.hasPrefix(prefix + ".") else {
            collector.record(
                .embeddedProfileIdentifier,
                .error,
                "The embedded profile authorizes the wildcard \(prefix).*, which does not cover the bundle identifier \(declaredBundleIdentifier)."
            )
            return
        }
        collector.record(
            .embeddedProfileIdentifier,
            .note,
            "The embedded profile authorizes the wildcard \(prefix).* which covers this bundle identifier."
        )
    }

    private func recordProfileValidity(
        _ profile: ProvisioningProfile,
        collector: inout ArtifactVerificationCollector
    ) {
        guard let creationDate = profile.creationDate, let expirationDate = profile.expirationDate else {
            collector.record(
                .embeddedProfileExpiry,
                .warning,
                "The embedded profile declares no complete validity period, so it was not evaluated against the current time."
            )
            return
        }
        let validity = ProvisioningProfileValidity.evaluate(
            creationDate: creationDate,
            expirationDate: expirationDate,
            at: now()
        )
        recordProfilePeriodStatus(validity.periodStatus, expirationDate: expirationDate, collector: &collector)
    }

    private func recordProfilePeriodStatus(
        _ status: ProvisioningProfileValidityPeriodStatus,
        expirationDate: Date,
        collector: inout ArtifactVerificationCollector
    ) {
        switch status {
        case .currentlyValid:
            collector.record(.embeddedProfileExpiry, .note, "The embedded profile is within its validity period.")
        case .expired:
            collector.record(.embeddedProfileExpiry, .warning, "The embedded profile expired on \(Self.dayString(expirationDate)).")
        case .notYetValid:
            collector.record(.embeddedProfileExpiry, .warning, "The embedded profile is not yet valid.")
        case .malformed:
            collector.record(.embeddedProfileExpiry, .warning, "The embedded profile's validity period is not ordered.")
        }
    }
}
