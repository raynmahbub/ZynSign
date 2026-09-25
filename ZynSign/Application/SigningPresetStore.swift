import Foundation

/// The persistence boundary for reusable signing presets.
///
/// The store keeps `SigningPreset` values across launches and hands them
/// back unchanged. It is the seam behind which the storage technology
/// lives: callers see domain values and typed errors, never a file or a
/// database context. The port is deliberately small — the operations the
/// presets feature needs — and is not a general query abstraction.
protocol SigningPresetStore: Sendable {

    /// Lists every stored preset, in a deterministic order suitable for
    /// display.
    func allPresets() async throws -> [SigningPreset]

    /// Retrieves the preset with `id`, or `nil` when none exists.
    func preset(withID id: PresetIdentifier) async throws -> SigningPreset?

    /// Inserts or replaces a preset, keyed on its identifier.
    func upsert(_ preset: SigningPreset) async throws

    /// Removes the preset with `id`. No-op when no such preset exists.
    func remove(presetWithID id: PresetIdentifier) async throws

    /// The number of stored presets. Convenience for "X saved" UI.
    func count() async throws -> Int
}
