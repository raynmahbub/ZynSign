import Combine
import Foundation
import SwiftUI

/// The local transfer screen's model.
///
/// **What it enforces on the interface's behalf:**
///
/// - Nothing listens until the user starts a session, and the button that
///   starts one is disabled while it is starting.
/// - The screen shows the state the service reports, not the state the user
///   just asked for: a failed start reads as failed, with the sentence the
///   failure carried.
/// - The token is shown only while a session is open, and the upload command
///   is built from the address and token actually in use.
/// - Removing a received file asks the service to delete it and re-reads the
///   snapshot; the row disappears only once the service says it did.
@MainActor
final class LocalTransferModel: ObservableObject {

    /// One received file, with the URL the share sheet needs.
    struct ReceivedFile: Identifiable, Equatable {
        let id: UUID
        let name: String
        let formattedSize: String
        let url: URL
    }

    /// What the screen shows.
    enum Phase: Equatable {
        /// Nothing is listening.
        case stopped
        /// A session is opening.
        case starting
        /// A session is open at this address until this moment.
        case listening(address: String, expiresAt: Date)
        /// A session tried to open and could not.
        case failed(String)
    }

    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var received: [ReceivedFile] = []
    @Published private(set) var token: String?
    @Published private(set) var requestCount = 0
    @Published private(set) var rejectionCount = 0
    @Published private(set) var isBusy = false
    @Published private(set) var notice: String?

    private let service: LocalTransferService
    private let port: UInt16

    init(service: LocalTransferService, port: UInt16 = LocalTransferService.defaultPort) {
        self.service = service
        self.port = port
    }

    /// The command a person runs on another machine, once a session is open.
    var uploadCommand: String? {
        guard let token, case .listening(let address, _) = phase else { return nil }
        return LocalTransferStatusPage.uploadCommand(
            address: address,
            token: token,
            fileName: "App.ipa"
        )
    }

    /// The extensions a transfer accepts, for the screen's explanation.
    var acceptedExtensions: String {
        LocalTransferFileName.acceptedExtensions.joined(separator: ", ")
    }

    /// Reads the service's current state. Safe to call when nothing is
    /// listening: it reports `stopped` and keeps the files already received.
    func refresh() async {
        await apply(await service.snapshot())
    }

    /// Opens a session.
    func start() async {
        guard !isBusy else { return }
        isBusy = true
        phase = .starting
        notice = nil
        defer { isBusy = false }
        await apply(await service.start(port: port))
        if case .failed(let message) = phase {
            notice = message
        }
    }

    /// Closes the session and discards its token.
    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await service.stop()
        await apply(await service.snapshot())
        notice = "Stopped listening. Files already received stay in the workspace."
    }

    /// Removes one received file.
    func discard(_ file: ReceivedFile) async {
        await apply(await service.discard(file.id))
    }

    /// Removes every received file.
    func discardAll() async {
        await apply(await service.discardAll())
    }

    /// Clears the transient notice after the screen has shown it.
    func clearNotice() {
        notice = nil
    }

    /// Re-reads the service's snapshot and rebuilds the rows.
    private func apply(_ snapshot: LocalTransferService.Snapshot) async {
        switch snapshot.state {
        case .stopped:
            phase = .stopped
            token = nil
        case .starting:
            phase = .starting
            token = nil
        case .listening(let endpoint, let expiresAt):
            phase = .listening(address: endpoint.addressDescription, expiresAt: expiresAt)
            token = snapshot.token
        case .failed(let message):
            phase = .failed(message)
            token = nil
        }
        requestCount = snapshot.requestCount
        rejectionCount = snapshot.rejectionCount
        var files: [ReceivedFile] = []
        for receipt in snapshot.receipts {
            guard let url = await service.fileURL(for: receipt.id) else { continue }
            files.append(
                ReceivedFile(
                    id: receipt.id,
                    name: receipt.fileName,
                    formattedSize: receipt.formattedByteCount,
                    url: url
                )
            )
        }
        received = files
    }
}
