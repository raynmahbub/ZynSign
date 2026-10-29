import XCTest
@testable import ZynSign

/// A transport that records what it was asked to do and hands the service's
/// own handler back to the test, so every decision under test is the
/// production one. It stands in for the socket, nothing else.
private final class LocalTransferTestTransport: LocalTransferTransport, @unchecked Sendable {

    let endpoint: LocalTransferEndpoint
    private(set) var startedPorts: [UInt16] = []
    private(set) var stopCount = 0
    private(set) var handler: (@Sendable (LocalTransferHTTP.Request, LocalTransferIncomingBody) async -> LocalTransferHTTP.Response)?

    init(endpoint: LocalTransferEndpoint = LocalTransferEndpoint(port: 8_080, addresses: ["192.168.1.10"])) {
        self.endpoint = endpoint
    }

    func start(
        port: UInt16,
        limits: LocalTransferLimits,
        handling: @escaping @Sendable (LocalTransferHTTP.Request, LocalTransferIncomingBody) async -> LocalTransferHTTP.Response
    ) async throws -> LocalTransferEndpoint {
        startedPorts.append(port)
        handler = handling
        return endpoint
    }

    func stop() async {
        stopCount += 1
    }

    /// Delivers one request through the recorded handler.
    func deliver(
        _ request: LocalTransferHTTP.Request,
        body: LocalTransferIncomingBody = .none
    ) async -> LocalTransferHTTP.Response {
        guard let handler else {
            return LocalTransferHTTP.Response.rejection(.notListening)
        }
        return await handler(request, body)
    }
}

/// A transport whose listener refuses to open.
private final class LocalTransferFailingTransport: LocalTransferTransport, @unchecked Sendable {

    func start(
        port: UInt16,
        limits: LocalTransferLimits,
        handling: @escaping @Sendable (LocalTransferHTTP.Request, LocalTransferIncomingBody) async -> LocalTransferHTTP.Response
    ) async throws -> LocalTransferEndpoint {
        throw ZynSignError.localTransferListenerFailed(diagnosticDetail: "test")
    }

    func stop() async {}
}

/// A clock the test can advance, so an expired session can be observed
/// without waiting for it.
private final class LocalTransferTestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

/// A fixed entropy source, so a session's token is known to the test.
private struct LocalTransferFixedRandom: SecureRandomSource {
    let bytes: Data

    func randomBytes(count: Int) throws -> Data {
        guard bytes.count == count else {
            throw ZynSignError.localTransferEntropyUnavailable()
        }
        return bytes
    }
}

final class LocalTransferTests: XCTestCase {

    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignLocalTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        workspace = nil
    }

    // MARK: - Fixtures

    private func limits(
        maximumUpload: Int = 4_096,
        maximumRequests: Int = 10,
        lifetime: TimeInterval = 600
    ) -> LocalTransferLimits {
        LocalTransferLimits(
            maximumUploadBytes: maximumUpload,
            maximumHeadBytes: 4_096,
            sessionLifetime: lifetime,
            maximumRequests: maximumRequests,
            requestTimeout: 30
        )
    }

    /// The token the fixed entropy source draws: 32 bytes of `0x2A`.
    private var expectedToken: String { String(repeating: "2a", count: 32) }

    private func makeService(
        limits: LocalTransferLimits,
        transport: LocalTransferTestTransport,
        date: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> LocalTransferService {
        LocalTransferService(
            stagingDirectory: workspace,
            limits: limits,
            random: LocalTransferFixedRandom(bytes: Data(repeating: 0x2A, count: 32)),
            makeTransport: { transport },
            now: { date }
        )
    }

    /// Builds a request as the parser would, for a path under the token.
    private func request(
        _ method: LocalTransferHTTP.Method = .put,
        path: String,
        contentLength: Int = 0,
        headers: [String: String] = [:]
    ) -> LocalTransferHTTP.Request {
        LocalTransferHTTP.Request(
            method: method,
            target: path,
            headers: headers,
            contentLength: contentLength
        )
    }

    /// Writes a body file the transport would have produced.
    private func bodyFile(bytes: Int) throws -> URL {
        let url = workspace.appendingPathComponent("incoming-\(UUID().uuidString).upload")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - Head parsing

    func testParsesAWellFormedUploadHead() throws {
        let head = "PUT /token/upload/App.ipa HTTP/1.1\r\nHost: phone\r\nContent-Length: 12\r\nContent-Type: application/octet-stream\r\n\r\n"
        let parse = LocalTransferHTTP.parseHead(Data(head.utf8), limits: limits())
        guard case .requested(let request, let consumed) = parse else {
            return XCTFail("Expected a request, got \(parse)")
        }
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.path, "/token/upload/App.ipa")
        XCTAssertEqual(request.contentLength, 12)
        XCTAssertEqual(request.header("content-type"), "application/octet-stream")
        XCTAssertEqual(consumed, head.utf8.count)
    }

    func testIncompleteHeadAsksForMoreBytes() {
        let head = "GET /token/ HTTP/1.1\r\nHost: phone\r\n"
        XCTAssertEqual(LocalTransferHTTP.parseHead(Data(head.utf8), limits: limits()), .incomplete)
    }

    func testRefusesAHeadBeyondTheBound() {
        let filler = String(repeating: "a", count: 5_000)
        let head = "GET /\(filler) HTTP/1.1\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(head.utf8), limits: limits()),
            .rejected(.headTooLarge)
        )
    }

    func testRefusesAnUnknownMethodWithoutEchoingIt() throws {
        let head = "DELETE /token/upload/App.ipa HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let parse = LocalTransferHTTP.parseHead(Data(head.utf8), limits: limits())
        guard case .rejected(let rejection) = parse else {
            return XCTFail("Expected a rejection, got \(parse)")
        }
        XCTAssertEqual(rejection, .unsupportedMethod)
        XCTAssertEqual(rejection.status, 405)
        XCTAssertFalse(rejection.message.contains("DELETE"))
    }

    func testRefusesFoldedAndMalformedHeaders() {
        let folded = "GET /token/ HTTP/1.1\r\nHost: phone\r\n  continued\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(folded.utf8), limits: limits()),
            .rejected(.malformedHeader)
        )
        let noColon = "GET /token/ HTTP/1.1\r\nHost phone\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(noColon.utf8), limits: limits()),
            .rejected(.malformedHeader)
        )
    }

    func testRefusesDuplicatedAndInvalidContentLength() {
        let duplicated = "PUT /token/upload/App.ipa HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(duplicated.utf8), limits: limits()),
            .rejected(.conflictingContentLength)
        )
        let notANumber = "PUT /token/upload/App.ipa HTTP/1.1\r\nContent-Length: 12a\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(notANumber.utf8), limits: limits()),
            .rejected(.invalidContentLength)
        )
    }

    func testRefusesChunkedFramingAndMissingLengthOnAWrite() {
        let chunked = "PUT /token/upload/App.ipa HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(chunked.utf8), limits: limits()),
            .rejected(.unsupportedTransferEncoding)
        )
        let noLength = "PUT /token/upload/App.ipa HTTP/1.1\r\nHost: phone\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(noLength.utf8), limits: limits()),
            .rejected(.lengthRequired)
        )
    }

    func testRefusesADeclaredBodyBeyondTheUploadBound() {
        let head = "PUT /token/upload/App.ipa HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(head.utf8), limits: limits(maximumUpload: 4_096)),
            .rejected(.payloadTooLarge(limit: 4_096))
        )
    }

    func testRefusesATargetThatIsNotAnOriginForm() {
        let absolute = "GET http://evil.example/token/ HTTP/1.1\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(absolute.utf8), limits: limits()),
            .rejected(.malformedRequestLine)
        )
        let badVersion = "GET /token/ HTTP/2.0\r\n\r\n"
        XCTAssertEqual(
            LocalTransferHTTP.parseHead(Data(badVersion.utf8), limits: limits()),
            .rejected(.malformedRequestLine)
        )
    }

    func testResponseWritesItsOwnLengthAndCloses() {
        let response = LocalTransferHTTP.Response.text(401, "Unauthorized", body: "no")
        let text = String(decoding: response.serialized, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nno"))
    }

    // MARK: - Names and tokens

    func testAcceptsOnlyKnownPackagesAndSigningMaterial() {
        XCTAssertEqual(LocalTransferFileName.accepted("App.ipa"), "App.ipa")
        XCTAssertEqual(LocalTransferFileName.accepted("App.TIPA"), "App.TIPA")
        XCTAssertEqual(LocalTransferFileName.accepted("identity.p12"), "identity.p12")
        XCTAssertNil(LocalTransferFileName.accepted("payload.dylib"))
        XCTAssertNil(LocalTransferFileName.accepted("App.ipa.exe"))
        XCTAssertNil(LocalTransferFileName.accepted("../../etc/passwd"))
        XCTAssertNil(LocalTransferFileName.accepted("../App.ipa"))
        XCTAssertNil(LocalTransferFileName.accepted("sub/App.ipa"))
        XCTAssertNil(LocalTransferFileName.accepted(".hidden.ipa"))
        XCTAssertNil(LocalTransferFileName.accepted("con.ipa"))
        XCTAssertNil(LocalTransferFileName.accepted(""))
        XCTAssertNil(LocalTransferFileName.accepted(String(repeating: "a", count: 300) + ".ipa"))
    }

    func testPercentDecodingRefusesMalformedEscapes() {
        XCTAssertEqual(LocalTransferPercentDecoding.decode("App%2Eipa"), "App.ipa")
        XCTAssertNil(LocalTransferPercentDecoding.decode("App%2"))
        XCTAssertNil(LocalTransferPercentDecoding.decode("App%zzipa"))
        XCTAssertNil(LocalTransferPercentDecoding.decode("%00.ipa"))
    }

    func testTokenComparisonIsExactAndShapeChecked() throws {
        let token = try XCTUnwrap(LocalTransferToken(bytes: Data(repeating: 0x2A, count: 32)))
        XCTAssertEqual(token.value, expectedToken)
        XCTAssertTrue(token.matches(expectedToken))
        XCTAssertFalse(token.matches(String(repeating: "2a", count: 31)))
        XCTAssertFalse(token.matches(String(repeating: "2b", count: 32)))
        XCTAssertFalse(token.matches(""))
        XCTAssertNil(LocalTransferToken(value: "not hex"))
        XCTAssertNil(LocalTransferToken(value: String(repeating: "A", count: 64)))
        XCTAssertNil(LocalTransferToken(bytes: Data(repeating: 0x2A, count: 31)))
    }

    func testSessionExpiresAtItsOwnDeadline() throws {
        let session = try LocalTransferSession.open(
            limits: limits(lifetime: 60),
            now: Date(timeIntervalSince1970: 1_000),
            random: LocalTransferFixedRandom(bytes: Data(repeating: 0x2A, count: 32))
        )
        XCTAssertFalse(session.isExpired(at: Date(timeIntervalSince1970: 1_059)))
        XCTAssertTrue(session.isExpired(at: Date(timeIntervalSince1970: 1_060)))
    }

    // MARK: - Service

    func testStartingOpensOneSessionAndBindsTheRequestedPort() async {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        let snapshot = await service.start(port: 9_000)
        XCTAssertEqual(transport.startedPorts, [9_000])
        XCTAssertEqual(snapshot.token, expectedToken)
        XCTAssertEqual(snapshot.endpoint?.port, 8_080)
        XCTAssertEqual(snapshot.endpoint?.displayAddress, "http://192.168.1.10:8080")
        XCTAssertTrue(snapshot.isListening)

        // A second start does not open a second listener or mint a new token.
        _ = await service.start(port: 9_000)
        XCTAssertEqual(transport.startedPorts, [9_000])
    }

    func testAFailedStartReportsTheReasonAndLeavesNothingListening() async {
        let service = LocalTransferService(
            stagingDirectory: workspace,
            limits: limits(),
            random: LocalTransferFixedRandom(bytes: Data(repeating: 0x2A, count: 32)),
            makeTransport: { LocalTransferFailingTransport() },
            now: Date.init
        )
        let snapshot = await service.start()
        guard case .failed(let message) = snapshot.state else {
            return XCTFail("Expected a failure, got \(snapshot.state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(snapshot.isListening)
        XCTAssertNil(snapshot.token)
    }

    func testUploadWithTheTokenIsStoredAndRecorded() async throws {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        let file = try bodyFile(bytes: 32)

        let response = await transport.deliver(
            request(path: "/\(expectedToken)/upload/App.ipa", contentLength: 32),
            body: .file(file, byteCount: 32)
        )
        XCTAssertEqual(response.status, 201)
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.receipts.count, 1)
        XCTAssertEqual(snapshot.receipts.first?.fileName, "App.ipa")
        XCTAssertEqual(snapshot.receipts.first?.byteCount, 32)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("App.ipa").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSecondUploadOfTheSameNameDoesNotOverwriteTheFirst() async throws {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        for _ in 0..<2 {
            let file = try bodyFile(bytes: 8)
            let response = await transport.deliver(
                request(path: "/\(expectedToken)/upload/App.ipa", contentLength: 8),
                body: .file(file, byteCount: 8)
            )
            XCTAssertEqual(response.status, 201)
        }
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.receipts.map { $0.fileName }, ["App.ipa", "App-2.ipa"])
    }

    func testUploadWithoutTheTokenIsRefusedAndStoresNothing() async throws {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        let file = try bodyFile(bytes: 8)
        let response = await transport.deliver(
            request(path: "/\(String(repeating: "00", count: 32))/upload/App.ipa", contentLength: 8),
            body: .file(file, byteCount: 8)
        )
        XCTAssertEqual(response.status, 401)
        let snapshot = await service.snapshot()
        XCTAssertTrue(snapshot.receipts.isEmpty)
        XCTAssertEqual(snapshot.rejectionCount, 1)
        // A refused upload's temporary file is not left behind by the service;
        // the transport that owns it removes it when the connection closes.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testBearerCredentialAuthenticatesWithoutATokenInThePath() async throws {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        let file = try bodyFile(bytes: 8)
        let response = await transport.deliver(
            request(
                path: "/upload/App.ipa",
                contentLength: 8,
                headers: ["authorization": "Bearer \(expectedToken)"]
            ),
            body: .file(file, byteCount: 8)
        )
        XCTAssertEqual(response.status, 201)
    }

    func testRefusesAnUnroutableNameAndAnEmptyBody() async throws {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()

        let rejected = try bodyFile(bytes: 8)
        let rejectedResponse = await transport.deliver(
            request(path: "/\(expectedToken)/upload/payload.dylib", contentLength: 8),
            body: .file(rejected, byteCount: 8)
        )
        XCTAssertEqual(rejectedResponse.status, 415)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))

        let empty = await transport.deliver(
            request(path: "/\(expectedToken)/upload/App.ipa", contentLength: 0),
            body: .none
        )
        XCTAssertEqual(empty.status, 400)
        let snapshot = await service.snapshot()
        XCTAssertTrue(snapshot.receipts.isEmpty)
    }

    func testRefusesAnUploadBeyondTheSessionBound() async throws {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(maximumUpload: 16), transport: transport)
        _ = await service.start()
        // The transport produces the file; the service re-checks the size it
        // was handed, so a transport bug cannot store an oversized body.
        let file = try bodyFile(bytes: 64)
        let response = await transport.deliver(
            request(path: "/\(expectedToken)/upload/App.ipa", contentLength: 64),
            body: .file(file, byteCount: 64)
        )
        XCTAssertEqual(response.status, 413)
        let snapshot = await service.snapshot()
        XCTAssertTrue(snapshot.receipts.isEmpty)
    }

    func testRequestBudgetIsFinite() async {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(maximumRequests: 2), transport: transport)
        _ = await service.start()
        for _ in 0..<2 {
            let response = await transport.deliver(request(.get, path: "/\(expectedToken)/"))
            XCTAssertEqual(response.status, 200)
        }
        let refused = await transport.deliver(request(.get, path: "/\(expectedToken)/"))
        XCTAssertEqual(refused.status, 429)
    }

    func testStatusPageReportsTheCommandAndNeverListsAPath() async {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        let response = await transport.deliver(request(.get, path: "/\(expectedToken)/"))
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("curl --data-binary @App.ipa"))
        XCTAssertTrue(html.contains("192.168.1.10:8080"))
        XCTAssertFalse(html.contains(workspace.path))
    }

    func testHeadAnswersThePageWithoutABody() async {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        let response = await transport.deliver(request(.head, path: "/\(expectedToken)/"))
        XCTAssertEqual(response.status, 200)
    }

    func testUnknownRouteIsNotFound() async {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        let response = await transport.deliver(request(.get, path: "/\(expectedToken)/files"))
        XCTAssertEqual(response.status, 404)
    }

    func testExpiredSessionRefusesAndStopsTheListener() async {
        let transport = LocalTransferTestTransport()
        let clock = LocalTransferTestClock(Date(timeIntervalSince1970: 5_000))
        let service = LocalTransferService(
            stagingDirectory: workspace,
            limits: limits(lifetime: 60),
            random: LocalTransferFixedRandom(bytes: Data(repeating: 0x2A, count: 32)),
            makeTransport: { transport },
            now: { clock.now }
        )
        _ = await service.start()
        clock.now = Date(timeIntervalSince1970: 5_061)
        let response = await transport.deliver(request(.get, path: "/\(expectedToken)/"))
        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(transport.stopCount, 1)
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.state, .stopped)
    }

    func testStartingAgainAfterExpiryOpensANewSession() async {
        let transport = LocalTransferTestTransport()
        let clock = LocalTransferTestClock(Date(timeIntervalSince1970: 7_000))
        let service = LocalTransferService(
            stagingDirectory: workspace,
            limits: limits(lifetime: 60),
            random: LocalTransferFixedRandom(bytes: Data(repeating: 0x2A, count: 32)),
            makeTransport: { transport },
            now: { clock.now }
        )
        _ = await service.start(port: 9_100)
        clock.now = Date(timeIntervalSince1970: 7_061)
        let expired = await service.snapshot()
        XCTAssertEqual(expired.state, .stopped)

        let restarted = await service.start(port: 9_100)
        XCTAssertTrue(restarted.isListening)
        XCTAssertEqual(restarted.token, expectedToken)
        XCTAssertEqual(transport.startedPorts, [9_100, 9_100])
    }

    func testUploadRouteAnswersOnlyWrites() async {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        let read = await transport.deliver(request(.get, path: "/\(expectedToken)/upload/App.ipa"))
        XCTAssertEqual(read.status, 404)
        let head = await transport.deliver(request(.head, path: "/\(expectedToken)/upload/App.ipa"))
        XCTAssertEqual(head.status, 404)
    }

    func testStoppingDiscardsTheTokenAndKeepsReceivedFiles() async throws {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        let file = try bodyFile(bytes: 8)
        _ = await transport.deliver(
            request(path: "/\(expectedToken)/upload/App.ipa", contentLength: 8),
            body: .file(file, byteCount: 8)
        )
        await service.stop()
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertNil(snapshot.token)
        XCTAssertEqual(snapshot.receipts.count, 1)
        XCTAssertEqual(transport.stopCount, 1)

        // Once stopped, a request that arrives on a stale connection is
        // refused rather than served with a discarded token.
        let after = await transport.deliver(request(.get, path: "/\(expectedToken)/"))
        XCTAssertEqual(after.status, 503)
    }

    func testDiscardRemovesOneFileAndDiscardAllEmptiesTheWorkspace() async throws {
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        for name in ["One.ipa", "Two.ipa"] {
            let file = try bodyFile(bytes: 4)
            _ = await transport.deliver(
                request(path: "/\(expectedToken)/upload/\(name)", contentLength: 4),
                body: .file(file, byteCount: 4)
            )
        }
        let before = await service.snapshot()
        XCTAssertEqual(before.receipts.count, 2)
        let first = try XCTUnwrap(before.receipts.first)
        let resolvedURL = await service.fileURL(for: first.id)
        XCTAssertNotNil(resolvedURL)

        _ = await service.discard(first.id)
        let middle = await service.snapshot()
        XCTAssertEqual(middle.receipts.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(first.fileName).path))

        _ = await service.discardAll()
        let empty = await service.snapshot()
        XCTAssertTrue(empty.receipts.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testWorkspaceFilesFromAnEarlierSessionAreReportedAgain() async throws {
        try Data(repeating: 0x42, count: 12).write(to: workspace.appendingPathComponent("Earlier.ipa"))
        try Data(repeating: 0x42, count: 3).write(to: workspace.appendingPathComponent("notes.txt"))
        let transport = LocalTransferTestTransport()
        let service = makeService(limits: limits(), transport: transport)
        _ = await service.start()
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.receipts.map { $0.fileName }, ["Earlier.ipa"])
        XCTAssertEqual(snapshot.receipts.first?.byteCount, 12)
    }

    func testUploadCommandMatchesThePage() throws {
        let command = LocalTransferStatusPage.uploadCommand(
            address: "http://192.168.1.10:8080",
            token: expectedToken,
            fileName: "App.ipa"
        )
        XCTAssertEqual(
            command,
            "curl --data-binary @App.ipa http://192.168.1.10:8080/\(expectedToken)/upload/App.ipa"
        )
        // A name that is not accepted is never interpolated into a command.
        let unsafe = LocalTransferStatusPage.uploadCommand(
            address: "http://192.168.1.10:8080",
            token: expectedToken,
            fileName: "App.ipa; rm -rf /"
        )
        XCTAssertEqual(unsafe, "curl --data-binary @App.ipa http://192.168.1.10:8080/\(expectedToken)/upload/App.ipa")
    }

    func testStatusPageEscapesInterpolatedValues() throws {
        XCTAssertEqual(LocalTransferStatusPage.escaped("<script>"), "&lt;script&gt;")
        XCTAssertEqual(LocalTransferStatusPage.escaped("a&b\"c'd"), "a&amp;b&quot;c&#39;d")
    }
}
