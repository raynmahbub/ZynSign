import Foundation

/// Atomic JSON persistence for per-tweak Auto-Inject rules (`TweakAutoInjectRule`).
final class FileTweakAutoInjectStore: TweakAutoInjectRuleStore, @unchecked Sendable {

    private let location: URL
    private let lock = NSLock()

    init(location: URL) {
        self.location = location
    }

    func allRules() throws -> [TweakAutoInjectRule] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func saveRule(_ rule: TweakAutoInjectRule) throws {
        lock.lock()
        defer { lock.unlock() }
        var current = (try? loadUnlocked()) ?? []
        current.removeAll { $0.id == rule.id }
        if rule.scope != .disabled {
            current.append(rule)
        }
        try writeUnlocked(current)
    }

    func removeRule(tweakID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var current = (try? loadUnlocked()) ?? []
        current.removeAll { $0.id == tweakID }
        try writeUnlocked(current)
    }

    private func loadUnlocked() throws -> [TweakAutoInjectRule] {
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        let data = try Data(contentsOf: location)
        return try JSONDecoder().decode([TweakAutoInjectRule].self, from: data)
    }

    private func writeUnlocked(_ rules: [TweakAutoInjectRule]) throws {
        let parent = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(rules)
        try data.write(to: location, options: .atomic)
    }
}
