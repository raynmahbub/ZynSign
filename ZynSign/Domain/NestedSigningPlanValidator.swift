import Foundation

/// Validates a nested code signing plan before any mutation occurs.
///
/// The nested signing layer does not blindly trust caller-provided plans or
/// execution ordering. Every constraint must be checked beforehand:
///
/// 1. Every signing item has a valid bundle-relative path that does not escape
///    the application bundle (`isWithin(.root)`).
/// 2. Every executable path sits strictly inside its containing item's bundle path.
/// 3. No duplicate signing target exists (by item ID or executable path).
/// 4. No item appears twice in the signing order.
/// 5. The root application is not accidentally treated as a nested signing target.
/// 6. All required dependencies are represented and refer to known items.
/// 7. Dependency ordering is strictly valid: every nested child must precede its container.
/// 8. No dependency cycles exist.
/// 9. Parent/child relationships are internally consistent.
/// 10. Each nested target is established Mach-O code; unsupported formats (fat containers,
///     non-arm64 slices) and unestablished items are rejected explicitly.
/// 11. Unsupported code types or items in the plan are rejected before mutation.
enum NestedSigningPlanValidator {

    /// Validates a `NestedCodeSigningPlan` produced by discovery and constructs
    /// a validated `NestedSigningPlan` ready for sequential nested signing.
    ///
    /// The parent application executable is recorded as root context on the validated
    /// plan, but is strictly omitted from the nested signing items.
    static func validate(plan: NestedCodeSigningPlan) throws -> NestedSigningPlan {
        // 1. Refuse plans that carry unsupported items.
        if let unsupported = plan.unsupportedItems.first {
            throw NestedSigningFailure(
                reason: .unsupportedCodeType,
                itemID: nil,
                path: unsupported.path,
                detail: "Plan contains an unsupported item at '\(unsupported.path.rawValue)': \(unsupported.reason.displayName).",
                category: .unsupportedInput,
                mutationOccurred: false
            )
        }

        // 2. Validate root application item.
        let root = plan.root
        guard root.kind == .application else {
            throw NestedSigningFailure(
                reason: .invalidSigningPlan,
                itemID: root.id,
                path: root.bundlePath,
                detail: "Plan root item must have kind .application.",
                category: .invalidInput,
                mutationOccurred: false
            )
        }
        guard root.bundlePath == .root else {
            throw NestedSigningFailure(
                reason: .invalidSigningPlan,
                itemID: root.id,
                path: root.bundlePath,
                detail: "Root application bundle path must be .root.",
                category: .invalidInput,
                mutationOccurred: false
            )
        }
        if let rootExec = root.executablePath {
            guard rootExec.isWithin(.root) else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: root.id,
                    path: rootExec,
                    detail: "Root executable path escapes the bundle root.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
        }

        // 3. Validate nested items.
        var seenItemIDs: Set<NestedCodeItemID> = []
        var seenExecutablePaths: [BundlePath: NestedCodeItemID] = [:]

        for item in plan.nestedItems {
            // Nested items cannot be the root application.
            guard item.kind != .application, item.id != root.id else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: item.id,
                    path: item.bundlePath,
                    detail: "The main application executable cannot be treated as a nested item.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }

            // Path safety: bundlePath must be inside .root.
            guard item.bundlePath.isWithin(.root) else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: item.id,
                    path: item.bundlePath,
                    detail: "Item bundle path '\(item.bundlePath.rawValue)' escapes the application bundle.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }

            // Executable path must be established and within item.bundlePath.
            guard let execPath = item.executablePath else {
                throw NestedSigningFailure(
                    reason: .unsupportedCodeType,
                    itemID: item.id,
                    path: item.bundlePath,
                    detail: "Item '\(item.id)' has no established executable path.",
                    category: .unsupportedInput,
                    mutationOccurred: false
                )
            }
            guard execPath.isWithin(item.bundlePath) else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: item.id,
                    path: execPath,
                    detail: "Executable at '\(execPath.rawValue)' is not inside its container '\(item.bundlePath.rawValue)'.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }

            // Duplicate target checks.
            guard seenItemIDs.insert(item.id).inserted else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: item.id,
                    path: item.bundlePath,
                    detail: "Duplicate signing target '\(item.id)'.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
            if let existingID = seenExecutablePaths[execPath] {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: item.id,
                    path: execPath,
                    detail: "Items '\(existingID)' and '\(item.id)' share the same executable path '\(execPath.rawValue)'.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
            seenExecutablePaths[execPath] = item.id

            // Supported code kind check.
            switch item.kind {
            case .framework, .dynamicLibrary, .applicationExtension:
                break
            case .application:
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: item.id,
                    path: item.bundlePath,
                    detail: "Unexpected nested application bundle at '\(item.bundlePath.rawValue)'.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }

            // Item status must be established.
            guard item.status.isEstablished else {
                throw NestedSigningFailure(
                    reason: .unsupportedCodeType,
                    itemID: item.id,
                    path: item.bundlePath,
                    detail: "Item '\(item.id)' is not established as signable code.",
                    category: .unsupportedInput,
                    mutationOccurred: false
                )
            }

            // Binary inspection checks.
            switch item.binary {
            case .machO(let summary):
                if let summary {
                    if summary.isUniversal {
                        throw NestedSigningFailure(
                            reason: .unsupportedFormat,
                            itemID: item.id,
                            path: execPath,
                            detail: "Universal (fat) Mach-O containers are unsupported.",
                            category: .unsupportedInput,
                            mutationOccurred: false
                        )
                    }
                    if let firstSlice = summary.slices.first, firstSlice.cpu != .arm64 {
                        throw NestedSigningFailure(
                            reason: .unsupportedFormat,
                            itemID: item.id,
                            path: execPath,
                            detail: "Non-arm64 architecture is unsupported.",
                            category: .unsupportedInput,
                            mutationOccurred: false
                        )
                    }
                }
            case .notMachO:
                throw NestedSigningFailure(
                    reason: .unsupportedCodeType,
                    itemID: item.id,
                    path: execPath,
                    detail: "Target at '\(execPath.rawValue)' is not a Mach-O binary.",
                    category: .unsupportedInput,
                    mutationOccurred: false
                )
            case .malformed(let error):
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: item.id,
                    path: execPath,
                    detail: "Mach-O binary at '\(execPath.rawValue)' is malformed: \(error.reason).",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            case .unsupported(let error):
                throw NestedSigningFailure(
                    reason: .unsupportedFormat,
                    itemID: item.id,
                    path: execPath,
                    detail: "Mach-O binary at '\(execPath.rawValue)' uses an unsupported form: \(error.reason).",
                    category: .unsupportedInput,
                    mutationOccurred: false
                )
            case .beyondInspectionBound, .unreadable, .notRequested:
                throw NestedSigningFailure(
                    reason: .unsupportedCodeType,
                    itemID: item.id,
                    path: execPath,
                    detail: "Target at '\(execPath.rawValue)' could not be inspected as Mach-O code.",
                    category: .unsupportedInput,
                    mutationOccurred: false
                )
            }

            // Parent/child consistency.
            if let parentID = item.parentID {
                if parentID != root.id {
                    guard let parentItem = plan.nestedItems.first(where: { $0.id == parentID }) else {
                        throw NestedSigningFailure(
                            reason: .invalidSigningPlan,
                            itemID: item.id,
                            path: item.bundlePath,
                            detail: "Item '\(item.id)' refers to missing parent '\(parentID)'.",
                            category: .invalidInput,
                            mutationOccurred: false
                        )
                    }
                    guard item.bundlePath.isWithin(parentItem.bundlePath) else {
                        throw NestedSigningFailure(
                            reason: .invalidSigningPlan,
                            itemID: item.id,
                            path: item.bundlePath,
                            detail: "Item '\(item.id)' is not inside its parent container '\(parentItem.bundlePath.rawValue)'.",
                            category: .invalidInput,
                            mutationOccurred: false
                        )
                    }
                }
            }
        }

        // 4. Validate signing steps and ordering.
        let allKnownIDs = Set([root.id] + plan.nestedItems.map(\.id))
        var stepItemIDs: Set<NestedCodeItemID> = []

        for (index, step) in plan.steps.enumerated() {
            guard step.order == index + 1 else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: step.itemID,
                    detail: "Signing steps must have 1-based contiguous order (expected \(index + 1), got \(step.order)).",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
            guard allKnownIDs.contains(step.itemID) else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: step.itemID,
                    detail: "Step \(step.order) refers to an unknown item '\(step.itemID)'.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
            guard stepItemIDs.insert(step.itemID).inserted else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: step.itemID,
                    detail: "Item '\(step.itemID)' appears more than once in the signing steps.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
        }

        // The application bundle must be the last step when steps are present.
        if !plan.steps.isEmpty {
            guard let lastStep = plan.steps.last, lastStep.itemID == root.id else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: root.id,
                    detail: "The application bundle must be the final step in the signing plan.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
        }

        // The root application must not appear in any position except the last.
        if plan.steps.count > 1 {
            let interiorSteps = plan.steps.dropLast()
            if interiorSteps.contains(where: { $0.itemID == root.id }) {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: root.id,
                    detail: "The main application executable cannot appear as an ordinary nested signing step.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
        }

        // 5. Validate dependencies and ordering constraints.
        let stepOrderByID = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.itemID, $0.order) })

        for dependency in plan.dependencies {
            guard allKnownIDs.contains(dependency.nestedCode) else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: dependency.nestedCode,
                    detail: "Dependency endpoint '\(dependency.nestedCode)' is unknown.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
            guard allKnownIDs.contains(dependency.container) else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: dependency.container,
                    detail: "Dependency endpoint '\(dependency.container)' is unknown.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
            guard dependency.nestedCode != dependency.container else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: dependency.nestedCode,
                    detail: "Self-dependency detected for item '\(dependency.nestedCode)'.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }

            // Ordering constraint: nestedCode must be signed before container.
            if let childOrder = stepOrderByID[dependency.nestedCode],
               let parentOrder = stepOrderByID[dependency.container] {
                guard childOrder < parentOrder else {
                    throw NestedSigningFailure(
                        reason: .invalidSigningPlan,
                        itemID: dependency.nestedCode,
                        detail: "Dependency ordering violation: nested code '\(dependency.nestedCode)' (step \(childOrder)) is ordered after its container '\(dependency.container)' (step \(parentOrder)).",
                        category: .invalidInput,
                        mutationOccurred: false
                    )
                }
            }
        }

        // 6. Build validated NestedSigningItem list in step order.
        // Nested items only; the root application is left for the later complete pipeline.
        let nestedSteps = plan.steps.filter { $0.itemID != root.id }
        let itemsByID = Dictionary(uniqueKeysWithValues: plan.nestedItems.map { ($0.id, $0) })

        var validatedItems: [NestedSigningItem] = []
        validatedItems.reserveCapacity(nestedSteps.count)

        for (index, step) in nestedSteps.enumerated() {
            guard let item = itemsByID[step.itemID],
                  let execPath = item.executablePath else {
                throw NestedSigningFailure(
                    reason: .invalidSigningPlan,
                    itemID: step.itemID,
                    detail: "Nested item '\(step.itemID)' missing from established items.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }

            validatedItems.append(NestedSigningItem(
                id: item.id,
                kind: item.kind,
                bundlePath: item.bundlePath,
                executablePath: execPath,
                parentID: item.parentID,
                bundleIdentifier: item.identity?.bundleIdentifier,
                initialSignatureState: item.existingSignature,
                order: index + 1
            ))
        }

        return NestedSigningPlan(
            rootItemID: root.id,
            rootExecutablePath: root.executablePath,
            items: validatedItems,
            dependencies: plan.dependencies
        )
    }
}
