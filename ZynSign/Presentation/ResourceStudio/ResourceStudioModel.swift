import Foundation
import Combine
import SwiftUI

/// Presentation state for the Resource & Asset Studio workspace.
///
/// Drives the dashboard, category explorers, search filtering, media loading,
/// audio playback, and inspector sheets.
@MainActor
public final class ResourceStudioModel: ObservableObject {

    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public enum Tab: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case icons = "Icons"
        case launch = "Launch"
        case images = "Images"
        case fonts = "Fonts"
        case localization = "Localization"
        case audio = "Audio"
        case video = "Video"
        case duplicates = "Duplicates"
        case relationships = "Groups"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .icons: return "app.badge"
            case .launch: return "arrow.up.right.video"
            case .images: return "photo"
            case .fonts: return "textformat"
            case .localization: return "globe"
            case .audio: return "waveform"
            case .video: return "film"
            case .duplicates: return "doc.on.doc"
            case .relationships: return "rectangle.3.group"
            }
        }
    }

    @Published public private(set) var phase: Phase = .loading
    @Published public private(set) var catalog: ResourceCatalog = .empty
    @Published public var selectedTab: Tab = .dashboard
    @Published public var selectedFilter: ResourceFilter = .all
    @Published public var searchText: String = ""
    @Published public var selectedResource: (any ResourceItem)? = nil
    @Published public var fullscreenImageItem: (any ResourceItem)? = nil
    @Published public var compareBaseLanguage: String = "en"
    @Published public var compareTargetLanguage: String = "fr"
    @Published public var selectedStringsFile: LocalizationFileAsset? = nil
    @Published public var previewFontSize: CGFloat = 18

    public let entry: LibraryEntry
    public let inspection: IPAResourceStudioInspection
    public let mediaLoader: ResourceMediaLoader
    public let audioService: AudioPlaybackService

    private var isInspecting = false

    public init(entry: LibraryEntry, inspection: IPAResourceStudioInspection) {
        self.entry = entry
        self.inspection = inspection
        self.mediaLoader = ResourceMediaLoader(inspection: inspection)
        self.audioService = AudioPlaybackService()
    }

    /// Loads the complete resource catalog for the imported application.
    public func load() async {
        if case .loaded = phase, !catalog.allAssets.isEmpty {
            return
        }
        await inspect()
    }

    /// Re-inspects the bundle resources.
    public func reload() async {
        mediaLoader.clearCache()
        audioService.stop()
        await inspect()
    }

    private func inspect() async {
        guard !isInspecting else { return }
        isInspecting = true
        defer { isInspecting = false }
        phase = .loading

        do {
            let cat = try await inspection.inspect(recordWithID: entry.record.id)
            self.catalog = cat
            // Default comparison languages if available
            if let first = cat.localizations.first?.languageCode {
                self.compareBaseLanguage = first
            }
            if cat.localizations.count > 1 {
                self.compareTargetLanguage = cat.localizations[1].languageCode
            }
            self.phase = .loaded
        } catch is CancellationError {
            // Task cancelled
        } catch {
            self.phase = .failed(Self.failureMessage(for: error))
        }
    }

    // MARK: - Search & Filters

    /// The list of items currently matching the active search query and filter.
    public var filteredItems: [any ResourceItem] {
        catalog.searchIndex.search(query: searchText, filter: selectedFilter)
    }

    /// Items for a specific category filtered by current search query.
    public func items(for category: ResourceCategory) -> [any ResourceItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            switch category {
            case .icon: return catalog.icons
            case .launch: return catalog.launchAsset.launchImages
            case .image: return catalog.images
            case .font: return catalog.fonts
            case .localization: return catalog.localizationFiles
            case .audio: return catalog.audio
            case .video: return catalog.videos
            case .other: return []
            }
        }
        return catalog.searchIndex.search(query: searchText).filter { $0.category == category }
    }

    // MARK: - Utilities

    public static func failureMessage(for error: any Error) -> String {
        if let z = error as? ZynSignError {
            return z.userMessage
        }
        return "The bundle resources could not be inspected."
    }
}
