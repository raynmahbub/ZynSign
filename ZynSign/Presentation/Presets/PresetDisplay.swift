import SwiftUI

/// Display helpers for signing presets. Views use these so a card, a
/// VoiceOver label, and a compatibility row describe the same facts.
enum PresetDisplay {
    static func lastUsed(_ date: Date?) -> String {
        guard let date else { return "Never used" }
        return "Last used \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func certificateName(_ preset: SigningPreset, inventory: PresetInventory?) -> String {
        guard let fingerprint = preset.certificateFingerprint else { return "No certificate" }
        if let match = inventory?.certificate(matching: fingerprint) {
            return match.displayName
        }
        return "Certificate not in Keychain"
    }

    static func profileName(_ preset: SigningPreset, inventory: PresetInventory?) -> String {
        if let match = inventory?.profile(matching: preset) {
            return match.name
        }
        return preset.provisioningProfileName ?? "No profile"
    }

    static func teamName(_ preset: SigningPreset, inventory: PresetInventory?) -> String {
        if let team = preset.teamIdentifier { return team }
        if let team = inventory?.profile(matching: preset)?.teamIdentifier { return team }
        if let fingerprint = preset.certificateFingerprint,
           let team = inventory?.certificate(matching: fingerprint)?.teamIdentifier {
            return team
        }
        return "No team"
    }

    static func badgeKind(for overall: PresetCompatibilityReport.Overall) -> ZStatusBadge.Kind {
        switch overall {
        case .ready: return .success
        case .attention: return .warning
        case .blocked: return .error
        case .incomplete: return .neutral
        }
    }

    static func checkKind(_ status: PresetCompatibilityCheck.Status) -> ZStatusBadge.Kind {
        switch status {
        case .passing: return .success
        case .warning: return .warning
        case .failing: return .error
        case .unknown: return .neutral
        }
    }
}

extension View {
    /// A control large enough to hit without precision, including with
    /// Dynamic Type and on iPad.
    func presetTouchTarget() -> some View {
        frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Progress for the guided builder. Going back changes the step only.
struct PresetBuilderSession: Equatable {
    var step: Int
    var draft: SigningPreset

    mutating func goBack() {
        step = max(0, step - 1)
    }

    mutating func goForward(maximum: Int) {
        step = min(maximum, step + 1)
    }
}
