import XCTest
@testable import FoldForm

final class MoonshineIntegrationTests: XCTestCase {
    func testBadModelHashStopsBeforeMicrophoneStarts() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoonshineIntegration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.handler = { _ in (200, Data("wrong model".utf8)) }
        let manifest = ModelManifest(id: "test-moonshine", files: [
            .init(name: "model.ort", url: URL(string: "https://example.com/model.ort")!, sha256: String(repeating: "0", count: 64))
        ])
        let store = ModelStore(root: root, session: StubURLProtocol.session())
        let speech = MoonshineSpeechService(store: store, manifest: manifest)
        await speech.start()
        var events = speech.events.makeAsyncIterator()
        let firstEvent = await events.next()
        XCTAssertEqual(firstEvent, .state(.downloading(0)))
        guard case .state(.unavailable(let reason)) = await events.next() else { return XCTFail("bad hash must refuse speech") }
        XCTAssertTrue(reason.contains("model"))
        XCTAssertFalse(store.isInstalled(manifest))
    }
}
