import Foundation

/// The rule that turns an application's declarations into the file name its
/// signed artifact is given.
///
/// Naming is predictable on purpose. The name is derived only from what the
/// bundle declares — its display name, its marketing version, its build — and
/// is composed the way a person reads a release:
///
///     MyApp-1.2.3-456-signed.ipa
///
/// Declarations that are missing are simply absent, never filled in with a
/// placeholder or a guess:
///
///     MyApp-456-signed.ipa        (no marketing version declared)
///     MyApp-signed.ipa            (no version and no build declared)
///
/// The name is deterministic: the same declarations always produce the same
/// base name, and only the collision suffix varies. Every component is
/// sanitised to a conservative character set, so a display name containing
/// separators, controls, or path syntax cannot influence where a file lands.
///
/// Collisions never overwrite. When the name is already taken the next free
/// suffix is used, in order:
///
///     MyApp-1.2.3-456-signed-2.ipa
///     MyApp-1.2.3-456-signed-3.ipa
///
/// Comparison is case-insensitive, because the file systems ZynSign writes to
/// treat it that way: a name that differs only in case is a collision, not a
/// second file. The policy decides the name; the export store still refuses to
/// overwrite, so a name chosen against a stale list can never destroy bytes.
enum ExportNamingPolicy {

    /// The suffix every exported artifact's base name carries.
    static let signedSuffix = "signed"

    /// The extension every exported artifact carries.
    static let fileExtension = "ipa"

    /// The greatest length of one sanitised component, in characters.
    static let maximumComponentLength = 48

    /// The greatest length of a produced base name, in characters. The final
    /// file name adds the signed suffix and extension.
    static let maximumBaseLength = 96

    /// The greatest collision suffix the policy produces before it stops
    /// incrementing and asks the caller to supply a fresh name.
    static let maximumCollisionSuffix = 9_999

    /// The name used when neither a display name nor a bundle identifier can
    /// produce one. It is a fixed word, not an invented application name.
    static let fallbackComponent = "Application"

    // MARK: - Base name

    /// The predictable base name for one application, without the signed
    /// suffix and extension.
    ///
    /// The display name is preferred; a bundle identifier contributes its
    /// final component (the part that conventionally names the application)
    /// and only when no display name is available. The version and build are
    /// appended when they are declared.
    static func baseName(
        applicationName: String?,
        bundleIdentifier: String,
        shortVersion: String?,
        buildVersion: String?
    ) -> String {
        var components: [String] = []
        if let name = sanitizedComponent(applicationName) {
            components.append(name)
        } else if let derived = sanitizedComponent(bundleIdentifierComponent(bundleIdentifier)) {
            components.append(derived)
        } else {
            components.append(fallbackComponent)
        }
        if let version = sanitizedVersionComponent(shortVersion) {
            components.append(version)
        }
        if let build = sanitizedVersionComponent(buildVersion), build != components.last {
            components.append(build)
        }

        var base = components.joined(separator: "-")
        if base.count > maximumBaseLength {
            base = String(base.prefix(maximumBaseLength))
            base = trimmingSeparators(base)
        }
        if base.isEmpty {
            base = fallbackComponent
        }
        return base
    }

    // MARK: - File name

    /// The file name for `base`, avoiding every name in `existing`.
    ///
    /// The first candidate is the base name with the signed suffix. When it is
    /// taken, `-2`, `-3`, … are tried in order until a free name is found.
    /// Past `maximumCollisionSuffix` the last candidate is returned: the
    /// caller is expected to have passed the names actually present in the
    /// destination, and the store refuses to overwrite regardless.
    static func fileName(
        base: String,
        existing: Set<String>,
        fileExtension: String = ExportNamingPolicy.fileExtension
    ) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        for attempt in 0...maximumCollisionSuffix {
            let candidate = candidateName(base: base, attempt: attempt, fileExtension: fileExtension)
            if !taken.contains(candidate.lowercased()) {
                return candidate
            }
        }
        return candidateName(base: base, attempt: maximumCollisionSuffix, fileExtension: fileExtension)
    }

    /// One candidate name: attempt `0` is the unsuffixed name, attempt `n` is
    /// the name with suffix `n + 1`.
    ///
    /// Exposed so the commit path can retry with the next candidate when
    /// storage reports that a name appeared between listing and writing.
    static func candidateName(
        base: String,
        attempt: Int,
        fileExtension: String = ExportNamingPolicy.fileExtension
    ) -> String {
        let index = max(0, attempt)
        if index == 0 {
            return "\(base)-\(signedSuffix).\(fileExtension)"
        }
        return "\(base)-\(signedSuffix)-\(index + 1).\(fileExtension)"
    }

    /// Whether `name` is a name this policy could have produced: the signed
    /// base form with an optional collision suffix and the given extension.
    /// Used by cleanup and diagnostics to recognise ZynSign's own output
    /// rather than guessing from the extension alone.
    static func isPolicyName(_ name: String, fileExtension: String = ExportNamingPolicy.fileExtension) -> Bool {
        let lowercased = name.lowercased()
        let suffix = ".\(fileExtension.lowercased())"
        guard lowercased.hasSuffix(suffix) else { return false }
        let stem = String(lowercased.dropLast(suffix.count))
        guard stem.hasSuffix("-\(signedSuffix)") else { return false }
        let head = String(stem.dropLast(signedSuffix.count + 1))
        guard !head.isEmpty else { return false }
        guard let separator = head.lastIndex(of: "-") else { return true }
        let tail = String(head[head.index(after: separator)...])
        if !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return true
        }
        return true
    }

    // MARK: - Components

    /// Sanitises one declaration into a component that is safe to use in a
    /// file name, or returns `nil` when nothing usable remains.
    ///
    /// Letters, digits, `.`, `_`, and `-` are kept. Every other character —
    /// including spaces, separators, controls, and anything outside ASCII —
    /// becomes `-`; runs of separators collapse, and leading and trailing
    /// separators are removed. The result is bounded in length.
    static func sanitizedComponent(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        var out = ""
        out.reserveCapacity(min(text.count, maximumComponentLength) + 1)
        var lastWasSeparator = true
        for character in text {
            let sanitized = sanitized(character)
            if sanitized == "-" {
                if lastWasSeparator { continue }
                lastWasSeparator = true
            } else {
                lastWasSeparator = false
            }
            out.append(sanitized)
        }
        out = trimmingSeparators(out)
        guard !out.isEmpty else { return nil }
        return String(out.prefix(maximumComponentLength))
    }

    /// Sanitises a declared version or build.
    ///
    /// Versions are dotted numbers in practice, so the rule is the same as for
    /// any component with the same conservative character set. A declaration
    /// that sanitises away entirely contributes nothing rather than a
    /// placeholder, so a name never claims a version the bundle did not
    /// declare.
    static func sanitizedVersionComponent(_ text: String?) -> String? {
        guard let component = sanitizedComponent(text) else { return nil }
        let digits = component.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return component
    }

    /// The final component of a bundle identifier: `com.example.MyApp`
    /// becomes `MyApp`. Used only when no display name is available.
    static func bundleIdentifierComponent(_ bundleIdentifier: String) -> String {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(separator: ".").last.map(String.init), !last.isEmpty else {
            return trimmed
        }
        return last
    }

    // MARK: - Private

    private static func sanitized(_ character: Character) -> String {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return "-"
        }
        let value = scalar.value
        let isDigit = (48...57).contains(value)
        let isUpper = (65...90).contains(value)
        let isLower = (97...122).contains(value)
        if isDigit || isUpper || isLower { return String(character) }
        switch value {
        case 46, 95, 45: return String(character)     // . _ -
        default: return "-"
        }
    }

    private static func trimmingSeparators(_ text: String) -> String {
        var result = text
        while let first = result.first, first == "-" || first == "." {
            result.removeFirst()
        }
        while let last = result.last, last == "-" || last == "." {
            result.removeLast()
        }
        return result
    }
}
