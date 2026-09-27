import Foundation

// MARK: - Benchmarks

/// The numbers ZynSign holds itself to.
///
/// These are internal policy, chosen to be generous enough that an ordinary
/// device passes comfortably and tight enough that a regression is visible.
/// They are not Apple's numbers, not a measurement of any particular device,
/// and not a promise to a user: they are the thresholds the Lab compares its
/// own measurements against, so a change in performance is a change someone
/// has to explain.
///
/// A measurement on a simulator is compared against the same thresholds but
/// is never presented as a device result — see the note on each report.
enum PerformanceBenchmark {

    /// Time from the first data access to a populated library list: reading
    /// the preferences document and the library catalog.
    static let firstDataReadMilliseconds = 1_500

    /// One search keystroke's worth of work, averaged over a run of queries
    /// against the live library index.
    static let searchMilliseconds = 120

    /// Preparing one ordinary package: container write, structure, metadata,
    /// nested discovery, plan validation.
    static let importPreparationMilliseconds = 600

    /// Preparing a package with nested code, which is the expensive shape.
    static let signingPreparationMilliseconds = 1_500

    /// Preparing a package at ordinary large-application size.
    static let largeImportMilliseconds = 4_000

    /// The resident memory ZynSign should stay under in ordinary use.
    static let residentMemoryCeilingBytes = 384 * 1_024 * 1_024

    /// How much a bounded spike may still be holding once it has been
    /// released. Anything above this is a cache that did not let go.
    static let memorySpikeToleranceBytes = 64 * 1_024 * 1_024

    /// The temporary footprint that earns a look: working copies that keep
    /// growing are the usual cause.
    static let temporaryFootprintWarningBytes = 512 * 1_024 * 1_024

    /// The least memory a device should have for a signing run.
    static let minimumPhysicalMemoryGigabytes = 2.0

    /// The latency under which a repository counts as fast. The value in
    /// `RepositoryHealthProbe`; repeated here so the Lab can compare a
    /// measured probe against the policy it is judged by.
    static let repositoryHealthFastMilliseconds = 800
}

// MARK: - Formatting

/// Byte counts as a reader can compare them.
enum ByteCountFormatting {

    /// Renders a byte count with a binary unit: `12.4 MB`.
    static func rendered(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
    }

    /// Renders an optional byte count, naming the unknown case.
    static func rendered(_ bytes: Int?) -> String {
        guard let bytes else { return "unknown" }
        return rendered(bytes)
    }

    /// Renders an optional unsigned count, naming the unknown case.
    static func rendered(_ bytes: UInt64?) -> String {
        guard let bytes else { return "unknown" }
        return rendered(Int(clamping: bytes))
    }
}

// MARK: - Suite

/// Performance verification: the measurements the RC claims, taken here.
///
/// The suite measures what can be measured honestly inside the app and says
/// so about what cannot. Frame rate during scrolling is not something a
/// process can measure about itself — that needs Instruments or an XCTest
/// metric — so the row exists, is reported as not run, and names the check
/// that settles it. A performance claim nobody can reproduce is worse than
/// no claim, and the report is built so an imported measurement can fill
/// that row without pretending the Lab took it.
struct PerformanceSuite {

    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        var results: [CompatibilityCheck] = []
        results.append(await firstDataReadCheck(context: context))
        results.append(await searchCheck(context: context))
        results.append(importPreparationCheck(context: context))
        results.append(signingPreparationCheck(context: context))
        results.append(scrollingCheck())
        results.append(memoryCheck())
        return results
    }

    // MARK: Cases

    /// Reading the preferences and the library is the work a cold launch
    /// does before the first list appears. It is measurable from inside, and
    /// it is the part ZynSign controls.
    private func firstDataReadCheck(context: CompatibilityLabContext) async -> CompatibilityCheck {
        guard let environment = context.environment else {
            return notRun(
                id: "performance.firstDataRead",
                title: "First data read",
                reason: "No application environment was composed for this run."
            )
        }
        let started = context.now()
        _ = environment.preferencesStore.snapshot
        let entries = (try? await environment.library.entries()) ?? []
        let elapsed = Int(context.now().timeIntervalSince(started) * 1_000)
        let passed = elapsed <= PerformanceBenchmark.firstDataReadMilliseconds
        return check(
            id: "performance.firstDataRead",
            title: "First data read",
            status: passed ? .passed : .warning,
            summary: "Preferences and \(entries.count) library record(s) read in \(elapsed) ms.",
            verified: "Verified the data reads a launch performs, measured in-process. Not verified: total launch time, which starts before ZynSign's code runs and is measured with Instruments or an XCTest launch metric.",
            nextStep: passed ? nil : "A growing catalog or a preference migration is the usual cause; re-measure on a device before changing anything.",
            measurements: [
                CompatibilityMeasurement(
                    name: "first data read",
                    value: Double(elapsed),
                    unit: "ms",
                    threshold: Double(PerformanceBenchmark.firstDataReadMilliseconds),
                    comparison: .lowerIsBetter
                ),
                CompatibilityMeasurement(
                    name: "library records",
                    value: Double(entries.count),
                    unit: "count",
                    comparison: .informational
                )
            ],
            durationMilliseconds: elapsed
        )
    }

    /// Search, measured against the real library index over the real
    /// library. With nothing imported there is nothing to search, and the
    /// honest answer is that the check did not run.
    private func searchCheck(context: CompatibilityLabContext) async -> CompatibilityCheck {
        guard let environment = context.environment else {
            return notRun(
                id: "performance.search",
                title: "Search latency",
                reason: "No application environment was composed for this run."
            )
        }
        let entries: [LibraryEntry]
        do {
            entries = try await environment.library.entries()
        } catch {
            return check(
                id: "performance.search",
                title: "Search latency",
                status: .failed,
                summary: "The library could not be read, so search could not be measured.",
                verified: "Nothing was measured.",
                nextStep: "Check the library catalog is readable (Settings → Recovery → Rebuild library index).",
                evidence: ["error: \((error as? ZynSignError)?.userMessage ?? String(describing: type(of: error)))"]
            )
        }
        guard !entries.isEmpty else {
            return check(
                id: "performance.search",
                title: "Search latency",
                status: .notRun,
                summary: "Nothing is imported, so there is nothing to search.",
                verified: "Nothing was measured: an empty library makes a search-timing figure meaningless.",
                nextStep: "Import a few applications, then run the Lab again.",
                evidence: ["library records: 0"]
            )
        }
        let index = LibraryIndex(entries: entries)
        let terms = Self.searchTerms
        let started = context.now()
        var matchCount = 0
        for term in terms {
            let query = LibraryQuery(searchText: term, sort: .name)
            matchCount += index.results(for: query, in: .all, now: context.now()).count
        }
        let total = Int(context.now().timeIntervalSince(started) * 1_000)
        let average = Double(total) / Double(max(1, terms.count))
        let passed = average <= Double(PerformanceBenchmark.searchMilliseconds)
        return check(
            id: "performance.search",
            title: "Search latency",
            status: passed ? .passed : .warning,
            summary: "\(terms.count) queries over \(entries.count) record(s) averaged \(Self.rendered(average)) ms each.",
            verified: "Verified the real library index answering real queries over the real library, in-process. Not verified: the typing-to-render path, which is a UI concern measured with Instruments.",
            nextStep: passed ? nil : "Re-measure on a device; if it holds, the index is rebuilding more than it should when a term changes.",
            evidence: ["terms: \(terms.count)", "matches: \(matchCount)"],
            measurements: [
                CompatibilityMeasurement(
                    name: "search latency",
                    value: average,
                    unit: "ms",
                    threshold: Double(PerformanceBenchmark.searchMilliseconds),
                    comparison: .lowerIsBetter
                )
            ],
            durationMilliseconds: total
        )
    }

    /// Preparing an ordinary package.
    private func importPreparationCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        return preparationCheck(
            id: "performance.import",
            title: "Import speed",
            scenario: .simpleApplication,
            thresholdMilliseconds: PerformanceBenchmark.importPreparationMilliseconds,
            claim: "Preparing one ordinary package",
            context: context
        )
    }

    /// Preparing the expensive shape: nested code that must be discovered
    /// and ordered before anything is signed.
    private func signingPreparationCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        return preparationCheck(
            id: "performance.signingPreparation",
            title: "Signing preparation",
            scenario: .applicationWithFrameworks,
            thresholdMilliseconds: PerformanceBenchmark.signingPreparationMilliseconds,
            claim: "Preparing a package with frameworks",
            context: context
        )
    }

    private func preparationCheck(
        id: String,
        title: String,
        scenario: SigningScenarioIdentifier,
        thresholdMilliseconds: Int,
        claim: String,
        context: CompatibilityLabContext
    ) -> CompatibilityCheck {
        let lab = SigningScenarioLab()
        let started = context.now()
        do {
            let outcome = try lab.run(scenario, context: context)
            let elapsed = Int(context.now().timeIntervalSince(started) * 1_000)
            let passed = elapsed <= thresholdMilliseconds
            return check(
                id: id,
                title: title,
                status: passed ? .passed : .warning,
                summary: "\(claim) took \(elapsed) ms.",
                verified: "Verified the preparation stages — build, read, structure, metadata, discovery, plan validation — measured in-process on this device.",
                nextStep: passed ? nil : "Re-measure on a device with a cool thermal state before treating this as a regression.",
                evidence: ["entries: \(outcome.entryCount)"],
                measurements: [
                    CompatibilityMeasurement(
                        name: "preparation",
                        value: Double(elapsed),
                        unit: "ms",
                        threshold: Double(thresholdMilliseconds),
                        comparison: .lowerIsBetter
                    )
                ],
                durationMilliseconds: elapsed
            )
        } catch {
            return check(
                id: id,
                title: title,
                status: .failed,
                summary: "\(claim) could not be measured: the run failed.",
                verified: "Nothing was measured.",
                nextStep: "Read the error, then re-run the Lab.",
                evidence: ["error: \((error as? ZynSignError)?.userMessage ?? String(describing: type(of: error)))"]
            )
        }
    }

    /// Scrolling. The row exists because a release decision should see it,
    /// and it stays not run because a process cannot measure its own frame
    /// rate honestly.
    private func scrollingCheck() -> CompatibilityCheck {
        CompatibilityCheck(
            id: "performance.scrolling",
            title: "Scrolling",
            status: .notRun,
            summary: "Frame rate is not measured in-process; it needs Instruments or an XCTest metric.",
            verified: "Nothing was measured. A frame rate ZynSign reported about itself would be a number nobody could reproduce.",
            nextStep: "Run the scrolling protocol in docs/hardening/performance-verification.md (Instruments → Core Animation, or an XCTest os_signpost metric) and import the result through a Lab overlay.",
            evidence: [
                "protocol: 60 fps sustained on the Library grid and list with 50+ applications, at the default and the largest Dynamic Type size"
            ],
            blocker: .medium
        )
    }

    /// Resident memory right now, against the ceiling ZynSign keeps.
    private func memoryCheck() -> CompatibilityCheck {
        let resident = ProcessMemoryFootprint.residentBytes()
        guard let resident else {
            return check(
                id: "performance.memory",
                title: "Memory usage",
                status: .notRun,
                summary: "The platform did not report this process's resident memory.",
                verified: "Nothing was measured.",
                nextStep: "Run the Lab on a device: a simulator's memory accounting is not the device's."
            )
        }
        let passed = Int(clamping: resident) <= PerformanceBenchmark.residentMemoryCeilingBytes
        return check(
            id: "performance.memory",
            title: "Memory usage",
            status: passed ? .passed : .warning,
            summary: "Resident memory at the time of the run: \(ByteCountFormatting.rendered(resident)).",
            verified: "Verified the process's own resident set, as the kernel reports it. Not verified: peak memory during a signing run, which is measured with Instruments.",
            nextStep: passed ? nil : "Take a Memory Graph or an Instruments allocation trace during a signing run before changing anything.",
            measurements: [
                CompatibilityMeasurement(
                    name: "resident memory",
                    value: Double(resident),
                    unit: "bytes",
                    threshold: Double(PerformanceBenchmark.residentMemoryCeilingBytes),
                    comparison: .lowerIsBetter
                )
            ]
        )
    }

    // MARK: Support

    /// The search terms the measurement runs, chosen to exercise a match, a
    /// miss, and a term that scans every field.
    private static let searchTerms = ["a", "z", "app", "com", "1", "zynsign", "e"]

    private static func rendered(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func notRun(id: String, title: String, reason: String) -> CompatibilityCheck {
        check(
            id: id,
            title: title,
            status: .notRun,
            summary: reason,
            verified: "Nothing was measured.",
            nextStep: "Run the Lab from the application, where the environment is composed."
        )
    }

    private func check(
        id: String,
        title: String,
        status: CompatibilityStatus,
        summary: String,
        verified: String,
        nextStep: String? = nil,
        evidence: [String] = [],
        measurements: [CompatibilityMeasurement] = [],
        durationMilliseconds: Int = 0
    ) -> CompatibilityCheck {
        CompatibilityCheck(
            id: id,
            category: .performance,
            title: title,
            status: status,
            summary: summary,
            verified: verified,
            nextStep: nextStep,
            evidence: evidence,
            measurements: measurements,
            durationMilliseconds: durationMilliseconds,
            blocker: status == .failed ? .medium : nil
        )
    }
}
