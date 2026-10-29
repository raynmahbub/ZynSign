import AppIntents
import Foundation

/// Siri & Shortcuts integration for ZynSign (`AppIntents` framework — zero third-party deps).
struct OpenZynSignLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ZynSign Library"
    static let description = IntentDescription("Opens ZynSign directly to your Application Library.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .zynSignShortcutNavigate, object: "library")
        return .result()
    }
}

struct OpenZynSignDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ZynSign Downloads"
    static let description = IntentDescription("Opens ZynSign directly to the Download Center.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .zynSignShortcutNavigate, object: "downloads")
        return .result()
    }
}

struct SyncPortableWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync ZynSign Portable Workspace"
    static let description = IntentDescription("Mirrors ZynSign sources, profiles, tweaks, and packages into Documents/ZynSignPortable.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = CompositionRoot.makeApplicationEnvironment()
        if let service = env.portableWorkspaceSync {
            let report = try await service.exportPortableMirror(environment: env)
            return .result(dialog: "Mirrored \(report.packagesCount) package(s) and \(report.sourcesCount) source(s) to ZynSignPortable.")
        }
        return .result(dialog: "Opened ZynSign.")
    }
}

struct ZynSignShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenZynSignLibraryIntent(),
            phrases: [
                "Open Library in \(.applicationName)",
                "Show my apps in \(.applicationName)"
            ],
            shortTitle: "Open Library",
            systemImageName: "square.stack.3d.up"
        )
        AppShortcut(
            intent: OpenZynSignDownloadsIntent(),
            phrases: [
                "Open Downloads in \(.applicationName)"
            ],
            shortTitle: "Downloads",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: SyncPortableWorkspaceIntent(),
            phrases: [
                "Sync Portable Workspace in \(.applicationName)"
            ],
            shortTitle: "Sync Portable Folder",
            systemImageName: "folder.badge.gearshape"
        )
    }
}
