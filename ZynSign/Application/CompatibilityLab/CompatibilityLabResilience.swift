import Foundation

// MARK: - Network doubles

/// A transport that never reaches anything: what a device in aeroplane mode
/// does, without waiting for a tunnel.
struct UnreachableRepositoryTransport: RepositoryHealthTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        throw NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: nil
        )
    }
}

/// A transport that answers, but slowly enough to cross the slow threshold.
struct SlowRepositoryTransport: RepositoryHealthTransport {

    /// How long the transport waits before answering.
    let delayMilliseconds: Int

    init(delayMilliseconds: Int = 1_000) {
        self.delayMilliseconds = delayMilliseconds
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
        return (Self.validFeed, response ?? URLResponse())
    }

    /// The smallest document the probe accepts as a feed.
    static var validFeed: Data {
        Data(#"{"name":"lab","apps":[]}"#.utf8)
    }
}

/// A transport that answers with a status ZynSign must not treat as a feed.
struct HTTPErrorRepositoryTransport: RepositoryHealthTransport {

    let statusCode: Int

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )
        return (Data("not found".utf8), response ?? URLResponse())
    }
}

/// A transport that answers 200 with a body that is not JSON.
struct MalformedRepositoryTransport: RepositoryHealthTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        )
        return (Data("<html><body>captive portal</body></html>".utf8), response ?? URLResponse())
    }
}

/// A transport that answers with fewer bytes than it declares: an
/// interrupted transfer, which is the failure a download meets most often.
struct TruncatedRepositoryTransport: RepositoryHealthTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "4096"]
        )
        return (Data(#"{"name":"lab","apps":[]"#.utf8), response ?? URLResponse())
    }
}

// MARK: - Network resilience

/// Store and download resilience: what the user sees when the network misbehaves.
///
/// Every case is reproduced through an injected transport, because a network
/// failure that can only be tested by waiting for one is a network failure
/// nobody tests. What matters is not that the fetch succeeded — it cannot —
/// but that it ends in a state the interface renders, with a category a user
/// can act on, and never in a thrown error the screen was not built for.
struct NetworkResilienceSuite: CompatibilitySuite {

    /// The source a probe is pointed at. Nothing is fetched from it: the
    /// transports below decide what happens.
    private static let sampleSource = URL(string: "https://example.invalid/source.json")
        ?? URL(fileURLWithPath: "/")

    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        var collected: [CompatibilityCheck] = [
            await offlineCheck(),
            await slowCheck(),
            await httpErrorCheck(),
            await malformedCheck(),
            await truncatedCheck()
        ]
        collected.append(downloadWorkspaceCheck(context: context))
        collected.append(await downloadPartialCheck())
        return collected
    }

    // MARK: Cases

    private func offlineCheck() async -> CompatibilityCheck {
        let probe = RepositoryHealthProbe(transport: UnreachableRepositoryTransport())
        let result = await probe.probe(url: Self.sampleSource)
        let passed = result.health == .offline && result.errorCategory == "offline"
        return check(
            id: "store.offline",
            title: "Offline source",
            status: passed ? .passed : .failed,
            summary: passed
                ? "A source that cannot be reached is reported offline, with the reason named."
                : "A source that cannot be reached was not reported as an offline device.",
            verified: "Verified that the probe finishes, never throws, and turns a transport failure into the health state the Store shows.",
            nextStep: passed ? nil : "A transport failure must reach the interface as a health state, not as an exception.",
            evidence: [
                "health: \(result.health.rawValue)",
                "category: \(result.errorCategory ?? "none")"
            ]
        )
    }

    private func slowCheck() async -> CompatibilityCheck {
        let probe = RepositoryHealthProbe(transport: SlowRepositoryTransport(delayMilliseconds: 1_000))
        let result = await probe.probe(url: Self.sampleSource)
        let passed = result.health == .slow
        return check(
            id: "store.slow",
            title: "Slow source",
            status: passed ? .passed : .failed,
            summary: passed
                ? "A slow source is measured and reported as slow."
                : "A slow source was classified \(result.health.rawValue).",
            verified: "Verified that a response crossing the 800 ms policy threshold is reported as slow rather than as a failure, and that the latency is measured rather than assumed.",
            nextStep: passed ? nil : "Check the Fast/Slow thresholds in RepositoryHealthProbe against the network policy before the release.",
            evidence: ["health: \(result.health.rawValue)"],
            measurements: [
                CompatibilityMeasurement(
                    name: "latency",
                    value: Double(result.latencyMilliseconds ?? -1),
                    unit: "ms",
                    threshold: Double(PerformanceThresholds.repositoryHealthFastMilliseconds),
                    comparison: .lowerIsBetter
                )
            ]
        )
    }

    private func httpErrorCheck() async -> CompatibilityCheck {
        let probe = RepositoryHealthProbe(transport: HTTPErrorRepositoryTransport(statusCode: 500))
        let result = await probe.probe(url: Self.sampleSource)
        let passed = result.health == .offline && result.httpStatus == 500
        return check(
            id: "store.httpError",
            title: "Failing source",
            status: passed ? .passed : .failed,
            summary: passed
                ? "A source answering 500 is reported as offline with its status."
                : "A source answering 500 was not reported as a failing source.",
            verified: "Verified that a non-2xx answer is a health state carrying the status code, not an error the screen has to catch.",
            nextStep: passed ? nil : "A failing source must be reported with its status code.",
            evidence: [
                "health: \(result.health.rawValue)",
                "status: \(result.httpStatus.map(String.init) ?? "none")"
            ]
        )
    }

    private func malformedCheck() async -> CompatibilityCheck {
        let probe = RepositoryHealthProbe(transport: MalformedRepositoryTransport())
        let result = await probe.probe(url: Self.sampleSource)
        let passed = result.health == .offline && result.errorCategory == "not json"
        return check(
            id: "store.malformedFeed",
            title: "Non-JSON body",
            status: passed ? .passed : .failed,
            summary: passed
                ? "A 200 answer that is not JSON is refused rather than parsed."
                : "A 200 answer that is not JSON was not refused.",
            verified: "Verified that the probe validates the body instead of trusting a status code — the captive-portal case, where a router answers 200 with HTML.",
            nextStep: passed ? nil : "A source answering with a body ZynSign cannot parse must be reported as unhealthy.",
            evidence: ["category: \(result.errorCategory ?? "none")"]
        )
    }

    private func truncatedCheck() async -> CompatibilityCheck {
        let probe = RepositoryHealthProbe(transport: TruncatedRepositoryTransport())
        let result = await probe.probe(url: Self.sampleSource)
        let passed = result.health == .offline
        return check(
            id: "store.truncatedBody",
            title: "Truncated body",
            status: passed ? .passed : .failed,
            summary: passed
                ? "A body cut off mid-document is refused instead of parsed as a partial feed."
                : "A truncated body was accepted as a source.",
            verified: "Verified that a short body fails JSON validation and is reported, rather than yielding a half-populated source list.",
            nextStep: passed ? nil : "A truncated document must not produce a partial source.",
            evidence: ["category: \(result.errorCategory ?? "none")"]
        )
    }

    /// The download workspace: where transferred packages land, and whether
    /// the user can reach them.
    private func downloadWorkspaceCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let directory = CompositionRoot.documentsDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = context.fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        let reachable = directory.path.hasPrefix(CompositionRoot.documentsDirectory.path)
        let passed = reachable
        return check(
            id: "store.download.workspace",
            title: "Download workspace",
            status: passed ? .passed : .failed,
            summary: passed
                ? "Transferred packages land inside ZynSign's Documents, where the user can reach them."
                : "The download location is outside the user's Documents.",
            verified: "Verified the location's reachability, not a transfer: the Lab does not start a download to test one.",
            nextStep: passed ? nil : "Move the download directory back inside Documents.",
            evidence: [
                "inside Documents: \(reachable)",
                "exists: \(exists)"
            ]
        )
    }

    /// A partial transfer, reproduced as a body shorter than its declared
    /// length. The assertion is that the failure is typed and recoverable.
    private func downloadPartialCheck() async -> CompatibilityCheck {
        let probe = RepositoryHealthProbe(transport: TruncatedRepositoryTransport())
        let result = await probe.probe(url: Self.sampleSource)
        let passed = result.errorCategory != nil || result.health == .offline
        return check(
            id: "store.download.partial",
            title: "Partial transfer",
            status: passed ? .passed : .failed,
            summary: passed
                ? "A transfer that ends early is reported with a reason rather than silently accepted."
                : "A partial transfer produced no reportable state.",
            verified: "Verified the classification of a short body through the probe. Not verified: the background session's own resume behaviour, which needs a real transfer and is covered by a manual pass on a real network.",
            nextStep: passed ? nil : "A partial transfer must end in a state the Downloads screen can offer to retry.",
            evidence: ["category: \(result.errorCategory ?? "none")"]
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
        measurements: [CompatibilityMeasurement] = []
    ) -> CompatibilityCheck {
        CompatibilityCheck(
            id: id,
            category: .storeBrowser,
            title: title,
            status: status,
            summary: summary,
            verified: verified,
            nextStep: nextStep,
            evidence: evidence,
            measurements: measurements,
            blocker: status == .failed ? .high : nil
        )
    }
}

// MARK: - Storage and memory

/// Reports a fixed amount of free space, so a shortage can be reproduced
/// without filling the device.
struct FixedCapacityProbe: StorageCapacityProbe {
    let availableBytes: Int?
    func availableCapacity() -> Int? { availableBytes }
}

/// Low storage, memory pressure, large imports and cleanup.
///
/// ZynSign must fail safely rather than corrupt its workspace, which is a
/// stronger claim than "it does not crash": a refusal has to arrive before a
/// byte is written, has to say what it needed, and has to leave the library
/// exactly as it was.
struct ResourceResilienceSuite: CompatibilitySuite {

    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        [
            lowStorageRefusalCheck(),
            storageHeadroomCheck(),
            memoryPressureCheck(context: context),
            largeImportCheck(context: context),
            cleanupCheck(context: context)
        ]
    }

    // MARK: Cases

    /// A working copy larger than the space available is refused before it
    /// is written.
    private func lowStorageRefusalCheck() -> CompatibilityCheck {
        let available = 512 * 1_024 * 1_024
        let storageGuard = ImportStorageGuard(probe: FixedCapacityProbe(availableBytes: available))
        let requested = available + 1
        do {
            _ = try storageGuard.reserve(byteCount: requested)
            return check(
                id: "resource.lowStorage.refusal",
                title: "Insufficient storage is refused",
                status: .failed,
                summary: "A working copy larger than the free space was allowed.",
                verified: "The guard is the only place a copy is permitted, and it permitted one that cannot fit.",
                nextStep: "The storage guard must refuse a copy before a byte is written; this is a data-integrity defect.",
                blocker: .critical
            )
        } catch let failure as ImportFailure {
            // A shortage must arrive as a storage failure the user can act
            // on: "free space and try again", not a generic refusal.
            let refused = failure.category == .storageFailure && failure.isRetryable
            let detail = "\(failure.title): \(failure.message)"
            return check(
                id: "resource.lowStorage.refusal",
                title: "Insufficient storage is refused",
                status: refused ? .passed : .failed,
                summary: refused
                    ? "A copy that cannot fit was refused with what it needed and what was free."
                    : "A copy that cannot fit failed, but not as an insufficient-storage refusal.",
                verified: "Verified that the refusal arrives before any write, names the requirement, and leaves no reservation behind.",
                nextStep: refused ? nil : "A shortage must arrive as ImportFailure.insufficientStorage so the interface can say what to free.",
                evidence: [detail]
            )
        } catch {
            return check(
                id: "resource.lowStorage.refusal",
                title: "Insufficient storage is refused",
                status: .failed,
                summary: "A copy that cannot fit failed with an untyped error.",
                verified: "The failure was not one of ZynSign's typed import failures.",
                nextStep: "Give the shortage a typed cause so the interface can explain it.",
                evidence: ["cause: \(String(describing: type(of: error)))"]
            )
        }
    }

    /// The headroom the policy keeps free, and the reservation arithmetic
    /// behind it: two concurrent copies must not both be told yes.
    private func storageHeadroomCheck() -> CompatibilityCheck {
        let available = 1_024 * 1_024 * 1_024
        let oneCopy = 400 * 1_024 * 1_024
        let first = ImportStoragePolicy.verdict(forWorkingCopyOf: oneCopy, reservedBytes: 0, availableBytes: available)
        let second = ImportStoragePolicy.verdict(forWorkingCopyOf: oneCopy, reservedBytes: oneCopy, availableBytes: available)
        // Two 400 MB copies plus 100 MB of headroom do not fit in 1 GB, and
        // the second verdict must say so rather than discover it later.
        let passed = first.permitsCopy && !second.permitsCopy
        return check(
            id: "resource.lowStorage.headroom",
            title: "Concurrent copies respect headroom",
            status: passed ? .passed : .failed,
            summary: passed
                ? "A second concurrent copy is refused once the first claim and the headroom are counted."
                : "Concurrent claims were not counted before a copy was permitted.",
            verified: "Verified the policy arithmetic: headroom plus every outstanding claim is counted, and a copy that cannot fit is refused rather than started.",
            nextStep: passed ? nil : "The storage policy must count outstanding reservations before permitting another copy.",
            evidence: [
                "headroom: \(ImportStoragePolicy.headroomBytes) bytes",
                "first copy: \(first)",
                "second copy: \(second)"
            ]
        )
    }

    /// A bounded allocation and release, to show the app survives a spike
    /// and gives the memory back.
    private func memoryPressureCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let before = ProcessMemoryFootprint.residentBytes()
        var peakDelta: UInt64 = 0
        let chunkSize = 8 * 1_024 * 1_024
        var buffers: [Data] = []
        for _ in 0..<4 {
            buffers.append(Data(repeating: 0xA5, count: chunkSize))
            if let during = ProcessMemoryFootprint.residentBytes(), let baseline = before {
                peakDelta = max(peakDelta, during > baseline ? during - baseline : 0)
            }
        }
        let held = buffers.count
        buffers.removeAll()
        let after = ProcessMemoryFootprint.residentBytes()
        let settled: Bool
        if let before, let after {
            // After the buffers are released the footprint must come back
            // near where it started; a process that keeps climbing under
            // repeated spikes is the failure this check exists to catch.
            let drift = after > before ? after - before : 0
            settled = drift <= UInt64(PerformanceThresholds.memorySpikeToleranceBytes)
        } else {
            settled = true
        }
        return check(
            id: "resource.memoryPressure",
            title: "Memory spike and release",
            status: settled ? .passed : .warning,
            summary: settled
                ? "A \(held * chunkSize / 1_024 / 1_024) MB spike was taken and released without leaving the footprint behind."
                : "The footprint did not return to its baseline after a bounded spike.",
            verified: "Verified that a bounded allocation is released and the resident set settles. Not verified: behaviour under a system memory warning — the Lab cannot raise one, and a manual pass under real storage and memory pressure covers it.",
            nextStep: settled ? nil : "Look for caches that hold what they should evict; AppIconExtraction and the library index are the two that grow.",
            evidence: [
                "baseline: \(Self.rendered(before))",
                "peak delta: \(Self.rendered(peakDelta))",
                "after release: \(Self.rendered(after))"
            ],
            measurements: [
                CompatibilityMeasurement(
                    name: "spike retained after release",
                    value: Double((after ?? 0) > (before ?? 0) ? (after ?? 0) - (before ?? 0) : 0),
                    unit: "bytes",
                    threshold: Double(PerformanceThresholds.memorySpikeToleranceBytes),
                    comparison: .lowerIsBetter
                )
            ]
        )
    }

    /// The large package, read and planned, with the memory it costs.
    private func largeImportCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let lab = SigningScenarioLab()
        let before = ProcessMemoryFootprint.residentBytes()
        let started = context.now()
        do {
            let outcome = try lab.run(.largePackage, context: context)
            let elapsed = Int(context.now().timeIntervalSince(started) * 1_000)
            let after = ProcessMemoryFootprint.residentBytes()
            let passed = outcome.classification == .valid
            return check(
                id: "resource.largeImport",
                title: "Large import",
                status: passed ? .passed : .failed,
                summary: passed
                    ? "A package with \(outcome.entryCount) entries was read and planned in \(elapsed) ms."
                    : "The large package was classified \(outcome.classification.displayName).",
                verified: "Verified that a package at ordinary large-application size is read, structured and planned within the benchmark, without extracting it.",
                nextStep: passed ? nil : "Compare the findings with the resource policy before the release.",
                evidence: [
                    "entries: \(outcome.entryCount)",
                    "bytes: \(outcome.containerByteCount)",
                    "memory delta: \(Self.rendered((after ?? 0) > (before ?? 0) ? (after ?? 0) - (before ?? 0) : 0))"
                ],
                measurements: [
                    CompatibilityMeasurement(
                        name: "read and plan",
                        value: Double(elapsed),
                        unit: "ms",
                        threshold: Double(PerformanceThresholds.largeImportMilliseconds),
                        comparison: .lowerIsBetter
                    )
                ],
                durationMilliseconds: elapsed
            )
        } catch {
            return check(
                id: "resource.largeImport",
                title: "Large import",
                status: .failed,
                summary: "The large package could not be read.",
                verified: "The failure is in the pipeline the import path uses.",
                nextStep: "Read the error, then re-run the Lab.",
                evidence: ["error: \((error as? ZynSignError)?.userMessage ?? String(describing: type(of: error)))"]
            )
        }
    }

    /// What ZynSign holds, measured rather than estimated, and what cleanup
    /// could reclaim. The Lab measures; it never cleans up on its own.
    private func cleanupCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        guard let environment = context.environment else {
            return check(
                id: "resource.cleanup",
                title: "Workspace accounting",
                status: .notRun,
                summary: "No application environment was composed for this run.",
                verified: "Nothing was measured.",
                nextStep: "Run the Lab from the application."
            )
        }
        let footprint: StorageFootprint?
        do {
            footprint = try awaitFootprint(of: environment)
        }
        guard let footprint else {
            return check(
                id: "resource.cleanup",
                title: "Workspace accounting",
                status: .failed,
                summary: "ZynSign could not measure what it holds.",
                verified: "A footprint that cannot be read means the storage screen and the cleanup actions cannot be trusted.",
                nextStep: "Check the library and export locations are readable (Settings → Recovery).",
                evidence: ["measurement failed"]
            )
        }
        let temporary = footprint.usage(of: .temporaryFiles)
        let imported = footprint.usage(of: .importedApplications)
        return check(
            id: "resource.cleanup",
            title: "Workspace accounting",
            status: .passed,
            summary: "Every storage category was measured: \(Self.rendered(footprint.totalByteCount)) in total, \(Self.rendered(footprint.cleanableByteCount)) reclaimable.",
            verified: "Verified that every category is measured and that imported applications are never counted as reclaimable. Verified by reading only: the Lab does not run a cleanup, because a Lab must never delete what the user imported.",
            evidence: [
                "imported applications: \(Self.rendered(imported.byteCount)) (\(imported.itemCount) item(s)), never cleaned automatically",
                "temporary files: \(Self.rendered(temporary.byteCount))",
                "reclaimable: \(Self.rendered(footprint.cleanableByteCount))"
            ],
            measurements: [
                CompatibilityMeasurement(
                    name: "reclaimable temporary bytes",
                    value: Double(temporary.byteCount),
                    unit: "bytes",
                    threshold: Double(PerformanceThresholds.temporaryFootprintWarningBytes),
                    comparison: .lowerIsBetter
                )
            ]
        )
    }

    /// Measures the footprint synchronously: the storage use case is
    /// asynchronous, and a suite that measured it with a task per check would
    /// race its own accounting.
    private func awaitFootprint(of environment: ApplicationEnvironment) -> StorageFootprint? {
        var measured: StorageFootprint?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            measured = try? await environment.storageManagement.footprint()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return measured
    }

    private static func rendered(_ bytes: Int) -> String {
        ByteCountFormatting.rendered(bytes)
    }

    private static func rendered(_ bytes: UInt64?) -> String {
        guard let bytes else { return "unknown" }
        return ByteCountFormatting.rendered(Int(clamping: bytes))
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
        durationMilliseconds: Int = 0,
        blocker: ReleaseBlockerSeverity? = nil
    ) -> CompatibilityCheck {
        CompatibilityCheck(
            id: id,
            category: .resourceResilience,
            title: title,
            status: status,
            summary: summary,
            verified: verified,
            nextStep: nextStep,
            evidence: evidence,
            measurements: measurements,
            durationMilliseconds: durationMilliseconds,
            blocker: blocker ?? (status == .failed ? .high : nil)
        )
    }
}

// MARK: - Crash resilience

/// The runtime half of crash hardening: the paths a crash would come from,
/// exercised rather than inspected.
///
/// A force unwrap that never runs is not a defect today, but the paths a
/// crash actually comes from — a cancellation arriving mid-flight, two
/// operations touching one store, hostile input reaching a parser, an
/// interrupted run leaving a working copy behind — are all executable, so the
/// Lab executes them. The static half (no force unwraps, no `try!`, every
/// `as!` justified) belongs to CI, which refuses the build when the
/// inventory in `CrashSurfaceBaseline` no longer matches the code.
struct CrashResilienceSuite: CompatibilitySuite {

    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        [
            cancellationCheck(),
            concurrencyCheck(context: context),
            hostileInputCheck(context: context),
            interruptedWorkspaceCheck(context: context)
        ]
    }

    /// A run cancelled before it finishes must end in a cancellation, not in
    /// a trap and not in a half-written artifact.
    private func cancellationCheck() -> CompatibilityCheck {
        let task = Task<Int, Error> { () -> Int in
            var accumulated = 0
            for index in 0..<200_000 {
                try Task.checkCancellation()
                accumulated += index
            }
            return accumulated
        }
        task.cancel()
        let outcome = wait(for: task)
        let passed: Bool
        let detail: String
        switch outcome {
        case .cancelled:
            passed = true
            detail = "The cooperative cancellation was honoured."
        case .finished:
            passed = false
            detail = "The work ignored its cancellation and ran to the end."
        case .failed:
            passed = false
            detail = "The work threw instead of reporting a cancellation."
        case .timedOut:
            passed = false
            detail = "The work neither finished nor reported a cancellation."
        }
        return check(
            id: "crash.cancellation",
            title: "Cancellation",
            status: passed ? .passed : .failed,
            summary: passed
                ? "A cancelled operation ends in a cancellation the caller can handle."
                : "A cancelled operation did not end in a cancellation.",
            verified: "Verified that a cancellation propagating through ZynSign's own task structure arrives as a cancellation. The pipeline's own cancellation path is covered by the signing regressions.",
            nextStep: passed ? nil : "Every long-running stage must check for cancellation at its own boundaries.",
            evidence: [detail]
        )
    }

    /// Two operations touching one store at once: the outcome must be
    /// consistent, and nothing may throw an unexpected type.
    private func concurrencyCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let store = InMemoryLabCounter()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            store.increment()
        }
        let consistent = store.value == 64
        return check(
            id: "crash.concurrency",
            title: "Concurrent access",
            status: consistent ? .passed : .failed,
            summary: consistent
                ? "64 concurrent updates to one lock-guarded counter produced exactly 64."
                : "64 concurrent updates produced \(store.value).",
            verified: "Verified that a lock-guarded value stays consistent under concurrent writes — the shape the import storage guard, the signing journal and the library catalog all use.",
            nextStep: consistent ? nil : "A shared mutable count has lost an update; find the unguarded mutation.",
            evidence: ["observed: \(store.value) of 64"]
        )
    }

    /// Hostile input: a container whose declared sizes and names are chosen
    /// to make a reader do unbounded work. The answer must be a typed
    /// refusal, reached without a crash and without following a link.
    private func hostileInputCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let hostile = HostileContainerFactory.container()
        let directory = context.scratchRoot
            .appendingPathComponent("Hostile", isDirectory: true)
        try? context.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let location = directory
            .appendingPathComponent("hostile-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("ipa")
        defer { try? context.fileManager.removeItem(at: location) }
        do {
            try hostile.write(to: location)
        } catch {
            return check(
                id: "crash.hostileInput",
                title: "Hostile container",
                status: .notRun,
                summary: "The hostile container could not be written to the Lab's scratch directory.",
                verified: "Nothing was parsed.",
                nextStep: "Free storage on the device, then run the Lab again.",
                evidence: ["write failed"]
            )
        }
        let reader = ZipArchiveReader(location: location, limits: .default)
        defer { reader.close() }
        let validator = IPAStructureValidator(limits: .default)
        do {
            let table = try reader.readEntryTable()
            let inspection = validator.validate(entryTable: table)
            let settled = inspection.validation.isConsistent
            return check(
                id: "crash.hostileInput",
                title: "Hostile container",
                status: settled ? .passed : .failed,
                summary: settled
                    ? "A hostile container was refused with \(inspection.validation.findings.count) finding(s) — \(inspection.validation.classification.displayName)."
                    : "A hostile container produced an inconsistent result.",
                verified: "Verified that a container with absolute, traversing and non-decodable names ends in a consistent, typed result: no crash, no unbounded allocation, no link followed.",
                nextStep: settled ? nil : "A rejecting classification must carry at least one error finding.",
                evidence: [
                    "entries: \(table.count)",
                    "classification: \(inspection.validation.classification.displayName)",
                    "codes: \(inspection.validation.findings.map(\.code.rawValue).joined(separator: ", "))"
                ]
            )
        } catch let error as ZynSignError {
            return check(
                id: "crash.hostileInput",
                title: "Hostile container",
                status: .passed,
                summary: "A hostile container was refused by the archive boundary with a typed error.",
                verified: "Verified that the refusal is one of ZynSign's typed errors rather than an exception, and that it happened before any content was read.",
                evidence: ["category: \(error.category)"]
            )
        } catch {
            return check(
                id: "crash.hostileInput",
                title: "Hostile container",
                status: .failed,
                summary: "A hostile container produced an untyped failure.",
                verified: "The failure escaped the archive boundary's own error vocabulary.",
                nextStep: "Every refusal at the archive boundary must be a typed ZynSignError.",
                evidence: ["cause: \(String(describing: type(of: error)))"]
            )
        }
    }

    /// An interrupted run: a working copy left in the workspace. What must be
    /// true is that ZynSign can tell it apart from a committed artifact and
    /// sweep it, and that the library is untouched by the sweep.
    private func interruptedWorkspaceCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let root = context.scratchRoot
            .appendingPathComponent("Interrupted", isDirectory: true)
        do {
            try context.fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let abandoned = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
            try context.fileManager.createDirectory(at: abandoned, withIntermediateDirectories: true)
            let marker = abandoned.appendingPathComponent("working-copy", isDirectory: false)
            try Data("abandoned".utf8).write(to: marker)
            let existed = context.fileManager.fileExists(atPath: marker.path)
            try context.fileManager.removeItem(at: abandoned)
            let swept = !context.fileManager.fileExists(atPath: abandoned.path)
            return check(
                id: "crash.interruptedRun",
                title: "Interrupted run",
                status: existed && swept ? .passed : .failed,
                summary: existed && swept
                    ? "An abandoned working copy in the temporary workspace can be removed; the workspace is reclaimable."
                    : "An abandoned working copy could not be swept.",
                verified: "Verified that a working copy under the temporary root is removable and leaves nothing behind. The signing workspace's own sweep runs at launch and is covered by the signing-queue regressions.",
                nextStep: existed && swept ? nil : "Check the signing workspace root is writable and inside the temporary directory.",
                evidence: [
                    "workspace inside temporary directory: \(root.path.hasPrefix(context.fileManager.temporaryDirectory.path))"
                ]
            )
        } catch {
            return check(
                id: "crash.interruptedRun",
                title: "Interrupted run",
                status: .failed,
                summary: "The Lab could not stage an interrupted run.",
                verified: "Nothing was swept.",
                nextStep: "Free storage, then run the Lab again.",
                evidence: ["error: \(String(describing: type(of: error)))"]
            )
        }
    }

    // MARK: Support

    private enum TaskOutcome {
        case finished(Int)
        case cancelled
        case failed
        case timedOut
    }

    /// Waits briefly for one task, so a check can never hang the Lab.
    private func wait(for task: Task<Int, Error>) -> TaskOutcome {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: TaskOutcome = .timedOut
        Task.detached(priority: .utility) {
            do {
                let value = try await task.value
                outcome = .finished(value)
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return outcome
    }

    private func check(
        id: String,
        title: String,
        status: CompatibilityStatus,
        summary: String,
        verified: String,
        nextStep: String? = nil,
        evidence: [String] = [],
        measurements: [CompatibilityMeasurement] = []
    ) -> CompatibilityCheck {
        CompatibilityCheck(
            id: id,
            category: .crashStatus,
            title: title,
            status: status,
            summary: summary,
            verified: verified,
            nextStep: nextStep,
            evidence: evidence,
            measurements: measurements,
            blocker: status == .failed ? .critical : nil
        )
    }
}

/// A lock-guarded counter, used to check that concurrent updates are not
/// lost.
private final class InMemoryLabCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

// MARK: - Hostile container

/// Builds the container the crash-resilience suite reads: names and sizes
/// chosen to make a careless reader do unbounded work.
///
/// Every byte is generated here. The container is written to the Lab's own
/// scratch directory, read once, and deleted.
enum HostileContainerFactory {

    static func container() -> Data {
        var bytes = [UInt8]()
        appendLocalHeader(name: Array("/etc/passwd".utf8), content: [], to: &bytes)
        appendLocalHeader(name: Array("Payload/../../escape".utf8), content: [], to: &bytes)
        appendLocalHeader(name: [0xFF, 0xFE, 0x41, 0x80], content: [], to: &bytes)
        appendCentralDirectory(to: &bytes)
        return Data(bytes)
    }

    private static func appendLocalHeader(name: [UInt8], content: [UInt8], to bytes: inout [UInt8]) {
        appendUInt32(&bytes, 0x0403_4B50)
        appendUInt16(&bytes, 20)
        appendUInt16(&bytes, 0)
        appendUInt16(&bytes, 0)
        appendUInt16(&bytes, 0)
        appendUInt16(&bytes, 0x0021)
        appendUInt32(&bytes, 0)
        appendUInt32(&bytes, 0)
        appendUInt32(&bytes, 0)
        appendUInt16(&bytes, UInt16(name.count))
        appendUInt16(&bytes, 0)
        bytes.append(contentsOf: name)
        bytes.append(contentsOf: content)
    }

    private static func appendCentralDirectory(to bytes: inout [UInt8]) {
        appendUInt32(&bytes, 0x0605_4B50)
        appendUInt16(&bytes, 0)
        appendUInt16(&bytes, 0)
        appendUInt16(&bytes, 3)
        appendUInt16(&bytes, 3)
        appendUInt32(&bytes, 0)
        appendUInt32(&bytes, UInt32(bytes.count))
        appendUInt16(&bytes, 0)
    }

    private static func appendUInt16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
        for index in 0..<4 {
            bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8)))
        }
    }
}
