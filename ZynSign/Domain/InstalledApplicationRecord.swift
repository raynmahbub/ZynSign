import Foundation

/// The stable identity of one installed-application record.
///
/// Opaque and minted by ZynSign, like every other identifier, so nothing
/// inside a package can influence where its record is kept.
struct InstalledApplicationIdentifier: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {

    /// The underlying uniqueness value.
    let rawValue: String

    /// Mints a fresh identifier.
    init() { self.rawValue = UUID().uuidString }

    /// Reuses a persisted identifier.
    init(rawValue: String) { self.rawValue = rawValue }

    var description: String { rawValue }
}

/// The stable identity of one event in an installed application's history.
struct InstallationEventIdentifier: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {

    let rawValue: String

    init() { self.rawValue = UUID().uuidString }

    init(rawValue: String) { self.rawValue = rawValue }

    var description: String { rawValue }
}

/// The channel a delivery travelled through, as the user reported it.
///
/// ZynSign never observes a delivery — the capability assessment stays
/// `noDeliveryMechanism` — so a channel is what the user said they used,
/// recorded so the history makes sense later. It is a fact about the
/// operator's workflow, not about the outcome.
enum InstallationChannel: String, Codable, CaseIterable, Hashable, Sendable {

    /// Over-the-air, through the `itms-services` link the delivery hand-off
    /// produced.
    case otaLink

    /// Managed distribution, through the operator's MDM relationship.
    case managedDistribution

    /// A host tool — Finder, Apple Configurator, or similar — that the
    /// operator drove themselves.
    case hostTool

    /// The user recorded the installation after the fact, without ZynSign
    /// having seen the delivery step.
    case reportedAfterTheFact

    /// The name the channel shows.
    var displayName: String {
        switch self {
        case .otaLink: return "Over-the-Air Link"
        case .managedDistribution: return "Managed Distribution"
        case .hostTool: return "Host Tool"
        case .reportedAfterTheFact: return "Recorded by You"
        }
    }

    /// What ZynSign knows about a delivery through this channel — always
    /// the same amount: nothing. The sentence says so, in fixed language.
    var explanation: String {
        switch self {
        case .otaLink:
            return "You opened the over-the-air link ZynSign produced. ZynSign cannot see what the installer did."
        case .managedDistribution:
            return "Your MDM relationship delivered the package. ZynSign has no connection to it."
        case .hostTool:
            return "A host tool installed the package. ZynSign has no connection to it."
        case .reportedAfterTheFact:
            return "You recorded this installation yourself. ZynSign did not observe it."
        }
    }
}

/// What happened in one installation event.
enum InstallationEventKind: String, Codable, CaseIterable, Hashable, Sendable {

    /// The application was put on a device for the first time through
    /// ZynSign's records.
    case installed

    /// A version the record already tracks was replaced by a newer one.
    case updated

    /// The same version was delivered again — for example after a device
    /// reset or a profile wipe.
    case reinstalled

    /// The name the history row shows.
    var displayName: String {
        switch self {
        case .installed: return "Installed"
        case .updated: return "Updated"
        case .reinstalled: return "Reinstalled"
        }
    }
}

/// One thing that happened to an installed application, as the user
/// confirmed it.
///
/// The event carries what ZynSign knew at the time: which artifact was
/// used, what verification last said about it, and which signing run
/// produced it. Nothing here claims the platform accepted anything — the
/// event records the user's own confirmation that the delivery happened.
struct InstalledApplicationEvent: Equatable, Hashable, Codable, Sendable {

    /// The event's stable identity.
    let id: InstallationEventIdentifier

    /// What happened.
    let kind: InstallationEventKind

    /// When the user confirmed it.
    let at: Date

    /// The declared marketing version of the artifact delivered.
    let shortVersion: String?

    /// The declared build of the artifact delivered.
    let buildVersion: String?

    /// The export record that held the artifact, when one did.
    let exportIdentifier: String?

    /// The file name the artifact carried in export storage, when known.
    /// A name, never a path.
    let exportFileName: String?

    /// The signing run that produced the artifact, when the journal held
    /// one.
    let signingRecordIdentifier: String?

    /// What verification last concluded about the artifact, when known at
    /// confirmation time.
    let verificationStatus: ArtifactVerificationStatus?

    /// The channel the delivery used.
    let channel: InstallationChannel

    init(
        id: InstallationEventIdentifier = InstallationEventIdentifier(),
        kind: InstallationEventKind,
        at: Date,
        shortVersion: String?,
        buildVersion: String?,
        exportIdentifier: String?,
        exportFileName: String?,
        signingRecordIdentifier: String?,
        verificationStatus: ArtifactVerificationStatus?,
        channel: InstallationChannel
    ) {
        self.id = id
        self.kind = kind
        self.at = at
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.exportIdentifier = exportIdentifier
        self.exportFileName = exportFileName
        self.signingRecordIdentifier = signingRecordIdentifier
        self.verificationStatus = verificationStatus
        self.channel = channel
    }

    /// The declared version and build, in the form people read them.
    var versionDisplay: String {
        switch (shortVersion, buildVersion) {
        case (.some(let version), .some(let build)): return "\(version) (\(build))"
        case (.some(let version), .none): return version
        case (.none, .some(let build)): return "Build \(build)"
        case (.none, .none): return "Version not declared"
        }
    }
}

/// One application in the Installed Apps Library: the local record of an
/// application the user installed through ZynSign's delivery workflow and
/// confirmed afterwards.
///
/// **What this record is, and is not.** ZynSign cannot install anything and
/// cannot see a device's application list — the capability assessment stays
/// `noDeliveryMechanism`. A record exists because the user said "this
/// happened": they confirmed an attempt after using the delivery hand-off,
/// or recorded an installation after the fact. The record is a ledger the
/// user maintains, kept honest by being explicit about that. It is never
/// presented as ZynSign's observation.
///
/// Records are keyed by declared bundle identifier: delivering a new
/// version of an application the record already tracks *updates* that
/// record by appending an event, so one application has one record, one
/// history, and one update state.
///
/// Events are bounded per record. When a record's events outgrow the cap
/// the oldest are trimmed by the store, so the history stays lightweight
/// for hundreds of installed applications without unbounded growth.
struct InstalledApplicationRecord: Equatable, Hashable, Identifiable, Codable, Sendable {

    /// The record's stable identity.
    let id: InstalledApplicationIdentifier

    /// The application's declared bundle identifier — the key the record is
    /// looked up by.
    let bundleIdentifier: String

    /// The display name captured from the most recent confirmation, falling
    /// back to the identifier. Updated as events are appended.
    let displayName: String

    /// The events, oldest first.
    let events: [InstalledApplicationEvent]

    /// The library record the most recent delivery was signed from, when
    /// known. Kept so details can link back while the entry exists.
    let libraryRecordIdentifier: String?

    /// When the record was created.
    let recordedAt: Date

    /// When the record last changed.
    let updatedAt: Date

    /// The most events one record keeps. The store trims beyond this.
    static let maximumEventsPerRecord = 20

    init(
        id: InstalledApplicationIdentifier = InstalledApplicationIdentifier(),
        bundleIdentifier: String,
        displayName: String,
        events: [InstalledApplicationEvent] = [],
        libraryRecordIdentifier: String? = nil,
        recordedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.events = events
        self.libraryRecordIdentifier = libraryRecordIdentifier
        self.recordedAt = recordedAt
        self.updatedAt = updatedAt
    }

    // MARK: - Derived facts

    /// The most recent event, when the record has one.
    var latestEvent: InstalledApplicationEvent? { events.last }

    /// When the application was last installed, updated, or reinstalled.
    var lastInstalledAt: Date? { latestEvent?.at }

    /// The declared version currently recorded as installed.
    var installedVersionDisplay: String {
        latestEvent?.versionDisplay ?? "Not recorded"
    }

    /// What verification said about the artifact behind the latest event.
    var installedVerificationStatus: ArtifactVerificationStatus? {
        latestEvent?.verificationStatus
    }

    /// The channel the latest delivery used.
    var installedChannel: InstallationChannel? { latestEvent?.channel }

    /// The app name a card shows.
    var displayOrIdentifier: String {
        displayName.isEmpty ? bundleIdentifier : displayName
    }

    /// A copy of the record with one more event appended, refreshed from
    /// the delivery's facts.
    ///
    /// Appending is the only way a record changes, so the history and the
    /// "last installed" facts can never disagree with the events.
    func appending(
        _ event: InstalledApplicationEvent,
        libraryRecordIdentifier: String?,
        now: Date
    ) -> InstalledApplicationRecord {
        var trimmed = events
        trimmed.append(event)
        if trimmed.count > Self.maximumEventsPerRecord {
            trimmed.removeFirst(trimmed.count - Self.maximumEventsPerRecord)
        }
        return InstalledApplicationRecord(
            id: id,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            events: trimmed,
            libraryRecordIdentifier: libraryRecordIdentifier ?? self.libraryRecordIdentifier,
            recordedAt: recordedAt,
            updatedAt: now
        )
    }

    /// A copy of the record with a refreshed display name, keeping the
    /// events. Used when the library learns a better name for the
    /// application.
    func renaming(to newName: String, now: Date) -> InstalledApplicationRecord {
        InstalledApplicationRecord(
            id: id,
            bundleIdentifier: bundleIdentifier,
            displayName: newName,
            events: events,
            libraryRecordIdentifier: libraryRecordIdentifier,
            recordedAt: recordedAt,
            updatedAt: now
        )
    }
}

/// What a newer signed output means for one installed record.
///
/// The comparison reads only what ZynSign holds — the record's latest
/// event and the newest export in the catalog for the same bundle
/// identifier — and compares the declared versions the way people read
/// them (`DeclaredVersionOrder`). It knows nothing about the device, which
/// may hold any version at all; `unknown` is the honest answer whenever
/// the declarations cannot be ordered.
enum InstallationUpdateState: Equatable, Hashable, Sendable {

    /// The newest export ZynSign holds is the one recorded as installed.
    case upToDate

    /// ZynSign holds a newer signed output than the one recorded as
    /// installed. The payload carries what the workspace knows about it.
    case updateAvailable(InstallationUpdateCandidate)

    /// The versions cannot be ordered, or there is nothing to compare
    /// against. No claim is made in either direction.
    case unknown

    /// Whether the state offers an update to deliver.
    var offersUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    /// Evaluates the update state for one installed record against the
    /// newest export for the same bundle identifier, when the catalog holds
    /// one and its bytes are available.
    static func evaluate(
        installed: InstalledApplicationRecord,
        newestExport: ExportRecord?
    ) -> InstallationUpdateState {
        guard let newestExport else { return .unknown }
        guard let installedEvent = installed.latestEvent else { return .unknown }
        // The export that was recorded as installed is still the newest
        // ZynSign holds: nothing newer exists, whatever the declarations say.
        if installedEvent.exportIdentifier == newestExport.id.rawValue {
            return .upToDate
        }
        let comparison = DeclaredVersionOrder.compare(
            version: newestExport.shortVersion,
            build: newestExport.buildVersion,
            with: installedEvent.shortVersion,
            build: installedEvent.buildVersion
        )
        switch comparison {
        case .orderedDescending:
            return .updateAvailable(
                InstallationUpdateCandidate(
                    exportIdentifier: newestExport.id.rawValue,
                    exportFileName: newestExport.fileName,
                    shortVersion: newestExport.shortVersion,
                    buildVersion: newestExport.buildVersion,
                    verificationStatus: newestExport.verificationStatus
                )
            )
        case .orderedSame, .orderedAscending, .none:
            // Equal versions under a different export are a re-sign of the
            // same release, not an update; older or incomparable versions
            // make no claim either.
            return .unknown
        }
    }
}

/// What ZynSign knows about a newer signed output than the one recorded as
/// installed.
struct InstallationUpdateCandidate: Equatable, Hashable, Sendable {

    /// The export record that holds the newer artifact.
    let exportIdentifier: String

    /// The file name the newer artifact carries.
    let exportFileName: String

    /// The declared marketing version.
    let shortVersion: String?

    /// The declared build.
    let buildVersion: String?

    /// What verification last said about the newer artifact.
    let verificationStatus: ArtifactVerificationStatus?

    /// The declared version and build, in the form people read them.
    var versionDisplay: String {
        switch (shortVersion, buildVersion) {
        case (.some(let version), .some(let build)): return "\(version) (\(build))"
        case (.some(let version), .none): return version
        case (.none, .some(let build)): return "Build \(build)"
        case (.none, .none): return "Version not declared"
        }
    }
}

/// A delivery the user started and has not confirmed the outcome of yet.
///
/// Attempts exist so an interrupted or unconfirmed delivery is never
/// mistaken for an installation. An attempt is created when the user
/// commits to delivering an artifact through a channel; it stays pending —
/// across relaunches, unchanged — until the user confirms the delivery
/// happened, says it did not, or discards it. Nothing in ZynSign confirms
/// an attempt on its own authority, and no timer resolves one.
struct PendingInstallationAttempt: Equatable, Hashable, Identifiable, Codable, Sendable {

    /// The attempt's stable identity.
    let id: InstallationEventIdentifier

    /// What the user said they were doing: installing for the first time,
    /// updating, or reinstalling.
    let intent: InstallationEventKind

    /// The application's declared bundle identifier.
    let bundleIdentifier: String

    /// The application's declared display name, when known.
    let displayName: String?

    /// The library record the artifact was signed from, when known.
    let libraryRecordIdentifier: String?

    /// The export record that holds the artifact, when one does.
    let exportIdentifier: String?

    /// The file name the artifact carries.
    let exportFileName: String?

    /// The declared marketing version of the artifact.
    let shortVersion: String?

    /// The declared build of the artifact.
    let buildVersion: String?

    /// The signing run that produced the artifact, when the journal held
    /// one.
    let signingRecordIdentifier: String?

    /// What verification last said about the artifact when the attempt
    /// started.
    let verificationStatus: ArtifactVerificationStatus?

    /// The channel the delivery will use.
    let channel: InstallationChannel

    /// When the attempt started.
    let startedAt: Date

    init(
        id: InstallationEventIdentifier = InstallationEventIdentifier(),
        intent: InstallationEventKind,
        bundleIdentifier: String,
        displayName: String?,
        libraryRecordIdentifier: String?,
        exportIdentifier: String?,
        exportFileName: String?,
        shortVersion: String?,
        buildVersion: String?,
        signingRecordIdentifier: String?,
        verificationStatus: ArtifactVerificationStatus?,
        channel: InstallationChannel,
        startedAt: Date
    ) {
        self.id = id
        self.intent = intent
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.libraryRecordIdentifier = libraryRecordIdentifier
        self.exportIdentifier = exportIdentifier
        self.exportFileName = exportFileName
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.signingRecordIdentifier = signingRecordIdentifier
        self.verificationStatus = verificationStatus
        self.channel = channel
        self.startedAt = startedAt
    }

    /// The name a banner shows for the attempt.
    var displayOrIdentifier: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return bundleIdentifier
    }

    /// The declared version and build, in the form people read them.
    var versionDisplay: String {
        switch (shortVersion, buildVersion) {
        case (.some(let version), .some(let build)): return "\(version) (\(build))"
        case (.some(let version), .none): return version
        case (.none, .some(let build)): return "Build \(build)"
        case (.none, .none): return "Version not declared"
        }
    }

    /// The sentence the pending banner leads with.
    var summary: String {
        "\(intent.displayName) \(displayOrIdentifier) \(versionDisplay) — awaiting your confirmation."
    }
}

/// One row of the workspace's flattened history: an event, joined with the
/// name the record carries today. Derived from the records, never stored
/// separately, so history and records can never disagree.
struct InstallationHistoryEntry: Equatable, Hashable, Identifiable, Sendable {

    /// The event the row shows.
    let event: InstalledApplicationEvent

    /// The record the event belongs to.
    let recordID: InstalledApplicationIdentifier

    /// The application's bundle identifier.
    let bundleIdentifier: String

    /// The name the record carries today.
    let appName: String

    var id: InstallationEventIdentifier { event.id }

    /// The row's primary line: what happened, and to what.
    var title: String { "\(appName) — \(event.kind.displayName)" }

    /// The row's secondary line: the version delivered, and how.
    var detail: String {
        var parts = [event.versionDisplay]
        parts.append("via \(event.channel.displayName)")
        return parts.joined(separator: " · ")
    }
}
