// Danger Swift — ZynSign's senior reviewer on every pull request.
//
// Runs from the 🔨 Build workflow, 01-build.yml (docker/brew danger-swift), and leaves
// review comments automatically. Nothing here blocks a merge — Danger is
// the reviewer who always shows up; the blocking gates are the CI checks.

import Danger
import Foundation

let danger = Danger()
let git = danger.git
let github = danger.github

let modified = git.modifiedFiles
let created = git.createdFiles
let changed = Set(modified + created)

// --- Pull request hygiene --------------------------------------------------

let pr = github.thisPR
let body = pr.body ?? ""
if body.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 {
    warn("This PR has little or no description. Explain what changed and why — future maintainers read this.")
}

let conventionalTitle = pr.title.range(
    of: #"^(feat|fix|refactor|perf|docs|ci|test|build|chore|style)(\([^)]+\))?!?: .+"#,
    options: .regularExpression
)
if conventionalTitle == nil {
    warn("PR title is not a Conventional Commit (e.g. `feat(signing): …`). Release notes are generated from these titles.")
}

// --- Test coverage ------------------------------------------------------------

let appChanges = changed.filter { $0.hasPrefix("ZynSign/") }
let testChanges = changed.filter { $0.hasPrefix("Tests/") }
if !appChanges.isEmpty && testChanges.isEmpty {
    warn("Tests are missing — application code changed but no test file did. If no test applies, say so in the PR description.")
}

// --- Documentation -------------------------------------------------------------

let docsChanges = changed.filter { $0.hasPrefix("docs/") || $0.hasSuffix(".md") }
if !appChanges.isEmpty && !changed.contains("CHANGELOG.md") {
    warn("CHANGELOG.md was not updated. Add an entry under `[Unreleased]` for user-visible changes.")
}
if !changed.isEmpty && docsChanges.count == changed.count {
    message("Documentation-only change — thank you for keeping the docs healthy.")
}

// --- Architecture sensitivity ---------------------------------------------------

let architectureSensitive = changed.filter {
    $0.hasPrefix("ZynSign/Domain/")
        || $0.hasPrefix("ZynSign/App/")
        || $0.hasPrefix("docs/architecture/")
        || $0.hasPrefix("Scripts/ci/architecture")
        || $0.contains("Keychain")
        || $0.contains("SecureIdentity")
        || $0 == "ZynSign.xcodeproj/project.pbxproj"
}
if !architectureSensitive.isEmpty {
    message("Architecture-sensitive files changed (\(architectureSensitive.sorted().joined(separator: ", "))) — the Architecture Guard runs automatically; a senior review is recommended.")
}

// --- File size -------------------------------------------------------------------

for file in changed.sorted() where file.hasSuffix(".swift") {
    if let contents = danger.utils.readFile(file) {
        let lineCount = contents.components(separatedBy: .newlines).count
        if lineCount > 800 {
            warn("`\(file)` is \(lineCount) lines — the recommended limit is 800. Consider splitting when touching it.")
        }
    }
}

// --- Release notes category hint ---------------------------------------------------

let labels = github.issue.labels.map { $0.name }
if labels.isEmpty && !appChanges.isEmpty {
    message("No labels yet — `feature`, `enhancement`, `bug`, `performance`, `ui`, `refactor`, `security`, `docs`, `ci` drive the Release Drafter categories.")
}
