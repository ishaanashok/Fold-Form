import XCTest
import CryptoKit
@testable import FoldForm

/// A URLProtocol that serves canned responses, so no test touches the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

final class ModelStoreTests: XCTestCase {
    private var root: URL!
    private let payload = Data((0..<200_000).map { UInt8($0 % 251) })
    private var payloadHash: String { SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ModelStoreTests-\(UUID().uuidString)")
        StubURLProtocol.requests = []
        StubURLProtocol.handler = { [payload] _ in (200, payload) }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func manifest(hash overrideHash: String? = nil, url: String = "https://example.com/model.bin") -> ModelManifest {
        ModelManifest(id: "test-model", files: [.init(name: "model.bin", url: URL(string: url)!, sha256: overrideHash ?? payloadHash)])
    }
    private func store() -> ModelStore { ModelStore(root: root, session: StubURLProtocol.session()) }

    func testDownloadsVerifiesAndInstalls() async throws {
        let store = store()
        let manifest = manifest()
        XCTAssertFalse(store.isInstalled(manifest))
        try await store.install(manifest)
        XCTAssertTrue(store.isInstalled(manifest))
        XCTAssertEqual(try Data(contentsOf: store.directory(for: manifest).appendingPathComponent("model.bin")), payload)
    }

    func testAWrongHashInstallsNothing() async throws {
        let store = store()
        let manifest = manifest(hash: String(repeating: "0", count: 64))
        do {
            try await store.install(manifest)
            XCTFail("should have refused")
        } catch let error as ModelStoreError {
            XCTAssertEqual(error, .hashMismatch("model.bin"))
        }
        XCTAssertFalse(store.isInstalled(manifest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: manifest).path), "no partial install left behind")
    }

    func testInstallingTwiceDownloadsOnce() async throws {
        let store = store()
        let manifest = manifest()
        try await store.install(manifest)
        try await store.install(manifest)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testPlainHTTPIsRefusedBeforeAnyRequest() async {
        let store = store()
        do {
            try await store.install(manifest(url: "http://example.com/model.bin"))
            XCTFail("should have refused")
        } catch let error as ModelStoreError {
            XCTAssertEqual(error, .insecureURL)
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAServerErrorIsReportedAndInstallsNothing() async {
        StubURLProtocol.handler = { _ in (404, Data()) }
        let store = store()
        let manifest = manifest()
        do {
            try await store.install(manifest)
            XCTFail("should have failed")
        } catch let error as ModelStoreError {
            XCTAssertEqual(error, .http(404))
        } catch { XCTFail("\(error)") }
        XCTAssertFalse(store.isInstalled(manifest))
    }

    func testProgressRisesToOne() async throws {
        let store = store()
        let collected = LockedBox<[Double]>([])
        try await store.install(manifest()) { value in collected.mutate { $0.append(value) } }
        let values = collected.value
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values, values.sorted(), "monotonic")
        XCTAssertEqual(values.last ?? 0, 1, accuracy: 1e-9)
    }

    func testRemoveUninstalls() async throws {
        let store = store()
        let manifest = manifest()
        try await store.install(manifest)
        store.remove(manifest)
        XCTAssertFalse(store.isInstalled(manifest))
    }

    func testAFileDeletedFromDiskIsNoLongerInstalled() async throws {
        let store = store()
        let manifest = manifest()
        try await store.install(manifest)
        try FileManager.default.removeItem(at: store.directory(for: manifest).appendingPathComponent("model.bin"))
        XCTAssertFalse(store.isInstalled(manifest))
    }
}
