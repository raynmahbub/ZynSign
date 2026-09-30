import Foundation

/// The result of comparing two application version strings.
enum AppVersionOrder: Equatable, Hashable, Sendable {
    /// The left version is older than the right one.
    case older
    /// Both versions describe the same release.
    case same
    /// The left version is newer than the right one.
    case newer
    /// The versions cannot be compared — either side is unparseable.
    case incomparable
}

/// A strict, bounded comparator for application version strings.
///
/// Versions compare component by component on their numeric parts, the way
/// release feeds and catalogs expect: `1.9` < `1.10`, `2.0` == `2.0.0`,
/// and `1.2.3` < `1.2.3.1`. A trailing run of zeros does not change a
/// version's meaning. Anything that is not a dot-separated list of small
/// unsigned integers is incomparable rather than approximated — the update
/// tracker reports "cannot compare" instead of guessing.
enum AppVersionComparison {

    /// The most components a version string may carry. Longer strings are
    /// incomparable; no feed ZynSign reads needs more.
    static let maximumComponents = 6

    /// The most digits one component may carry.
    static let maximumComponentDigits = 9

    /// Compares two version strings.
    static func compare(_ lhs: String, _ rhs: String) -> AppVersionOrder {
        guard let left = parse(lhs), let right = parse(rhs) else { return .incomparable }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .older }
            if l > r { return .newer }
        }
        return .same
    }

    /// Whether `candidate` is a newer release than `installed`. Incomparable
    /// versions are never reported as updates.
    static func isUpdate(_ candidate: String, over installed: String) -> Bool {
        compare(candidate, installed) == .newer
    }

    /// Parses a version string into bounded numeric components, or `nil` when
    /// the string does not meet the shape rules. A leading `v` is accepted
    /// (`v1.2` == `1.2`) because release feeds disagree about it.
    static func parse(_ raw: String) -> [Int]? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= maximumComponents else { return nil }
        var components: [Int] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, part.count <= maximumComponentDigits else { return nil }
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            guard let value = Int(part) else { return nil }
            components.append(value)
        }
        return components
    }
}
