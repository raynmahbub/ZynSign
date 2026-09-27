import SwiftUI
import UIKit

struct StoreGallerySelection: Identifiable { let index: Int; var id: Int { index } }
struct StoreScreenshotGallery: View {
    let urls: [URL]
    let initial: Int
    let name: String
    @State private var selection = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    StoreZoomPage(url: url, active: abs(selection - index) <= 1)
                        .tag(index).accessibilityLabel("\(name), screenshot \(index + 1) of \(urls.count)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .navigationTitle("\(selection + 1) of \(urls.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.keyboardShortcut(.escape, modifiers: []) }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { selection = max(0, selection - 1) } label: { Label("Previous", systemImage: "chevron.left") }
                        .disabled(selection == 0).keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer()
                    Text("Pinch to zoom").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { selection = min(urls.count - 1, selection + 1) } label: { Label("Next", systemImage: "chevron.right") }
                        .disabled(selection == urls.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
                }
            }
            .onAppear { selection = initial }
        }
    }
}
private struct StoreZoomPage: View {
    let url: URL
    let active: Bool
    @State private var image: UIImage?
    @State private var finished = false
    @State private var scale: CGFloat = 1
    var body: some View {
        VStack {
            if let image {
                StoreZoomImage(image: image, requestedScale: scale)
                HStack {
                    Button("Zoom Out") { scale = max(1, scale - 1) }.frame(minWidth: 44, minHeight: 44)
                    Button("Reset Zoom") { scale = 1 }.frame(minWidth: 44, minHeight: 44)
                    Button("Zoom In") { scale = min(4, scale + 1) }.frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.bordered)
            } else if finished { ContentUnavailableView("Image Unavailable", systemImage: "photo", description: Text("This screenshot is not cached and could not be loaded.")) }
            else { ProgressView("Loading screenshot") }
        }
        .task(id: active) {
            guard active, image == nil else { return }
            image = await StoreImageCache.shared.image(url); finished = true
        }
    }
}
private struct StoreZoomImage: UIViewRepresentable {
    let image: UIImage
    let requestedScale: CGFloat
    func makeUIView(context: Context) -> ZoomCanvas {
        let view = ZoomCanvas()
        view.imageView.image = image
        return view
    }
    func updateUIView(_ view: ZoomCanvas, context: Context) {
        if view.lastRequestedScale != requestedScale {
            view.lastRequestedScale = requestedScale
            view.setZoomScale(requestedScale, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
    final class ZoomCanvas: UIScrollView, UIScrollViewDelegate {
        let imageView = UIImageView()
        var lastRequestedScale: CGFloat = 1
        private var lastSize = CGSize.zero
        init() {
            super.init(frame: .zero)
            delegate = self; minimumZoomScale = 1; maximumZoomScale = 4
            showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastSize {
                lastSize = bounds.size
                setZoomScale(1, animated: false)
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
