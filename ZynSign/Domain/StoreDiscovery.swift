import Foundation

/// Metadata-derived grouping. The subtitle describes the observable signal;
/// a collection is never a quality, safety, or publisher endorsement.
struct StoreFeaturedCollection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let apps: [CatalogApp]
}

struct StoreCategoryCount: Identifiable {
    var id: String { name }
    let name: String
    let count: Int
}
