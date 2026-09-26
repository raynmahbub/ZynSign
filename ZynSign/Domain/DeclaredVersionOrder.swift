import Foundation

/// Orders the version strings applications declare the way people read
/// them.
///
/// A declared version is free text: `CFBundleShortVersionString` and
/// `CFBundleVersion` are whatever the developer typed. This ordering reads
/// the common shapes correctly — `1.10` is newer than `1.9`, `1.2` and
/// `1.2.0` are the same version, and `1.0b1` comes before `1.0` — without
/// pretending to understand every scheme. Where a comparison cannot be made
/// honestly, for example because one side declares nothing, the answer is
/// `nil` and the caller must ask the user rather than guess.
///
/// The ordering is advisory. It feeds the Import Hub's *suggestions*; no
/// library entry is ever replaced because of it without the user's
/// explicit choice.
enum DeclaredVersionOrder {

    /// Compares two applications by declared marketing version, then by
    /// build number when the marketing versions are the same.
    ///
    /// Returns `nil` when the declarations cannot be ordered: one side
    /// declares a version and the other does not, or the marketing
    /// versions are equal and only one side declares a build.
    static func compare(
        version lhsVersion: String?,
        build lhsBuild: String?,
        with rhsVersion: String?,
        build rhsBuild: String?
    ) -> ComparisonResult? {
        switch (normalized(lhsVersion), normalized(rhsVersion)) {
        case let (lhs?, rhs?):
            let result = compare(lhs, rhs)
            guard result == .orderedSame else { return result }
            return compareBuilds(lhsBuild, rhsBuild)
        case (nil, nil):
            return compareBuilds(lhsBuild, rhsBuild)
        default:
            return nil
        }
    }

    /// Compares two declared version strings component by component.
    ///
    /// The strings are split into runs of digits and runs of letters;
    /// separators (`.`, `-`, `_`, `+`, spaces, and anything else that is
    /// neither) only delimit. Numbers compare by value however long they
    /// are, letters compare case-insensitively, a missing component reads
    /// as zero, and a letter run sorts before any number — which is what
    /// makes `1.0b1` a pre-release of `1.0`.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(of: lhs)
        let right = components(of: rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftComponent = index < left.count ? left[index] : .number("0")
            let rightComponent = index < right.count ? right[index] : .number("0")
            let result = leftComponent.compare(to: rightComponent)
            if result != .orderedSame {
                return result
            }
        }
        return .orderedSame
    }

    // MARK: - Components

    private enum Component {
        /// A run of decimal digits, with leading zeros removed.
        case number(String)
        /// A run of letters, lowercased.
        case text(String)

        func compare(to other: Component) -> ComparisonResult {
            switch (self, other) {
            case let (.number(lhs), .number(rhs)):
                // Leading zeros are gone, so a longer run is a larger
                // number and equal lengths compare digit by digit. No
                // integer conversion means no overflow on absurd input.
                if lhs.count != rhs.count {
                    return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
                }
                return ordered(lhs, rhs)
            case let (.text(lhs), .text(rhs)):
                return ordered(lhs, rhs)
            case (.text, .number):
                return .orderedAscending
            case (.number, .text):
                return .orderedDescending
            }
        }

        private func ordered(_ lhs: String, _ rhs: String) -> ComparisonResult {
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
    }

    private static func components(of version: String) -> [Component] {
        var components: [Component] = []
        var digits = ""
        var letters = ""

        func flushDigits() {
            guard !digits.isEmpty else { return }
            let trimmed = digits.drop(while: { $0 == "0" })
            components.append(.number(trimmed.isEmpty ? "0" : String(trimmed)))
            digits = ""
        }

        func flushLetters() {
            guard !letters.isEmpty else { return }
            components.append(.text(letters.lowercased()))
            letters = ""
        }

        for character in version {
            if character.isASCII && character.isNumber {
                flushLetters()
                digits.append(character)
            } else if character.isLetter {
                flushDigits()
                letters.append(character)
            } else {
                flushDigits()
                flushLetters()
            }
        }
        flushDigits()
        flushLetters()
        return components
    }

    private static func compareBuilds(_ lhs: String?, _ rhs: String?) -> ComparisonResult? {
        switch (normalized(lhs), normalized(rhs)) {
        case let (lhs?, rhs?):
            return compare(lhs, rhs)
        case (nil, nil):
            return .orderedSame
        default:
            return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
