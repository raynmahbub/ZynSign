import SwiftUI

/// ZynSign bottom sheet — interactive sheet for pickers and options.
///
/// Wraps SwiftUI `.sheet` with ZDL detents, grabber, and haptics.
/// Usage: `.zBottomSheet(isPresented: $show, detents: [.medium, .large]) { content }`
struct ZBottomSheet<Content: View>: View {
    let detents: Set<PresentationDetent>
    let content: Content

    init(detents: Set<PresentationDetent> = [.medium, .large], @ViewBuilder content: () -> Content) {
        self.detents = detents; self.content = content()
    }

    var body: some View {
        content
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
            .presentationCornerRadius(ZRadius.lg)
    }
}

extension View {
    func zBottomSheet<Content: View>(isPresented: Binding<Bool>, detents: Set<PresentationDetent> = [.medium, .large], @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented) {
            ZBottomSheet(detents: detents, content: content)
        }
    }

    func zBottomSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, detents: Set<PresentationDetent> = [.medium, .large], @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item) { item in
            ZBottomSheet(detents: detents) { content(item) }
        }
    }
}

/// ZynSign “smart sheet” header — consistent grabber + title + close
struct ZSheetHeader: View {
    let title: String
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let onClose {
                Button { onClose(); ZHaptics.tap() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, ZSpacing.md)
        .padding(.vertical, ZSpacing.sm)
    }
}
