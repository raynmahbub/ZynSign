import Foundation

/// Supplies nested-code discovery with the content-derived facts it asks for,
/// reading them through the archive boundary the rest of the application
/// already uses.
///
/// The source is deliberately thin. It reads exactly the entry discovery names
/// — a container's information file or a candidate binary — within a bound,
/// and it classifies what it reads with the existing read-only facilities:
/// `ApplicationMetadataReader` for a declared identity and
/// `MachOCodeSignatureInspector`, over the existing `MachOParsing`
/// implementation, for the binary's structure and its existing signature
/// state. Nothing here reads an entry discovery did not name, enumerates the
/// container, extracts anything to a filesystem, resolves a link, loads or
/// executes a binary, or writes a byte.
///
/// Failures never escape as thrown errors. Every question has a descriptive
/// answer, because "the entry could not be read" is a fact about the bundle
/// that the plan must record rather than an exception that aborts discovery.
/// The one thing this type never does is guess: an entry that cannot be read
/// is reported unreadable, and a candidate that is not Mach-O is reported as
/// not Mach-O, never as code with unknown content.
struct ArchiveNestedCodeInspectionSource: NestedCodeInspectionSource {

    private let reader: any ArchiveReader
    private let parser: any MachOParsing
    private let signatureInspector: MachOCodeSignatureInspector
    private let limits: ArchiveLimits

    /// Creates the source over one open reader.
    ///
    /// The parser is shared with the signature inspector so that one candidate
    /// is parsed by one mechanism, and the archive limits are the same policy
    /// the reader itself enforces, so a caller can never widen a read.
    init(
        reader: any ArchiveReader,
        parser: any MachOParsing = ReadOnlyMachOParser(),
        limits: ArchiveLimits = .default
    ) {
        self.reader = reader
        self.parser = parser
        self.limits = limits
        self.signatureInspector = MachOCodeSignatureInspector(parser: parser)
    }

    func bundleInformation(
        ofContainerAt path: ArchivePath,
        maximumBytes: Int
    ) -> NestedCodeBundleInformation {
        let bytes: Data
        do {
            bytes = try reader.readEntryData(at: path, maximumBytes: boundedReadSize(maximumBytes))
        } catch {
            return .unreadable
        }
        guard let metadata = ApplicationMetadataReader.read(from: bytes).metadata else {
            return .malformed
        }
        // The package type is not part of the metadata model this build
        // reads, so it is reported as undeclared rather than invented.
        return .read(NestedCodeBundleIdentity(metadata: metadata))
    }

    func binary(
        at path: ArchivePath,
        declaredByteCount: Int?,
        maximumBytes: Int
    ) -> NestedCodeBinaryInspection {
        if let declaredByteCount, declaredByteCount > maximumBytes {
            return NestedCodeBinaryInspection(
                observation: .beyondInspectionBound(declaredByteCount: declaredByteCount)
            )
        }
        let bytes: Data
        do {
            bytes = try reader.readEntryData(at: path, maximumBytes: boundedReadSize(maximumBytes))
        } catch {
            return NestedCodeBinaryInspection(observation: .unreadable)
        }
        return Self.classify(signatureInspector.inspect(bytes: bytes))
    }

    /// The tighter of the caller's bound and the reader's own inspection-read
    /// policy, so that a read can never succeed by producing more bytes than
    /// the container boundary is willing to expand.
    private func boundedReadSize(_ maximumBytes: Int) -> Int {
        max(1, min(maximumBytes, limits.maximumInspectionReadBytes))
    }

    /// Interprets one read-only inspection as an observation plus a signature
    /// state.
    ///
    /// A signature failure confined to the signature region is not a failure
    /// to establish code: the image parsed as Mach-O, and the plan says so by
    /// keeping the observation and recording the signature state separately. A
    /// container failure that leaves no established structure is classified by
    /// the parser's own reason, so an unrecognized magic is "not Mach-O", a
    /// form this build does not model is "unsupported", and anything else is
    /// "malformed" — three different statements that must not be collapsed.
    private static func classify(_ inspection: MachOCodeSignatureInspection) -> NestedCodeBinaryInspection {
        switch inspection {
        case .thin(let slice):
            return NestedCodeBinaryInspection(
                observation: .machO(summary: NestedCodeMachOSummary(
                    slices: [slice.slice],
                    isUniversal: false
                )),
                existingSignature: NestedCodeExistingSignature(states: [slice.existingSignature])
            )
        case .universal(let slices):
            return NestedCodeBinaryInspection(
                observation: .machO(summary: NestedCodeMachOSummary(
                    slices: slices.map(\.slice),
                    isUniversal: true
                )),
                existingSignature: NestedCodeExistingSignature(states: slices.map(\.existingSignature))
            )
        case let .malformedSignature(_, state):
            return NestedCodeBinaryInspection(
                observation: .machO(summary: nil),
                existingSignature: NestedCodeExistingSignature.failure(state)
            )
        case .malformedMachO(let error):
            return NestedCodeBinaryInspection(
                observation: NestedCodeBinaryObservation.classifying(error)
            )
        }
    }
}
