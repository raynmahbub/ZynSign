import Foundation

/// A node in the explorer's visual tree.
///
/// `payload` and `application` are display roots. They are not archive
/// entries. Every other node is a `BundlePath` already known to be inside
/// the bundle, so navigation cannot climb out of it.
enum ExplorerNodeID: Hashable {
    case payload
    case application
    case entry(BundlePath)

    var stableKey: String {
        switch self {
        case .payload: return "payload"
        case .application: return "application"
        case .entry(let path): return "entry:\(path.rawValue)"
        }
    }
}

/// One breadcrumb the user can tap to reveal that node.
struct ExplorerCrumb: Equatable, Identifiable {
    let id: ExplorerNodeID
    let title: String
}

/// One visible tree row. Rows exist only for expanded ancestors, and a large
/// folder contributes at most one page plus a "show more" item.
struct ExplorerTreeRow: Equatable, Identifiable {
    let id: ExplorerNodeID
    let name: String
    let depth: Int
    let classification: BundleFileClassification
    let isDirectory: Bool
    let isExpanded: Bool
    let childCount: Int?
    let declaredByteCount: Int?
    let locationText: String
    let detailText: String
    let accessibilityLabel: String
    let bundlePath: BundlePath?
    /// Framework and extension directories have an inspector distinct from
    /// merely expanding them.
    let offersBundlePage: Bool
}

/// A row the list actually renders. `showMore` is not a file.
enum ExplorerVisibleItem: Equatable, Identifiable {
    case row(ExplorerTreeRow)
    case showMore(parent: ExplorerNodeID, hiddenCount: Int)

    var id: String {
        switch self {
        case .row(let row): return "row-\(row.id.stableKey)"
        case .showMore(let parent, _): return "more-\(parent.stableKey)"
        }
    }
}

/// Contextual actions on a file. There is no editing action.
enum ExplorerQuickAction: String, CaseIterable, Identifiable {
    case viewDetails = "View Details"
    case revealInTree = "Reveal in Tree"
    case copyPath = "Copy Path"
    case copyFilename = "Copy Filename"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .viewDetails: return "info.circle"
        case .revealInTree: return "list.bullet.indent"
        case .copyPath: return "doc.on.doc"
        case .copyFilename: return "character.cursor.ibeam"
        }
    }

    /// Whether any action's name asks the explorer to change the package.
    static var exposesEditing: Bool {
        let forbidden = ["edit", "delete", "rename", "sign", "extract", "export", "move"]
        return allCases.contains { action in
            let name = action.rawValue.lowercased()
            return forbidden.contains { name.contains($0) }
        }
    }
}

/// Copy shared by the explorer screens. The package is never modified.
enum ExplorerPresentationCopy {
    static let readOnlyNote = "Previews are a bounded, read-only look at the package. ZynSign does not modify, extract, run, or resign anything from the explorer."
    static let declaredSizeNote = "Bundle size is the sum of sizes the package declares. It is not a measurement taken by reading every file."
}

/// Projects a `BundleContents` value into the rows the tree should render.
///
/// Collapsed folders contribute no children. A folder larger than `pageSize`
/// contributes one page and a show-more item, so a large bundle is not
/// rendered in full merely because its root is expanded.
enum ExplorerTreeProjection {

    static let pageSize = 200

    static func visibleItems(
        contents: BundleContents,
        expanded: Set<ExplorerNodeID>,
        windows: [ExplorerNodeID: Int]
    ) -> [ExplorerVisibleItem] {
        var items: [ExplorerVisibleItem] = []
        let payloadExpanded = expanded.contains(.payload)
        items.append(.row(payloadRow(contents: contents, expanded: payloadExpanded)))
        guard payloadExpanded else { return items }

        let applicationExpanded = expanded.contains(.application)
        items.append(.row(applicationRow(contents: contents, expanded: applicationExpanded)))
        guard applicationExpanded else { return items }

        appendChildren(
            of: .root,
            parent: .application,
            depth: 2,
            contents: contents,
            expanded: expanded,
            windows: windows,
            into: &items
        )
        return items
    }

    static func breadcrumb(for node: ExplorerNodeID?, contents: BundleContents) -> [ExplorerCrumb] {
        let payload = ExplorerCrumb(id: .payload, title: IPALayout.payloadDirectoryName)
        let application = ExplorerCrumb(id: .application, title: contents.bundleName)
        guard let node else { return [payload, application] }
        switch node {
        case .payload:
            return [payload]
        case .application:
            return [payload, application]
        case .entry(let path):
            var chain: [BundlePath] = []
            var cursor: BundlePath? = path
            while let current = cursor, !current.isRoot {
                chain.append(current)
                cursor = current.parent
            }
            return [payload, application] + chain.reversed().map {
                ExplorerCrumb(id: .entry($0), title: $0.name ?? contents.bundleName)
            }
        }
    }

    /// Expansion that makes `node` visible, without expanding `node` itself.
    static func revealedExpansion(
        of node: ExplorerNodeID,
        existing: Set<ExplorerNodeID>
    ) -> Set<ExplorerNodeID> {
        var next = existing
        next.insert(.payload)
        switch node {
        case .payload:
            break
        case .application:
            next.insert(.payload)
        case .entry(let path):
            next.insert(.application)
            var cursor = path.parent
            while let current = cursor, !current.isRoot {
                next.insert(.entry(current))
                cursor = current.parent
            }
        }
        return next
    }

    /// The parent window required for `node` to fall inside a page, if the
    /// default page would hide it.
    static func windowNeeded(
        toShow node: ExplorerNodeID,
        contents: BundleContents,
        pageSize: Int = pageSize
    ) -> (ExplorerNodeID, Int)? {
        guard case .entry(let path) = node else { return nil }
        let parentPath = path.parent ?? .root
        let parent: ExplorerNodeID = parentPath.isRoot ? .application : .entry(parentPath)
        guard let siblings = contents.entries(in: parentPath),
              let index = siblings.firstIndex(where: { $0.path == path }) else {
            return nil
        }
        let needed = index + 1
        guard needed > pageSize else { return nil }
        let pages = (needed + pageSize - 1) / pageSize
        return (parent, pages * pageSize)
    }

    static func entry(for node: ExplorerNodeID, contents: BundleContents) -> BundleEntry? {
        guard case .entry(let path) = node else { return nil }
        return contents.entry(at: path)
    }

    static func name(of node: ExplorerNodeID, contents: BundleContents) -> String {
        switch node {
        case .payload: return IPALayout.payloadDirectoryName
        case .application: return contents.bundleName
        case .entry(let path): return contents.entry(at: path)?.name ?? path.name ?? contents.bundleName
        }
    }

    static func location(of node: ExplorerNodeID, contents: BundleContents) -> String {
        switch node {
        case .payload: return ExplorerLocation.payloadPath
        case .application: return ExplorerLocation.displayPath(bundleName: contents.bundleName, entry: .root)
        case .entry(let path): return ExplorerLocation.displayPath(bundleName: contents.bundleName, entry: path)
        }
    }

    // MARK: - Rows

    private static func payloadRow(contents: BundleContents, expanded: Bool) -> ExplorerTreeRow {
        row(
            id: .payload,
            name: IPALayout.payloadDirectoryName,
            depth: 0,
            classification: .folder,
            isDirectory: true,
            isExpanded: expanded,
            childCount: 1,
            declaredByteCount: nil,
            locationText: ExplorerLocation.payloadPath,
            bundlePath: nil,
            offersBundlePage: false
        )
    }

    private static func applicationRow(contents: BundleContents, expanded: Bool) -> ExplorerTreeRow {
        row(
            id: .application,
            name: contents.bundleName,
            depth: 1,
            classification: .folder,
            isDirectory: true,
            isExpanded: expanded,
            childCount: contents.rootEntries.count,
            declaredByteCount: nil,
            locationText: ExplorerLocation.displayPath(bundleName: contents.bundleName, entry: .root),
            bundlePath: .root,
            offersBundlePage: false
        )
    }

    private static func appendChildren(
        of directory: BundlePath,
        parent: ExplorerNodeID,
        depth: Int,
        contents: BundleContents,
        expanded: Set<ExplorerNodeID>,
        windows: [ExplorerNodeID: Int],
        into items: inout [ExplorerVisibleItem]
    ) {
        let children = contents.entries(in: directory) ?? []
        let limit = max(pageSize, windows[parent] ?? pageSize)
        for entry in children.prefix(limit) {
            let id = ExplorerNodeID.entry(entry.path)
            let classification = BundleFileClassification.recognize(entry)
            let isExpanded = entry.isDirectory && expanded.contains(id)
            items.append(.row(row(
                id: id,
                name: entry.name,
                depth: depth,
                classification: classification,
                isDirectory: entry.isDirectory,
                isExpanded: isExpanded,
                childCount: entry.isDirectory ? contents.childCount(of: entry.path) : nil,
                declaredByteCount: entry.declaredByteCount,
                locationText: ExplorerLocation.displayPath(bundleName: contents.bundleName, entry: entry.path),
                bundlePath: entry.path,
                offersBundlePage: classification.hasBundlePage
            )))
            if isExpanded {
                appendChildren(
                    of: entry.path,
                    parent: id,
                    depth: depth + 1,
                    contents: contents,
                    expanded: expanded,
                    windows: windows,
                    into: &items
                )
            }
        }
        let hidden = children.count - min(children.count, limit)
        if hidden > 0 {
            items.append(.showMore(parent: parent, hiddenCount: hidden))
        }
    }

    private static func row(
        id: ExplorerNodeID,
        name: String,
        depth: Int,
        classification: BundleFileClassification,
        isDirectory: Bool,
        isExpanded: Bool,
        childCount: Int?,
        declaredByteCount: Int?,
        locationText: String,
        bundlePath: BundlePath?,
        offersBundlePage: Bool
    ) -> ExplorerTreeRow {
        let detail = detailText(
            classification: classification,
            isDirectory: isDirectory,
            childCount: childCount,
            isApplication: id == .application
        )
        var spoken = "\(name), \(classification.displayName)"
        if isDirectory, let childCount {
            spoken += ", \(itemCountText(childCount))"
        }
        if id == .application {
            spoken = "\(name), application bundle"
            if let childCount { spoken += ", \(itemCountText(childCount))" }
        }
        return ExplorerTreeRow(
            id: id,
            name: name,
            depth: depth,
            classification: classification,
            isDirectory: isDirectory,
            isExpanded: isExpanded,
            childCount: childCount,
            declaredByteCount: declaredByteCount,
            locationText: locationText,
            detailText: detail,
            accessibilityLabel: spoken,
            bundlePath: bundlePath,
            offersBundlePage: offersBundlePage
        )
    }

    private static func detailText(
        classification: BundleFileClassification,
        isDirectory: Bool,
        childCount: Int?,
        isApplication: Bool
    ) -> String {
        if isApplication {
            return childCount.map { "Application · \(itemCountText($0))" } ?? "Application"
        }
        if isDirectory {
            let count = itemCountText(childCount ?? 0)
            if classification == .folder { return count }
            return "\(classification.displayName) · \(count)"
        }
        return classification.displayName
    }

    static func itemCountText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

extension BundleFileClassification {
    /// The SF Symbol for a tree row. Colour is not the only signal.
    var symbolName: String {
        switch self {
        case .metadata: return "list.bullet.rectangle"
        case .provisioningProfile: return "checkmark.seal"
        case .executable: return "cpu"
        case .framework: return "shippingbox"
        case .appExtension: return "puzzlepiece.extension"
        case .image: return "photo"
        case .text: return "doc.text"
        case .propertyList: return "list.bullet.rectangle"
        case .localization: return "globe"
        case .assetCatalog: return "square.stack.3d.down.right"
        case .folder: return "folder.fill"
        case .symbolicLink: return "link"
        case .unsupported: return "questionmark.square.dashed"
        case .generic: return "doc"
        }
    }
}
