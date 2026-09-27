import SwiftUI
import UniformTypeIdentifiers

/// How an import drop target shows that files are being dragged over it.
enum ImportDropTargetStyle {

    /// A full-area highlight with the number of files that would be
    /// imported — for whole screens such as Home and the Library.
    case overlay

    /// A lift-and-tint highlight — for a single control such as an Import
    /// button.
    case button

    /// No highlight of its own — for views that draw their own, like the
    /// Import Hub's drop zone.
    case none
}

extension View {

    /// Makes the view accept files dropped from other apps (on iPad) and
    /// hand them to the Import Hub, which it then opens.
    ///
    /// While files are dragged over the view it highlights and previews how
    /// many would be imported. Dropped files are copied into ZynSign's own
    /// inbox — the originals are only read — and received by the hub like
    /// files from any other entry point.
    func importDropTarget(
        _ style: ImportDropTargetStyle = .overlay,
        isTargeted: Binding<Bool>? = nil,
        incomingCount: Binding<Int>? = nil
    ) -> some View {
        modifier(ImportDropTargetModifier(style: style, externalTargeted: isTargeted, externalCount: incomingCount))
    }
}

@MainActor
private struct ImportDropTargetModifier: ViewModifier {

    let style: ImportDropTargetStyle
    let externalTargeted: Binding<Bool>?
    let externalCount: Binding<Int>?

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.importPresentation) private var importPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var incomingCount = 0

    func body(content: Content) -> some View {
        content
            .onDrop(
                of: ImportDropDelegate.acceptedTypes,
                delegate: ImportDropDelegate(
                    isTargeted: Binding(
                        get: { isTargeted },
                        set: { value in
                            isTargeted = value
                            externalTargeted?.wrappedValue = value
                        }
                    ),
                    incomingCount: Binding(
                        get: { incomingCount },
                        set: { value in
                            incomingCount = value
                            externalCount?.wrappedValue = value
                        }
                    ),
                    perform: { providers in receive(providers) }
                )
            )
            .overlay {
                if style == .overlay && isTargeted {
                    ImportDropHighlight(count: incomingCount)
                        .transition(.opacity)
                }
            }
            .scaleEffect(style == .button && isTargeted && !reduceMotion ? 1.06 : 1)
            .overlay {
                if style == .button && isTargeted {
                    RoundedRectangle(cornerRadius: ZRadius.card)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .animation(ZMotion.fast(duration: 0.2), value: isTargeted)
    }

    private func receive(_ providers: [NSItemProvider]) {
        let hub = environment.importHub
        guard let receiver = environment.droppedFiles, !providers.isEmpty else { return }
        ZHaptics.tap()
        hub.beginReceivingDrop(count: providers.count)
        importPresentation.present()
        Task { @MainActor in
            let reception = await receiver.receive(providers)
            hub.endReceivingDrop(count: providers.count)
            hub.receive(reception.urls, origin: .dragAndDrop)
            hub.recordUnreceivedDrops(reception.failedCount)
        }
    }
}

/// The drop delegate behind every import target: accepts file data, counts
/// what is being dragged, and hands the providers over on drop.
struct ImportDropDelegate: DropDelegate {

    /// Anything that is file data.
    static let acceptedTypes: [UTType] = [.data]

    @Binding var isTargeted: Bool
    @Binding var incomingCount: Int
    let perform: ([NSItemProvider]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        incomingCount = info.itemProviders(for: Self.acceptedTypes).count
        isTargeted = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: Self.acceptedTypes)
        guard !providers.isEmpty else { return false }
        perform(providers)
        return true
    }
}

/// The highlight a whole screen shows while files are dragged over it.
struct ImportDropHighlight: View {

    let count: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ZRadius.xl, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
            RoundedRectangle(cornerRadius: ZRadius.xl, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            VStack(spacing: ZSpacing.sm) {
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(Self.title(for: count))
                    .font(.title3.weight(.semibold))
                Text("ZynSign copies what it needs. Your files are not changed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(ZSpacing.xl)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous))
        }
        .padding(ZSpacing.sm)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    static func title(for count: Int) -> String {
        switch count {
        case 0, 1: return "Drop to Import"
        default: return "Drop to Import \(count) Files"
        }
    }
}

/// The Import Hub's dedicated drop zone. On iPad it is a large target that
/// lights up and previews the count; everywhere it is also a button that
/// opens the file picker, so it works without drag and drop too.
struct ImportDropZone: View {

    let receivingCount: Int
    let onChooseFiles: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isTargeted = false
    @State private var incomingCount = 0

    var body: some View {
        Button(action: onChooseFiles) {
            VStack(spacing: ZSpacing.sm) {
                Image(systemName: isTargeted ? "square.and.arrow.down.on.square.fill" : "square.and.arrow.down.on.square")
                    .font(.system(size: horizontalSizeClass == .regular ? 40 : 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, value: isTargeted)
                Text(isTargeted ? ImportDropHighlight.title(for: incomingCount) : "Choose Files…")
                    .font(.headline)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if receivingCount > 0 {
                    Label(
                        receivingCount == 1 ? "Receiving 1 dropped file…" : "Receiving \(receivingCount) dropped files…",
                        systemImage: "arrow.down.circle"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, horizontalSizeClass == .regular ? ZSpacing.xxl : ZSpacing.lg)
            .padding(.horizontal, ZSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(isTargeted ? 1 : 0.45),
                        style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [8, 5])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .importDropTarget(.none, isTargeted: $isTargeted, incomingCount: $incomingCount)
        .animation(ZMotion.fast, value: isTargeted)
        .accessibilityLabel("Choose files to import")
        .accessibilityHint("Opens the file picker. On iPad you can also drop .ipa and .zip files here.")
    }

    private var caption: String {
        horizontalSizeClass == .regular
            ? "Drop .ipa or .zip files here, or choose them from Files. Select as many as you like."
            : "Pick one or more .ipa or .zip files. You can also share or open them in ZynSign from other apps."
    }
}
