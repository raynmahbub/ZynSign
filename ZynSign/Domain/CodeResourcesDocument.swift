import Foundation

/// Structured failures at the CodeResources boundary.
///
/// Cases name the structure that refused. Paths in parse-side errors are
/// kept as plain strings, because a path read from an untrusted property
/// list is exactly the thing that failed validation and must not be
/// laundered into a `BundlePath` first.
enum CodeResourcesError: Error, Equatable {
    /// The presented bytes were empty.
    case emptyInput
    /// The input exceeded the configured byte bound.
    case inputTooLarge
    /// The bytes were not a decodable property list with a dictionary root.
    case malformedPlist
    /// The property list used a format ZynSign does not accept (OpenStep).
    case unsupportedPlistFormat
    /// A top-level key outside the supported subset (`files2`, `rules2`).
    /// The v1 `files`/`rules` dictionaries and platform-specific dictionaries
    /// are an explicit unsupported subset, not a silent drop.
    case unsupportedTopLevelKey(String)
    /// The `files2` dictionary was missing entirely.
    case missingFiles2
    /// One entry's value was not a supported entry structure.
    case invalidEntryStructure(path: String)
    /// A file path in the document is not a valid bundle-relative path.
    case invalidPath(String)
    /// A digest carried the wrong length for its documented form.
    case invalidHashLength(path: String, expected: Int, actual: Int)
    /// A rule's value was not a supported rule structure.
    case invalidRuleStructure(pattern: String)
    /// A model value failed its own invariants.
    case invalidDocument
    /// The tree exceeded the configured bounds.
    case resourceLimitExceeded
    /// A canonicalization failure while serializing.
    case serializationFailure
}

/// One sealed file resource: the `hash2` entry of the files2 dictionary.
///
/// `hash2` is the SHA-256 digest of the file's exact stored bytes — 32 bytes.
/// The legacy `hash` (SHA-1) form is deliberately not generated: ZynSign's
/// signing configuration is SHA-256-only, and emitting a SHA-1 form would
/// imply a dual-digest compatibility claim that has not been established.
struct FileResourceSeal: Equatable, Hashable {

    static let hash2ByteCount = DigestAlgorithm.sha256.digestLength

    let path: BundlePath
    let hash2: Data

    init(path: BundlePath, hash2: Data) throws {
        guard hash2.count == Self.hash2ByteCount else {
            throw CodeResourcesError.invalidHashLength(
                path: path.rawValue,
                expected: Self.hash2ByteCount,
                actual: hash2.count
            )
        }
        self.path = path
        self.hash2 = hash2
    }
}

/// One nested-code entry of the files2 dictionary.
///
/// Format evidence:
///
/// - **Observed (Apple-published sample; Apple developer documentation).**
///   Nested code appears in `files2` as a `cdhash` value (20 bytes) rather
///   than a content digest, because nested code is independently signed and
///   its own signature seals its contents. Apple's samples also carry a
///   requirement-language string beside the cdhash; generating that text is
///   outside ZynSign's implemented subset, so this model carries the cdhash
///   only and omits the requirement text — an omission recorded in the
///   architecture document, not hidden.
/// - **Inferred (independent reimplementations, consistent).** The cdhash is
///   the first 20 bytes of the SHA-256 digest of the nested binary's
///   SHA-256 CodeDirectory blob. ZynSign derives it exactly that way from a
///   signing result's code-directory digest; byte-for-byte agreement with
///   Apple's own seal **Requires experiment**.
struct NestedCodeResourceSeal: Equatable, Hashable {

    static let codeDirectoryHashByteCount = 20

    let path: BundlePath
    let codeDirectoryHash: Data

    /// Creates a seal from a full code-directory digest, truncating the
    /// documented 32-byte SHA-256 form to its first 20 bytes.
    init(path: BundlePath, codeDirectoryDigest: Digest) throws {
        guard codeDirectoryDigest.algorithm == .sha256,
              codeDirectoryDigest.bytes.count == DigestAlgorithm.sha256.digestLength else {
            throw CodeResourcesError.invalidHashLength(
                path: path.rawValue,
                expected: DigestAlgorithm.sha256.digestLength,
                actual: codeDirectoryDigest.bytes.count
            )
        }
        try self.init(path: path, codeDirectoryHash: Data(codeDirectoryDigest.bytes.prefix(Self.codeDirectoryHashByteCount)))
    }

    /// Creates a seal from an already-truncated 20-byte code-directory hash.
    init(path: BundlePath, codeDirectoryHash: Data) throws {
        guard codeDirectoryHash.count == Self.codeDirectoryHashByteCount else {
            throw CodeResourcesError.invalidHashLength(
                path: path.rawValue,
                expected: Self.codeDirectoryHashByteCount,
                actual: codeDirectoryHash.count
            )
        }
        self.path = path
        self.codeDirectoryHash = codeDirectoryHash
    }
}

/// One entry of the files2 dictionary.
enum CodeResourcesFileEntry: Equatable, Hashable {
    case file(FileResourceSeal)
    case nestedCode(NestedCodeResourceSeal)

    var path: BundlePath {
        switch self {
        case .file(let seal): return seal.path
        case .nestedCode(let seal): return seal.path
        }
    }
}

/// Why a discovered path is not sealed.
enum OmittedResourceReason: Equatable, Hashable {
    /// The caller's configuration excluded this path.
    case excludedByConfiguration
    /// The symlink policy recorded this symbolic link instead of hashing it.
    case symbolicLinkExcluded
}

/// A recorded omission. Omissions are part of the seal's provenance and are
/// kept on the document; they are deliberately **not** serialized into the
/// CodeResources property list, whose format defines no such field.
struct OmittedResource: Equatable, Hashable {
    let path: BundlePath
    let reason: OmittedResourceReason
}

/// One resource rule from the rules2 dictionary.
///
/// Rules are represented, preserved, and round-tripped, but **never
/// generated**: which exclusion and optionality rules the platform expects is
/// outside ZynSign's established knowledge (**Requires experiment** against
/// authoritative samples). A caller that holds authoritative rules may supply
/// them; the generator itself emits a document without a rules2 dictionary.
struct CodeResourcesRule: Equatable, Hashable {
    let pattern: String
    let optional: Bool?
    let weight: Int?

    init(pattern: String, optional: Bool? = nil, weight: Int? = nil) throws {
        guard !pattern.isEmpty, pattern.utf8.count <= 1_024,
              !pattern.contains(where: { $0.isControl }) else {
            throw CodeResourcesError.invalidRuleStructure(pattern: pattern)
        }
        self.pattern = pattern
        self.optional = optional
        self.weight = weight
    }
}

/// The typed resource-seal document.
///
/// The model represents the subset ZynSign's signing workflow actually uses:
///
/// - `files2` — file resources with SHA-256 `hash2` digests, and nested code
///   with `cdhash` values;
/// - `rules2` — optional, caller-supplied, never generated;
/// - `omitted` — the provenance record of exclusions, not serialized.
///
/// The historical `files` (SHA-1) dictionary, the v1 `rules` dictionary, and
/// the platform-specific sub-dictionaries observed in some Apple output are
/// an explicit unsupported subset: parsing one fails with
/// `unsupportedTopLevelKey` rather than silently dropping content.
struct CodeResourcesDocument: Equatable {

    /// Every files2 entry, in ascending path order, paths unique.
    let files2: [CodeResourcesFileEntry]

    /// The rules2 dictionary, when the caller supplied authoritative rules.
    let rules2: [CodeResourcesRule]?

    /// Recorded omissions. Not serialized.
    let omitted: [OmittedResource]

    init(
        files2: [CodeResourcesFileEntry],
        rules2: [CodeResourcesRule]? = nil,
        omitted: [OmittedResource] = []
    ) throws {
        let sorted = files2.sorted { left, right in
            CanonicalPropertyListXMLSerializer.utf8Ascending(left.path.rawValue, right.path.rawValue)
        }
        var previous: BundlePath?
        for entry in sorted {
            guard entry.path != .root else {
                throw CodeResourcesError.invalidPath(entry.path.rawValue)
            }
            if let previous, previous == entry.path {
                throw CodeResourcesError.invalidDocument
            }
            previous = entry.path
        }
        var rules: [CodeResourcesRule]?
        if let supplied = rules2 {
            rules = supplied.sorted {
                CanonicalPropertyListXMLSerializer.utf8Ascending($0.pattern, $1.pattern)
            }
        }
        self.files2 = sorted
        self.rules2 = rules
        self.omitted = omitted
    }

    /// Whether the document seals nothing (no files, no nested code).
    var isEmpty: Bool { files2.isEmpty }

    /// The exact serialized CodeResources bytes.
    ///
    /// These are the bytes whose SHA-256 digest occupies CodeDirectory
    /// special slot 3. Serialization is deterministic and independent of the
    /// order in which the document was assembled.
    func serialized() throws -> Data {
        CodeResourcesSerializer().serialize(self)
    }
}

/// Deterministic serialization of the resource-seal document.
///
/// Output goes through the one canonical property-list serializer, so the
/// document's bytes are a function of its content alone: files2 keys in
/// ascending UTF-8 byte order, hash and cdhash values as base64 data, exact
/// fixed header lines. The property-list layout follows the form Apple's
/// tooling writes — a root dictionary whose `files2` key holds the entries —
/// but byte-for-byte agreement with Apple's own serializer is **not claimed**
/// and is recorded as requiring experiment.
struct CodeResourcesSerializer {

    static let maximumDocumentByteCount = CanonicalPropertyListLimits.default.maximumDocumentByteCount

    let limits: CanonicalPropertyListLimits

    init(limits: CanonicalPropertyListLimits = .default) {
        self.limits = limits
    }

    func serialize(_ document: CodeResourcesDocument) throws -> Data {
        var files2Values: [String: ProvisioningProfileValue] = [:]
        files2Values.reserveCapacity(document.files2.count)
        for entry in document.files2 {
            let value: ProvisioningProfileValue
            switch entry {
            case .file(let seal):
                value = .dictionary(["hash2": .data(seal.hash2)])
            case .nestedCode(let seal):
                value = .dictionary(["cdhash": .data(seal.codeDirectoryHash)])
            }
            files2Values[entry.path.rawValue] = value
        }

        var root: [String: ProvisioningProfileValue] = ["files2": .dictionary(files2Values)]
        if let rules = document.rules2 {
            var rulesValues: [String: ProvisioningProfileValue] = [:]
            rulesValues.reserveCapacity(rules.count)
            for rule in rules {
                var entry: [String: ProvisioningProfileValue] = [:]
                if let optional = rule.optional {
                    entry["optional"] = .boolean(optional)
                }
                if let weight = rule.weight {
                    entry["weight"] = .integer(Int64(weight))
                }
                rulesValues[rule.pattern] = .dictionary(entry)
            }
            root["rules2"] = .dictionary(rulesValues)
        }

        let serializer = CanonicalPropertyListXMLSerializer(limits: limits)
        do {
            return try serializer.serialize(root: .dictionary(root))
        } catch {
            throw CodeResourcesError.serializationFailure
        }
    }
}

/// Reads CodeResources bytes into the typed document.
///
/// The parser accepts exactly what the serializer emits, plus any legal
/// property-list spelling of the same structure (binary or XML). Anything
/// outside the supported subset — v1 dictionaries, platform-specific
/// dictionaries, unknown entry keys — is a typed refusal, never a silent
/// drop. Parsing is read-only: no bytes are rewritten and no signature is
/// touched.
enum CodeResourcesParser {

    static let maximumInputByteCount = CodeResourcesSerializer.maximumDocumentByteCount

    static func parse(_ bytes: Data) throws -> CodeResourcesDocument {
        guard !bytes.isEmpty else { throw CodeResourcesError.emptyInput }
        guard bytes.count <= maximumInputByteCount else {
            throw CodeResourcesError.inputTooLarge
        }

        var format = PropertyListSerialization.PropertyListFormat.openStep
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(
                from: bytes,
                options: [],
                format: &format
            )
        } catch {
            throw CodeResourcesError.malformedPlist
        }
        guard format != .openStep else {
            throw CodeResourcesError.unsupportedPlistFormat
        }
        guard let dictionary = root as? [String: Any] else {
            throw CodeResourcesError.malformedPlist
        }
        guard dictionary.count <= ProvisioningProfileParsingLimits.default.maximumCollectionCount else {
            throw CodeResourcesError.resourceLimitExceeded
        }

        for key in dictionary.keys {
            guard key == "files2" || key == "rules2" else {
                throw CodeResourcesError.unsupportedTopLevelKey(key)
            }
        }
        guard let files2Any = dictionary["files2"] else {
            throw CodeResourcesError.missingFiles2
        }
        guard let files2 = files2Any as? [String: Any] else {
            throw CodeResourcesError.malformedPlist
        }
        guard files2.count <= ProvisioningProfileParsingLimits.default.maximumCollectionCount else {
            throw CodeResourcesError.resourceLimitExceeded
        }

        var entries: [CodeResourcesFileEntry] = []
        entries.reserveCapacity(files2.count)
        for (pathKey, value) in files2 {
            guard let path = BundlePath(rawValue: pathKey) else {
                throw CodeResourcesError.invalidPath(pathKey)
            }
            guard let entryDictionary = value as? [String: Any] else {
                throw CodeResourcesError.invalidEntryStructure(path: pathKey)
            }
            if let hash2Any = entryDictionary["hash2"] {
                guard entryDictionary.count == 1,
                      let hash2 = hash2Any as? Data,
                      hash2.count == FileResourceSeal.hash2ByteCount else {
                    throw CodeResourcesError.invalidEntryStructure(path: pathKey)
                }
                entries.append(.file(try FileResourceSeal(path: path, hash2: hash2)))
            } else if let cdhashAny = entryDictionary["cdhash"] {
                guard entryDictionary.count == 1,
                      let cdhash = cdhashAny as? Data,
                      cdhash.count == NestedCodeResourceSeal.codeDirectoryHashByteCount else {
                    throw CodeResourcesError.invalidEntryStructure(path: pathKey)
                }
                entries.append(.nestedCode(try NestedCodeResourceSeal(path: path, codeDirectoryHash: cdhash)))
            } else {
                throw CodeResourcesError.invalidEntryStructure(path: pathKey)
            }
        }

        var rules: [CodeResourcesRule]?
        if let rulesAny = dictionary["rules2"] {
            guard let rulesDictionary = rulesAny as? [String: Any] else {
                throw CodeResourcesError.malformedPlist
            }
            var parsedRules: [CodeResourcesRule] = []
            parsedRules.reserveCapacity(rulesDictionary.count)
            for (pattern, value) in rulesDictionary {
                guard let ruleDictionary = value as? [String: Any],
                      ruleDictionary.count <= 2 else {
                    throw CodeResourcesError.invalidRuleStructure(pattern: pattern)
                }
                var optional: Bool?
                var weight: Int?
                for (ruleKey, ruleValue) in ruleDictionary {
                    switch ruleKey {
                    case "optional":
                        guard let flag = ruleValue as? Bool else {
                            throw CodeResourcesError.invalidRuleStructure(pattern: pattern)
                        }
                        optional = flag
                    case "weight":
                        guard let number = ruleValue as? NSNumber,
                              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
                              let intValue = Int(exactly: number.int64Value) else {
                            throw CodeResourcesError.invalidRuleStructure(pattern: pattern)
                        }
                        weight = intValue
                    default:
                        throw CodeResourcesError.invalidRuleStructure(pattern: pattern)
                    }
                }
                parsedRules.append(try CodeResourcesRule(pattern: pattern, optional: optional, weight: weight))
            }
            rules = parsedRules
        }

        return try CodeResourcesDocument(files2: entries, rules2: rules, omitted: [])
    }
}
