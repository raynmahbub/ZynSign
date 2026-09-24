import Foundation

/// Failures raised while producing the canonical XML property-list
/// serialization of a typed property-list value tree.
///
/// The cases are structural: they name the stage that refused, never the
/// contents that were refused. No serialized text appears in a diagnostic.
enum CanonicalPropertyListError: Error, Equatable {
    /// The root of the tree was not a dictionary. The canonical form is only
    /// defined for the document shapes ZynSign serializes.
    case rootMustBeDictionary
    /// A value used a type the canonical form does not carry. Dates are the
    /// notable case: ZynSign has no established deterministic date encoding.
    case unsupportedValueType
    /// A real number was not finite and therefore has no decimal text form.
    case nonFiniteNumber
    /// A key failed the safety rules: empty, oversized, or control characters.
    case invalidKey
    /// The tree exceeded the configured depth, node, or collection bounds.
    case resourceLimitExceeded
    /// A checked arithmetic step overflowed while planning the output.
    case integerOverflow
    /// The serialized document exceeded its configured maximum length.
    case outputTooLarge
}

/// Bounds applied while serializing a canonical property list. These are
/// ZynSign policy, not Apple limits: they bound work performed on untrusted
/// trees so serialization cannot be turned into a resource-exhaustion vector.
struct CanonicalPropertyListLimits: Equatable, Hashable {

    /// Maximum recursive depth of the serialized tree.
    let maximumNestingDepth: Int

    /// Maximum number of nodes serialized in one document.
    let maximumNodeCount: Int

    /// Maximum UTF-8 byte count of one key or string value.
    let maximumStringByteCount: Int

    /// Maximum serialized document length in bytes.
    let maximumDocumentByteCount: Int

    static let `default` = CanonicalPropertyListLimits(
        maximumNestingDepth: 32,
        maximumNodeCount: 50_000,
        maximumStringByteCount: 16 * 1_024,
        maximumDocumentByteCount: 8 * 1_024 * 1_024
    )

    init(
        maximumNestingDepth: Int,
        maximumNodeCount: Int,
        maximumStringByteCount: Int,
        maximumDocumentByteCount: Int
    ) {
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumNodeCount = maximumNodeCount
        self.maximumStringByteCount = maximumStringByteCount
        self.maximumDocumentByteCount = maximumDocumentByteCount
    }
}

/// Deterministic XML property-list serialization over the existing typed
/// property-list value tree (`ProvisioningProfileValue`).
///
/// Foundation's property-list writers are not used for output because their
/// dictionary ordering and formatting are not contractual: two runs, or two
/// semantically equal trees, could produce different bytes. Where a digest is
/// computed over serialized bytes, the bytes must be a function of the value
/// alone. This serializer is that function.
///
/// The canonicalization rule, in full — this is ZynSign's rule, established
/// for determinism, **not** a claim that Apple's tools emit byte-identical
/// output (see `docs/architecture/signing-metadata.md` for the evidence
/// level):
///
/// 1. The document is UTF-8 XML with the standard property-list header:
///    the XML declaration, the property-list DTD doctype, and
///    `<plist version="1.0">`, each followed by one newline.
/// 2. Dictionary keys are emitted in ascending UTF-8 byte order. This is a
///    total order over distinct keys and never depends on hash seed or
///    insertion order.
/// 3. Indentation is one tab per nesting depth; every element occupies its
///    own line, terminated by one newline. The document ends with
///    `</plist>` followed by a newline.
/// 4. Booleans emit `<true/>` / `<false/>`; integers emit decimal
///    `<integer>` text; reals emit `<real>` text using the shortest
///    representation that round-trips the exact `Double` value, and a
///    non-finite real is an error rather than a written value.
/// 5. Data emits base64 (standard alphabet, padded) wrapped at 76 characters
///    per line, each continuation line indented one level deeper.
/// 6. Keys and string values are XML-escaped for `&`, `<`, and `>`. No other
///    transformation is applied to any text: values are never normalized,
///    trimmed, or re-typed.
///
/// The parse direction is *not* re-implemented: reading property-list bytes
/// continues to go through the existing Foundation-based boundary and the
/// bounded `ProvisioningProfileValue` conversion, which accepts any legal
/// plist spelling. Canonicalization governs bytes ZynSign writes and hashes.
struct CanonicalPropertyListXMLSerializer {

    let limits: CanonicalPropertyListLimits

    init(limits: CanonicalPropertyListLimits = .default) {
        self.limits = limits
    }

    /// Serializes one dictionary-shaped tree to exact canonical bytes.
    ///
    /// The input is never mutated; the output is freshly allocated. A value
    /// the canonical form cannot represent is a typed error, never a coerced
    /// substitute.
    func serialize(root: ProvisioningProfileValue) throws -> Data {
        guard case .dictionary = root else {
            throw CanonicalPropertyListError.rootMustBeDictionary
        }
        var context = SerializationContext(limits: limits)
        context.appendLine("<?xml version=\"1.0\" encoding=\"UTF-8\"?>", depth: 0)
        context.appendLine("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">", depth: 0)
        context.appendLine("<plist version=\"1.0\">", depth: 0)
        try serializeValue(root, depth: 0, context: &context)
        context.appendLine("</plist>", depth: 0)
        guard context.byteCount <= limits.maximumDocumentByteCount else {
            throw CanonicalPropertyListError.outputTooLarge
        }
        return context.data
    }

    // MARK: - Value emission

    private func serializeValue(
        _ value: ProvisioningProfileValue,
        depth: Int,
        context: inout SerializationContext
    ) throws {
        guard depth <= limits.maximumNestingDepth else {
            throw CanonicalPropertyListError.resourceLimitExceeded
        }
        try context.countNode()
        switch value {
        case .string(let text):
            context.appendLine("<string>\(Self.escaped(text))</string>", depth: depth)
        case .boolean(let flag):
            context.appendLine(flag ? "<true/>" : "<false/>", depth: depth)
        case .integer(let number):
            context.appendLine("<integer>\(number)</integer>", depth: depth)
        case .real(let number):
            guard number.isFinite else {
                throw CanonicalPropertyListError.nonFiniteNumber
            }
            context.appendLine("<real>\(Self.realText(number))</real>", depth: depth)
        case .data(let bytes):
            try serializeData(bytes, depth: depth, context: &context)
        case .date:
            // No deterministic canonical date encoding is established.
            throw CanonicalPropertyListError.unsupportedValueType
        case .array(let elements):
            context.appendLine("<array>", depth: depth)
            for element in elements {
                try serializeValue(element, depth: depth + 1, context: &context)
            }
            context.appendLine("</array>", depth: depth)
        case .dictionary(let entries):
            context.appendLine("<dict>", depth: depth)
            for key in entries.keys.sorted(by: Self.utf8Ascending) {
                try validateKey(key)
                try context.countNode()
                context.appendLine("<key>\(Self.escaped(key))</key>", depth: depth + 1)
                guard let entry = entries[key] else {
                    throw CanonicalPropertyListError.invalidKey
                }
                try serializeValue(entry, depth: depth + 1, context: &context)
            }
            context.appendLine("</dict>", depth: depth)
        }
    }

    private func serializeData(
        _ bytes: Data,
        depth: Int,
        context: inout SerializationContext
    ) throws {
        context.appendLine("<data>", depth: depth)
        let base64 = bytes.base64EncodedString()
        var start = base64.startIndex
        while start < base64.endIndex {
            let end = base64.index(start, offsetBy: 76, limitedBy: base64.endIndex) ?? base64.endIndex
            context.appendLine(String(base64[start..<end]), depth: depth + 1)
            start = end
        }
        context.appendLine("</data>", depth: depth)
    }

    private func validateKey(_ key: String) throws {
        guard !key.isEmpty,
              key.utf8.count <= limits.maximumStringByteCount,
              !key.contains(where: { $0.isControl }) else {
            throw CanonicalPropertyListError.invalidKey
        }
    }

    // MARK: - Text forms

    /// XML text escaping for element content. Only the three characters that
    /// terminate element content are replaced; no other normalization occurs.
    static func escaped(_ text: String) -> String {
        guard text.contains("&") || text.contains("<") || text.contains(">") else {
            return text
        }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// The shortest decimal text that round-trips the exact `Double`.
    /// Swift's default `Double` description is that representation.
    static func realText(_ value: Double) -> String {
        String(describing: value)
    }

    /// A total order over keys: ascending UTF-8 bytes. String's own `<`
    /// compares under Unicode canonical equivalence, under which two
    /// different byte sequences can compare equal; digest input must not
    /// depend on that equivalence, so the byte order is used instead.
    static func utf8Ascending(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }
}

/// Accumulates canonical output under the configured bounds.
private struct SerializationContext {
    let limits: CanonicalPropertyListLimits
    var data = Data()
    var nodeCount = 0
    var byteCount: Int { data.count }

    init(limits: CanonicalPropertyListLimits) {
        self.limits = limits
        data.reserveCapacity(1_024)
    }

    mutating func countNode() throws {
        nodeCount += 1
        guard nodeCount <= limits.maximumNodeCount else {
            throw CanonicalPropertyListError.resourceLimitExceeded
        }
    }

    mutating func appendLine(_ line: String, depth: Int) {
        for _ in 0..<max(depth, 0) {
            data.append(0x09) // tab
        }
        data.append(contentsOf: line.utf8)
        data.append(0x0A) // newline
    }
}
