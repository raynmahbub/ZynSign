import Foundation
import CoreFoundation

/// Resource limits for property-list values retained from a profile's
/// entitlements dictionary.
///
/// Unknown root fields are ignored, but entitlements are preserved as typed
/// data. These limits keep recursive conversion bounded without imposing a
/// platform authorization policy on entitlement names or values.
struct ProvisioningProfileParsingLimits: Equatable, Hashable {

    /// Maximum recursive depth of an entitlement value.
    let maximumNestingDepth: Int

    /// Maximum number of scalar/container nodes converted in one entitlement
    /// tree.
    let maximumValueNodeCount: Int

    /// Maximum UTF-8 byte count of one profile string value.
    let maximumStringByteCount: Int

    /// Maximum size of one data value.
    let maximumDataByteCount: Int

    /// Maximum number of elements in one array or dictionary.
    let maximumCollectionCount: Int

    /// The default bounded policy for the profile parser.
    static let `default` = ProvisioningProfileParsingLimits(
        maximumNestingDepth: 32,
        maximumValueNodeCount: 50_000,
        maximumStringByteCount: 16 * 1_024,
        maximumDataByteCount: 1 * 1_024 * 1_024,
        maximumCollectionCount: 10_000
    )

    init(
        maximumNestingDepth: Int,
        maximumValueNodeCount: Int,
        maximumStringByteCount: Int,
        maximumDataByteCount: Int,
        maximumCollectionCount: Int
    ) {
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumValueNodeCount = maximumValueNodeCount
        self.maximumStringByteCount = maximumStringByteCount
        self.maximumDataByteCount = maximumDataByteCount
        self.maximumCollectionCount = maximumCollectionCount
    }
}

/// A property-list value retained by an entitlement without erasing its type.
///
/// The cases deliberately distinguish booleans from numeric values. Arrays
/// and dictionaries recurse through the same representation, and dictionary
/// keys remain strings as required by a property list. No incompatible value
/// is coerced to a string or silently dropped.
indirect enum ProvisioningProfileValue: Equatable, Hashable {

    case string(String)
    case boolean(Bool)
    case integer(Int64)
    case real(Double)
    case data(Data)
    case date(Date)
    case array([ProvisioningProfileValue])
    case dictionary([String: ProvisioningProfileValue])

    /// Converts one Foundation property-list value with an explicit resource
    /// policy. This is intentionally not a general `Any` wrapper.
    static func decode(
        _ value: Any,
        limits: ProvisioningProfileParsingLimits = .default
    ) throws -> ProvisioningProfileValue {
        var nodeCount = 0
        return try decode(value, depth: 0, limits: limits, nodeCount: &nodeCount)
    }

    private static func decode(
        _ value: Any,
        depth: Int,
        limits: ProvisioningProfileParsingLimits,
        nodeCount: inout Int
    ) throws -> ProvisioningProfileValue {
        guard depth <= limits.maximumNestingDepth else {
            throw ZynSignError.provisioningProfile(
                .resourceLimitExceeded,
                diagnosticDetail: "An entitlement value exceeded the maximum nesting depth."
            )
        }
        nodeCount += 1
        guard nodeCount <= limits.maximumValueNodeCount else {
            throw ZynSignError.provisioningProfile(
                .resourceLimitExceeded,
                diagnosticDetail: "The entitlement tree exceeded the maximum value-node count."
            )
        }

        if let string = value as? String {
            guard string.utf8.count <= limits.maximumStringByteCount else {
                throw ZynSignError.provisioningProfile(
                    .resourceLimitExceeded,
                    diagnosticDetail: "An entitlement string exceeded the configured size bound."
                )
            }
            return .string(string)
        }

        if let data = value as? Data {
            guard data.count <= limits.maximumDataByteCount else {
                throw ZynSignError.provisioningProfile(
                    .resourceLimitExceeded,
                    diagnosticDetail: "An entitlement data value exceeded the configured size bound."
                )
            }
            return .data(data)
        }

        if let date = value as? Date {
            guard date.timeIntervalSinceReferenceDate.isFinite else {
                throw ZynSignError.invalidProvisioningProfileDate(
                    diagnosticDetail: "An entitlement date was not finite."
                )
            }
            return .date(date)
        }

        if let number = value as? NSNumber {
            // CFBoolean and CFNumber both bridge through NSNumber. Check the
            // Core Foundation type first so an integer is never coerced into
            // a boolean merely because its numeric representation is `char`.
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            switch CFNumberGetType(number as CFNumber) {
            case .char, .sInt8, .sInt16, .sInt32, .sInt64, .cInt, .cLong, .cLongLong, .cfIndex:
                return .integer(number.int64Value)
            case .float32, .float64:
                let real = number.doubleValue
                guard real.isFinite else {
                    throw ZynSignError.provisioningProfile(
                        .unsupportedValue,
                        diagnosticDetail: "An entitlement numeric value was not finite."
                    )
                }
                return .real(real)
            default:
                throw ZynSignError.provisioningProfile(
                    .unsupportedValue,
                    diagnosticDetail: "An entitlement numeric representation is not supported."
                )
            }
        }

        if let bool = value as? Bool {
            return .boolean(bool)
        }

        if let array = value as? [Any] {
            guard array.count <= limits.maximumCollectionCount else {
                throw ZynSignError.provisioningProfile(
                    .resourceLimitExceeded,
                    diagnosticDetail: "An entitlement array exceeded the configured element bound."
                )
            }
            return .array(try array.map {
                try decode($0, depth: depth + 1, limits: limits, nodeCount: &nodeCount)
            })
        }

        if let dictionary = value as? [String: Any] {
            guard dictionary.count <= limits.maximumCollectionCount else {
                throw ZynSignError.provisioningProfile(
                    .resourceLimitExceeded,
                    diagnosticDetail: "An entitlement dictionary exceeded the configured entry bound."
                )
            }
            var decoded: [String: ProvisioningProfileValue] = [:]
            decoded.reserveCapacity(dictionary.count)
            for key in dictionary.keys.sorted() {
                guard let entry = dictionary[key] else {
                    throw ZynSignError.provisioningProfile(
                        .invalidFieldValue,
                        diagnosticDetail: "An entitlement dictionary entry could not be read."
                    )
                }
                guard !key.isEmpty, key.utf8.count <= limits.maximumStringByteCount,
                      !key.contains(where: { $0.isControl }) else {
                    throw ZynSignError.provisioningProfile(
                        .invalidFieldValue,
                        diagnosticDetail: "An entitlement dictionary key was empty, oversized, or contained a control character."
                    )
                }
                decoded[key] = try decode(
                    entry,
                    depth: depth + 1,
                    limits: limits,
                    nodeCount: &nodeCount
                )
            }
            return .dictionary(decoded)
        }

        throw ZynSignError.provisioningProfile(
            .unsupportedValue,
            diagnosticDetail: "An entitlement value used a type outside the supported property-list types."
        )
    }
}

/// The structured entitlements carried by a provisioning profile.
///
/// The dictionary preserves every key/value that the parser can represent;
/// unknown entitlement names are not discarded and their presence is not
/// treated as proof that the platform will authorize them.
struct ProvisioningProfileEntitlements: Equatable, Hashable {

    /// Entitlement values keyed by their exact property-list key.
    let values: [String: ProvisioningProfileValue]

    init(values: [String: ProvisioningProfileValue]) {
        self.values = values
    }

    /// The keys in deterministic lexical order for diagnostics and tests.
    var keys: [String] { values.keys.sorted() }

    /// Accesses one parsed entitlement without exposing a raw Foundation
    /// dictionary.
    subscript(key: String) -> ProvisioningProfileValue? {
        values[key]
    }

    /// The number of retained entitlement keys.
    var count: Int { values.count }
}
