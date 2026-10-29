import AppIntents
import Foundation

/// Siri & Shortcuts integration for ZynSign (`AppIntents` framework — zero third-party deps).
struct OpenZynSignLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Open ZynSign Library"
    static var description = IntentDescription("Opens ZynSign directly to your Application Library.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .zynSignShortcutNavigate, object: "library")
        return .result()
    }
}

struct OpenZynSignDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open ZynSign Downloads"
    static var description = IntentDescription("Opens ZynSign directly to the Download Center.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .zynSignShortcutNavigate, object: "downloads")
        return .result()
    }
}

struct SyncPortableWorkspaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync ZynSign Portable Workspace"
    static var description = IntentDescription("Mirrors ZynSign sources, profiles, tweaks, and packages into Documents/ZynSignPortable.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .zynSignShortcutNavigate, object: "sync-portable")
        return .result(dialog: "Syncing ZynSignPortable workspace.")
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
