import Foundation

/// The raw facts a volume capacity reading carries.
///
/// The numbers come from the platform's volume query; this type only
/// classifies them. Negative or absent values are represented as `nil`
/// rather than clamped, so "unknown" and "zero" stay different answers.
struct VolumeCapacityFacts: Equatable, Hashable, Sendable {
    /// Total volume capacity in bytes, when known.
    let totalBytes: Int?
    /// Bytes available for important usage, when known.
    let availableBytes: Int?
    /// Bytes the application's own container currently occupies, when known.
    let appUsageBytes: Int?
}

/// One band of free-space pressure.
enum StoragePressure: String, Equatable, Hashable, Sendable {
    /// More than 20% of the volume is free.
    case comfortable
    /// Between 5% and 20% of the volume is free.
    case attention
    /// Less than 5% of the volume is free.
    case critical
    /// The capacity is unknown; pressure cannot be judged.
    case unknown

    var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .attention: return "Low"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }
}

/// A classified storage reading the interface can render directly.
struct StorageGaugeReading: Equatable, Hashable, Sendable {
    /// The facts the classification was built from.
    let facts: VolumeCapacityFacts
    /// The free-space pressure band.
    let pressure: StoragePressure
    /// Free fraction of the volume (0…1), when computable.
    let freeFraction: Double?
    /// Used fraction of the volume (0…1), when computable.
    let usedFraction: Double?

    /// Builds the classification from raw facts.
    init(facts: VolumeCapacityFacts) {
        self.facts = facts
        if let total = facts.totalBytes, total > 0, let available = facts.availableBytes, available >= 0 {
            let free = min(1.0, Double(available) / Double(total))
            self.freeFraction = free
            self.usedFraction = max(0.0, 1.0 - free)
            switch free {
            case ..<0.05: self.pressure = .critical
            case ..<0.20: self.pressure = .attention
            default: self.pressure = .comfortable
            }
        } else {
            self.freeFraction = nil
            self.usedFraction = nil
            self.pressure = .unknown
        }
    }

    /// Formats a byte count for display, e.g. `1.2 GB`.
    static func humanReadable(_ bytes: Int?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
