import Foundation
@testable import ZynSign

enum StoreFixtures {
    static let url = URL(string: "https://source.example/catalog.json")!
    static let manifest = Data("""
    {
      "name": "Independent Shelf", "identifier": "example.shelf", "featuredApps": ["org.example.orbit"],
      "iconURL": "https://source.example/icon.png",
      "apps": [{
        "name": "Orbit", "bundleIdentifier": "org.example.orbit", "developerName": "Mira Labs",
        "category": "Development", "localizedDescription": "A useful tool.",
        "screenshotURLs": {"iphone": ["https://source.example/phone.png"], "ipad": ["https://source.example/pad.png"]},
        "versions": [
          {"version": "2.3", "date": "2026-09-20", "downloadURL": "https://source.example/orbit.ipa", "size": 12000, "minOSVersion": "17.0", "localizedDescription": "A better orbit."},
          {"version": "2.2", "date": "2026-09-10T12:00:00Z", "downloadURL": "https://source.example/old.ipa"}
        ]
      }]
    }
    """.utf8)
    static func source(id: UUID = UUID()) throws -> CatalogSource {
        try StoreManifestValidator().parse(manifest, sourceID: id, url: url)
    }
    static func changed(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func changedApp(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        try changed { object in
            var apps = object["apps"] as! [[String: Any]]
            edit(&apps[0]); object["apps"] = apps
        }
    }
}
final class StoreMemoryStorage: StorePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var state = StoreSnapshot()
    var rejectSaves = false // configured before use in tests
    func load() throws -> StoreSnapshot { lock.lock(); defer { lock.unlock() }; return state }
    func save(_ snapshot: StoreSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectSaves { throw StoreFailure.invalid("Synthetic disk full") }
        state = snapshot
    }
}
actor StoreStubClient: StoreFetching {
    var responses: [Result<StoreHTTPResponse, Error>]
    private(set) var requests: [(URL, String?, String?)] = []
    init(_ responses: [Result<StoreHTTPResponse, Error>]) { self.responses = responses }
    static func ok(_ data: Data = StoreFixtures.manifest, status: Int = 200) -> Result<StoreHTTPResponse, Error> {
        .success(StoreHTTPResponse(data: data, status: status, etag: "test-tag", modified: "test-date"))
    }
    func fetch(_ url: URL, etag: String?, modified: String?, limit: Int) async throws -> StoreHTTPResponse {
        requests.append((url, etag, modified))
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return try responses.removeFirst().get()
    }
}
