import SwiftUI

/// The Import area of the shell: the document-import flow for `.ipa`
/// packages.
///
/// The view owns only presentation: it opens the system document picker
/// restricted to the accepted package type, forwards the outcome to the
/// model, and renders the model's phase. Everything about how a package is
/// reached, staged, and examined lives below the application boundary.
///
/// The screen states plainly what an import is and is not: ZynSign reads the
/// package's structure and declared metadata and keeps accepted packages in
/// its library; it does not install or sign them.
struct PackageImportView: View {

    @StateObject private var model: PackageImportModel
    @State private var isShowingImporter = false

    init(importing: IPAPackageImport) {
        _model = StateObject(wrappedValue: PackageImportModel(importing: importing))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle:
                    idleContent
                case .importing:
                    importingContent
                case .succeeded(let summary):
                    succeededContent(summary)
                case .failed(let message):
                    failedContent(message)
                case .cancelled:
                    cancelledContent
                }
            }
            .navigationTitle(ShellSection.importPackage.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fileImporter(
                isPresented: $isShowingImporter,
                allowedContentTypes: ImportablePackage.contentTypes
            ) { result in
                model.handlePickerResult(result)
            }
        }
    }

    // MARK: - Phases

    private var idleContent: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Import a Package", systemImage: ShellSection.importPackage.symbolName)
            } description: {
                Text("Choose an .ipa file to bring it into ZynSign. ZynSign reads the package's structure and the information its application declares, then keeps accepted packages in its library. Import does not install, sign, or modify the package.")
            } actions: {
                Button("Choose Package…") { isShowingImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var importingContent: some View {
        VStack(spacing: 16) {
            ProgressView {
                Text("Reading package…")
            }
            Button("Cancel", role: .cancel) {
                model.cancelImport()
            }
            .buttonStyle(.bordered)
        }
    }

    private func succeededContent(_ summary: PackageImportModel.Summary) -> some View {
        List {
            Section("Application") {
                LabeledContent("File", value: summary.sourceFileName ?? "—")
                LabeledContent("Name", value: summary.displayName ?? "—")
                LabeledContent("Identifier", value: summary.bundleIdentifier ?? "—")
                LabeledContent("Version", value: summary.marketingVersion ?? "—")
                LabeledContent("Build", value: summary.buildVersion ?? "—")
            }
            Section("Library") {
                Text(summary.libraryMessage)
                Text("Library records are kept across launches and are listed in the Applications area. No signing or installation is involved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Import Another Package…") { isShowingImporter = true }
            }
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Import Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Choose Another Package…") { isShowingImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var cancelledContent: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Import Cancelled", systemImage: ShellSection.importPackage.symbolName)
            } description: {
                Text("The import was cancelled. Nothing was kept.")
            } actions: {
                Button("Choose Package…") { isShowingImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

#Preview {
    PackageImportView(importing: CompositionRoot.makeApplicationEnvironment().packageImport)
}
