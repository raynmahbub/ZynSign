import SwiftUI

struct StoreSavedAppsView: View {
    @ObservedObject var model: StoreBrowserModel
    var body: some View {
        List {
            if model.savedApps.isEmpty {
                ContentUnavailableView("Nothing Saved Yet", systemImage: "bookmark", description: Text("Save an app for later. Saving never downloads it."))
            } else {
                Section("Saved on This Device") {
                    ForEach(model.savedApps) { app in
                        HStack(spacing: 8) {
                            StoreAppLink(app: app, model: model)
                            Button(role: .destructive) { Task { await model.save(app, isSaved: false) } } label: {
                                Image(systemName: "bookmark.slash").frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(app.name) from saved apps")
                        }
                    }
                }
            }
        }
        .navigationTitle("Saved Items")
    }
}

struct StoreCollectionsView: View {
    @ObservedObject var model: StoreBrowserModel
    var body: some View {
        List {
            Section {
                Text("Collections group observable repository metadata. They do not imply quality, safety, or endorsement.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.collections) { collection in
                NavigationLink { StoreCollectionDetailView(collection: collection, model: model) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(collection.title).font(.headline)
                        Text(collection.subtitle).font(.caption).foregroundStyle(.secondary)
                        Text("\(collection.apps.count) catalog entries").font(.caption2).foregroundStyle(.tertiary)
                    }.padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Collections")
    }
}

struct StoreCollectionDetailView: View {
    let collection: StoreFeaturedCollection
    @ObservedObject var model: StoreBrowserModel
    var body: some View {
        List {
            Section {
                Text(collection.subtitle).font(.subheadline).foregroundStyle(.secondary)
                Text("This collection reflects source metadata only; it is not an endorsement or trust assessment.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Apps · \(collection.apps.count)") {
                if collection.apps.isEmpty { Text("No matching repository metadata is currently available.").foregroundStyle(.secondary) }
                ForEach(collection.apps) { StoreAppLink(app: $0, model: model) }
            }
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StoreDeveloperView: View {
    let developer: String
    @ObservedObject var model: StoreBrowserModel
    private var apps: [CatalogApp] {
        model.apps.filter { $0.developer.compare(developer, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var sources: [CatalogSource] {
        let ids = Set(apps.map(\.sourceID))
        return model.snapshot.sources.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
    }
    private var updates: [CatalogApp] {
        apps.filter { $0.latest.date != nil }.sorted { ($0.latest.date ?? .distantPast) > ($1.latest.date ?? .distantPast) }
    }
    private var categories: [String] { Array(Set(apps.map(\.category))).sorted() }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    StoreArtwork(url: apps.first?.developerIconURL, symbol: "person.crop.circle.fill")
                        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(developer).font(.title2.bold())
                        Text("\(apps.count) catalog listings").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                Text("Developer names and icons are supplied by repositories and are not independently verified.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories, id: \.self) { category in
                        NavigationLink { StoreCategoryAppsView(category: category, model: model) } label: {
                            LabeledContent(category, value: "\(apps.filter { $0.category == category }.count)")
                        }
                    }
                }
            }
            Section("Latest Updates") {
                if updates.isEmpty { Text("No release dates are supplied for this developer’s listings.").foregroundStyle(.secondary) }
                ForEach(updates.prefix(12)) { StoreAppLink(app: $0, model: model) }
            }
            Section("Published Apps") {
                ForEach(apps) { StoreAppLink(app: $0, model: model) }
            }
            Section("Repository Sources") {
                ForEach(sources) { source in
                    NavigationLink { StoreSourceDetailView(id: source.id, model: model) } label: {
                        HStack(spacing: 10) {
                            StoreArtwork(url: source.iconURL, symbol: "globe")
                                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name).font(.subheadline.weight(.semibold))
                                Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(developer)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StoreCategoryExplorerView: View {
    @ObservedObject var model: StoreBrowserModel
    var body: some View {
        List {
            Section {
                Text("Counts are catalog entries reported by currently enabled sources. Category labels come from source metadata.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Categories") {
                ForEach(model.categoryCounts) { category in
                    NavigationLink { StoreCategoryAppsView(category: category.name, model: model) } label: {
                        LabeledContent(category.name, value: "\(category.count)")
                    }
                }
            }
        }
        .navigationTitle("Categories")
    }
}

struct StoreCategoryAppsView: View {
    let category: String
    @ObservedObject var model: StoreBrowserModel
    private var apps: [CatalogApp] { model.apps.filter { $0.category.compare(category, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } }
    var body: some View {
        List { ForEach(apps) { StoreAppLink(app: $0, model: model) } }
            .navigationTitle(category)
            .overlay {
                if apps.isEmpty { ContentUnavailableView("No Apps", systemImage: "square.grid.2x2", description: Text("No cached listings use this category.")) }
            }
    }
}
