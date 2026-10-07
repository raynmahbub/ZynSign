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
    /// hand them to the flow that owns them: packages and anything else to
    /// the Import Hub, which then opens, and signing material — a `.p12`
    /// identity or a `.mobileprovision` profile — to Certificates &
    /// Profiles through the shell.
    ///
    /// While files are dragged over the view it highlights and previews how
    /// many would be imported. Dropped files are copied into ZynSign's own
    /// inbox — the originals are only read — and received by each flow like
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
    @Environment(\.signingMaterialsPresentation) private var signingMaterialsPresentation
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
            .animation(ZMotion.fast, value: isTargeted)
    }

    private func receive(_ providers: [NSItemProvider]) {
        let hub = environment.importHub
        guard !providers.isEmpty else { return }
        ZHaptics.tap()
        guard let receiver = environment.droppedFiles else {
            // A drop has to be answered whatever the build can do with it.
            // Without a receiver ZynSign cannot hold the file past the moment
            // of the drop, so the hub lists the items as unreceived and says
            // so — rather than the gesture lighting up and doing nothing.
            hub.recordUnreceivedDrops(providers.count)
            importPresentation.present()
            return
        }
        hub.beginReceivingDrop(count: providers.count)
        // When every provider names signing material, the drop belongs to
        // Certificates & Profiles and the hub must not rise first — an empty
        // Import Hub over a certificate drop would have to be dismissed
        // before the sheet it waits behind could appear. Any other drop asks
        // for the hub immediately, so a large package shows "Receiving…"
        // while its inbox copy is still being written.
        if !Self.isSigningMaterialDrop(providers) {
            importPresentation.present()
        }
        Task { @MainActor in
            let reception = await receiver.receive(providers)
            hub.endReceivingDrop(count: providers.count)
            route(reception)
        }
    }

    /// Hands each received file to the flow that owns its kind.
    ///
    /// Packages and anything the policy does not name stay the Import Hub's
    /// business exactly as before. Signing material — decided by
    /// `SigningMaterialFileFormat`, the same policy Open In routes with —
    /// goes to Certificates & Profiles: the first identity and the first
    /// profile of a drop open their own import flows, and a second file of
    /// the same kind falls back to the hub, whose refusal says where
    /// certificates are added. Where no shell installed a signing-material
    /// presentation (a preview, a test), every file stays the hub's, so a
    /// drop is always answered rather than dropped in silence.
    private func route(_ reception: DroppedFileReception) {
        let hub = environment.importHub
        var identity: URL?
        var profile: URL?
        var hubBound: [URL] = []
        for url in reception.urls {
            guard signingMaterialsPresentation.isAvailable,
                  let kind = SigningMaterialFileFormat.kind(for: url) else {
                hubBound.append(url)
                continue
            }
            switch kind {
            case .identity where identity == nil:
                identity = url
            case .profile where profile == nil:
                profile = url
            default:
                hubBound.append(url)
            }
        }
        if !hubBound.isEmpty || reception.failedCount > 0 {
            importPresentation.present()
            hub.receive(hubBound, origin: .dragAndDrop)
            hub.recordUnreceivedDrops(reception.failedCount)
        }
        if let identity {
            signingMaterialsPresentation.importIdentity(identity)
        }
        if let profile {
            signingMaterialsPresentation.importProfile(profile)
        }
    }

    /// Whether every provider in the drop names signing-material types —
    /// the common shape of a `.p12` or `.mobileprovision` dragged straight
    /// from Files. The identifiers mirror ZynSign's own type declarations
    /// in `Info.plist`; a provider that names nothing but `public.file-url`
    /// simply fails the check, and the drop opens the hub as it always did.
    private static func isSigningMaterialDrop(_ providers: [NSItemProvider]) -> Bool {
        let materialIdentifiers = signingMaterialTypeIdentifiers
        return providers.allSatisfy { provider in
            provider.registeredTypeIdentifiers.contains { materialIdentifiers.contains($0) }
        }
    }

    private static let signingMaterialTypeIdentifiers: Set<String> = {
        var identifiers = Set(
            SigningMaterialFileFormat.acceptedPathExtensions.compactMap { ext in
                UTType(filenameExtension: ext)?.identifier
            }
        )
        identifiers.insert("com.rsa.pkcs-12")
        identifiers.insert("com.microsoft.pkcs12")
        identifiers.insert("com.apple.mobileprovision")
        return identifiers
    }()
}

/// The drop delegate behind every import target: accepts file data, counts
/// what is being dragged, and hands the providers over on drop.
struct ImportDropDelegate: DropDelegate {

    /// Anything the drop can carry as a file.
    ///
    /// The set is deliberately wider than `public.data`. What a drag registers
    /// depends on the app it came from — a file out of Files may offer a
    /// reference and the file's own type, and a provider from another app names
    /// neither the way the picker does — and a drag this target declines is
    /// dropped by the system *without a word*, the one outcome no part of ZynSign
    /// can recover from. Anything that lands is then read by the receiver's own
    /// rules, and the hub still refuses what is not a package, with a reason.
    static let acceptedTypes: [UTType] = [.data, .fileURL, .archive, .zip]

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
        .accessibilityHint("Opens the file picker. On iPad you can also drop .ipa, .tipa, and .zip files here.")
    }

    private var caption: String {
        horizontalSizeClass == .regular
            ? "Drop .ipa, .tipa, or .zip files here, or choose them from Files. Select as many as you like."
            : "Pick one or more .ipa or .tipa files. You can also share or open them in ZynSign from other apps."
    }
}
