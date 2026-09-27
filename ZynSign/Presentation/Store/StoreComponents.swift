import SwiftUI

struct StoreArtwork: View {
    let url: URL?
    var symbol = "app.fill"
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(.secondarySystemFill)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: symbol).resizable().scaledToFit().padding(16).foregroundStyle(.secondary) }
        }
        .clipped()
        .task(id: url) {
            image = nil
            if let url {
                let loaded = await StoreImageCache.shared.image(url)
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
        .accessibilityHidden(true)
    }
}

struct StoreAppLink: View {
    let app: CatalogApp
    @ObservedObject var model: StoreBrowserModel
    var body: some View {
        NavigationLink { StoreAppDetailView(app: app, model: model) } label: {
            HStack(alignment: .top, spacing: 12) {
                StoreArtwork(url: app.iconURL).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: ZRadius.appIcon(side: 56), style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(.headline)
                    Text(app.developer).font(.subheadline).foregroundStyle(.secondary)
                    Text("\(app.latest.version) · \(app.category)").font(.caption).foregroundStyle(.secondary)
                    Label(model.sourceName(app), systemImage: "globe").font(.caption).foregroundStyle(.tint)
                }
            }.padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), by \(app.developer), version \(app.latest.version), \(app.category), source \(model.sourceName(app))")
    }
}
struct StoreFeatureCard: View {
    let app: CatalogApp
    let source: String
    @ScaledMetric(relativeTo: .body) private var width = 175.0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StoreArtwork(url: app.iconURL).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: ZRadius.appIcon(side: 72), style: .continuous))
            Text(app.name).font(.headline)
            Text(app.subtitle ?? app.developer).font(.caption).foregroundStyle(.secondary)
            Text("v\(app.latest.version)").font(.caption.monospacedDigit())
            Label(source, systemImage: "globe").font(.caption).foregroundStyle(.tint)
        }
        .frame(width: min(width, 280), alignment: .leading).padding(16)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}
struct StoreHealthBadge: View {
    let source: CatalogSource
    var body: some View {
        let status = source.status()
        Label(status.rawValue.capitalized, systemImage: status == .healthy ? "checkmark.circle" : (status == .offline ? "wifi.slash" : "exclamationmark.triangle"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(status == .healthy ? Color.green : (status == .offline ? Color.secondary : Color.orange))
            .accessibilityLabel("Source health: \(status.rawValue). Health describes availability, not trust.")
    }
}
extension View {
    func storeNotice(_ message: Binding<String?>) -> some View {
        alert("Store Needs Attention", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: { Text(message.wrappedValue ?? "") }
    }
}
