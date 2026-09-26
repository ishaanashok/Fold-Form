import XCTest
@testable import FoldForm

private struct TestKeys: KeyProviding {
    var key: String?
    func apiKey() throws -> String? { key }
}

private final class NIMURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, NIMURLProtocol) -> Void)?
    nonisolated(unsafe) static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() { Self.onStop?() }
    func reply(status: Int = 200, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NIMURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class NIMClientTests: XCTestCase {
    private var request: ImagineRequest {
        ImagineRequest(prompt: "Make a bracket", sketchPNG: Data([1, 2, 3]), polylines: [[[0, 0], [1, 1]]], designPNG: Data([4, 5, 6]), designDescription: "P0 plate, P1 body", selectedBody: "P1", units: "mm", revision: 7, allowDelete: false)
    }
    private var reply: Data {
        Data(#"{"choices":[{"message":{"content":"{\"assumptions\":[],\"steps\":[]}"}}]}"#.utf8)
    }
    override func tearDown() {
        NIMURLProtocol.handler = nil
        NIMURLProtocol.onStop = nil
    }

    func testRequestUsesHTTPSBearerAndImageContentWithoutPuttingKeyInBody() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        let reply = reply
        NIMURLProtocol.handler = { request, stub in captured.mutate { $0 = request }; stub.reply(data: reply) }
        let client = NIMClient(session: NIMURLProtocol.session(), keys: TestKeys(key: "test-token"))
        let plan = try await client.generate(request)
        XCTAssertTrue(plan.steps.isEmpty)
        let sent = try XCTUnwrap(captured.value)
        XCTAssertEqual(sent.url?.absoluteString, "https://integrate.api.nvidia.com/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try XCTUnwrap(Self.bodyData(sent))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-token"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "z-ai/glm-5.3-flash")
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let user = try XCTUnwrap(messages.last)
        let content = try XCTUnwrap(user["content"] as? [[String: Any]])
        XCTAssertTrue(content.contains { ($0["text"] as? String)?.contains("Make a bracket") == true })
        let imageURLs = content.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        XCTAssertTrue(imageURLs.contains { $0.hasPrefix("data:image/png;base64,") })
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        let calls = LockedBox(0)
        NIMURLProtocol.handler = { _, _ in calls.mutate { $0 += 1 } }
        do {
            _ = try await NIMClient(session: NIMURLProtocol.session(), keys: TestKeys(key: nil)).generate(request)
            XCTFail("missing key should fail")
        } catch let error as NIMError {
            XCTAssertEqual(error, .missingKey)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(calls.value, 0)
    }

    func testUnauthorizedOfflineAndTimeoutHaveUsefulErrors() async {
        let unauthorizedReply = reply
        NIMURLProtocol.handler = { _, stub in stub.reply(status: 401, data: unauthorizedReply) }
        await expect(.unauthorized)
        NIMURLProtocol.handler = { _, stub in stub.fail(URLError(.notConnectedToInternet)) }
        await expect(.offline)
        NIMURLProtocol.handler = { _, stub in stub.fail(URLError(.timedOut)) }
        await expect(.timedOut)
    }

    private func expect(_ expected: NIMError) async {
        do {
            _ = try await NIMClient(session: NIMURLProtocol.session(), keys: TestKeys(key: "test-token")).generate(request)
            XCTFail("request should fail")
        } catch let error as NIMError {
            XCTAssertEqual(error, expected)
        } catch { XCTFail("\(error)") }
    }

    func testCancelStopsTheUnderlyingRequest() async {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request stopped")
        NIMURLProtocol.handler = { _, _ in started.fulfill() }
        NIMURLProtocol.onStop = { stopped.fulfill() }
        let client = NIMClient(session: NIMURLProtocol.session(), keys: TestKeys(key: "test-token"))
        let input = request
        let task = Task { try await client.generate(input) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        _ = try? await task.value
    }

    func testKeychainRoundTripWhenAvailable() throws {
        let store = KeychainStore(account: "FoldFormTests-\(UUID().uuidString)")
        do {
            try store.save("test-token")
            XCTAssertEqual(try store.apiKey(), "test-token")
            try store.delete()
            XCTAssertNil(try store.apiKey())
        } catch {
            throw XCTSkip("Keychain unavailable in this test host: \(error)")
        }
    }
}
