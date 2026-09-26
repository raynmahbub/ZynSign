import SwiftUI

/// What the Import menu's commands do, published by the shell for the
/// focused scene.
struct ImportCommandActions {

    /// Opens the Import Hub.
    let openHub: () -> Void

    /// Opens the Import Hub with the file picker showing.
    let chooseFiles: () -> Void

    /// Opens the Import Hub's history.
    let showHistory: () -> Void
}

private struct ImportCommandActionsKey: FocusedValueKey {
    typealias Value = ImportCommandActions
}

extension FocusedValues {

    /// The import commands of the focused scene, when it offers them.
    var importCommandActions: ImportCommandActions? {
        get { self[ImportCommandActionsKey.self] }
        set { self[ImportCommandActionsKey.self] = newValue }
    }
}

/// The Import menu: keyboard shortcuts for the Import Hub on iPad hardware
/// keyboards, listed in the system's shortcut overlay when ⌘ is held.
///
/// - ⌘I opens the Import Hub from anywhere.
/// - ⌘O opens it with the file picker showing.
/// - ⌘Y opens the import history.
///
/// Inside the hub, ⌘↩ imports the selected apps, ⌘R opens the Duplicate
/// Resolution Center, and Esc closes the hub.
struct ImportCommands: Commands {

    @FocusedValue(\.importCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Import") {
            Button("Open Import Hub") { actions?.openHub() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(actions == nil)
            Button("Choose Files to Import…") { actions?.chooseFiles() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button("Import History") { actions?.showHistory() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}
