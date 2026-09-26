import XCTest
@testable import FoldForm

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

private struct TestKeys: KeyProviding {
    var key: String?
    func apiKey() throws -> String? { key }
}

private final class OpenAIURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, OpenAIURLProtocol) -> Void)?
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
        configuration.protocolClasses = [OpenAIURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class OpenAIImagineClientTests: XCTestCase {
    private var request: ImagineRequest {
        ImagineRequest(prompt: "Make a bracket", sketchPNG: Data([1, 2, 3]), polylines: [[[0, 0], [1, 1]]], designPNG: Data([4, 5, 6]), designDescription: "P0 plate, P1 body", selectedBody: "P1", bodyCount: 2, units: "mm", revision: 7, allowDelete: false)
    }
    private var reply: Data {
        Data(#"{"choices":[{"message":{"content":"{\"assumptions\":[],\"steps\":[]}"}}]}"#.utf8)
    }
    private func completion(_ plan: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": plan]]]])
    }
    override func tearDown() {
        OpenAIURLProtocol.handler = nil
        OpenAIURLProtocol.onStop = nil
    }

    func testRequestUsesHTTPSBearerAndImageContentWithoutPuttingKeyInBody() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        let reply = reply
        OpenAIURLProtocol.handler = { request, stub in captured.mutate { $0 = request }; stub.reply(data: reply) }
        let client = OpenAIImagineClient(session: OpenAIURLProtocol.session(), keys: TestKeys(key: "test-token"))
        let plan = try await client.generate(request)
        XCTAssertTrue(plan.steps.isEmpty)
        let sent = try XCTUnwrap(captured.value)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try XCTUnwrap(Self.bodyData(sent))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-token"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-6-sol")
        XCTAssertEqual(object["max_completion_tokens"] as? Int, 8192)
        XCTAssertNil(object["temperature"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "developer")
        let instructions = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(instructions.contains("A new rectangle is new geometry"))
        XCTAssertTrue(instructions.contains("top-level target"))
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
        OpenAIURLProtocol.handler = { _, _ in calls.mutate { $0 += 1 } }
        do {
            _ = try await OpenAIImagineClient(session: OpenAIURLProtocol.session(), keys: TestKeys(key: nil)).generate(request)
            XCTFail("missing key should fail")
        } catch let error as OpenAIImagineError {
            XCTAssertEqual(error, .missingKey)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(calls.value, 0)
    }

    func testMissingTargetPlanGetsOneCorrectionBeforeApplyingAnyPlan() async throws {
        let requests = LockedBox<[URLRequest]>([])
        let invalid = completion(#"{"steps":[{"op":"move","args":{"x":10,"unit":"mm"}}]}"#)
        let corrected = completion(#"{"steps":[{"as":"Rectangle","op":"add_box","args":{"width":30,"depth":4,"height":20,"unit":"mm"}}]}"#)
        OpenAIURLProtocol.handler = { request, stub in
            requests.mutate { $0.append(request) }
            stub.reply(data: requests.value.count == 1 ? invalid : corrected)
        }
        var input = request
        input.prompt = "Give me a rectangle"
        input.selectedBody = nil
        input.designDescription = "P0 base plate"
        input.bodyCount = 1
        let client = OpenAIImagineClient(session: OpenAIURLProtocol.session(), keys: TestKeys(key: "test-token"))

        let plan = try await client.generate(input)

        XCTAssertEqual(plan.steps.map(\.op), ["add_box"])
        XCTAssertEqual(requests.value.count, 2)
        let repairRequest = try XCTUnwrap(requests.value.dropFirst().first)
        let repairBody = try XCTUnwrap(Self.bodyData(repairRequest))
        XCTAssertTrue(String(decoding: repairBody, as: UTF8.self).contains("Missing target"))
        XCTAssertFalse(String(decoding: repairBody, as: UTF8.self).contains("test-token"))
        let repairObject = try XCTUnwrap(JSONSerialization.jsonObject(with: repairBody) as? [String: Any])
        XCTAssertEqual(repairObject["reasoning_effort"] as? String, "medium")
    }

    func testUnrepairedMissingTargetStopsAfterOneCorrection() async {
        let count = LockedBox(0)
        let invalid = completion(#"{"steps":[{"op":"move","args":{"x":10,"unit":"mm"}}]}"#)
        OpenAIURLProtocol.handler = { _, stub in
            count.mutate { $0 += 1 }
            stub.reply(data: invalid)
        }
        let client = OpenAIImagineClient(session: OpenAIURLProtocol.session(), keys: TestKeys(key: "test-token"))

        do {
            _ = try await client.generate(request)
            XCTFail("an invalid plan must not be accepted")
        } catch let error as ImagineValidationError {
            XCTAssertEqual(error, .missing("target"))
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(count.value, 2)
    }

    func testUnauthorizedOfflineAndTimeoutHaveUsefulErrors() async {
        let unauthorizedReply = reply
        OpenAIURLProtocol.handler = { _, stub in stub.reply(status: 401, data: unauthorizedReply) }
        await expect(.unauthorized)
        OpenAIURLProtocol.handler = { _, stub in stub.fail(URLError(.notConnectedToInternet)) }
        await expect(.offline)
        OpenAIURLProtocol.handler = { _, stub in stub.fail(URLError(.timedOut)) }
        await expect(.timedOut)
    }

    private func expect(_ expected: OpenAIImagineError) async {
        do {
            _ = try await OpenAIImagineClient(session: OpenAIURLProtocol.session(), keys: TestKeys(key: "test-token")).generate(request)
            XCTFail("request should fail")
        } catch let error as OpenAIImagineError {
            XCTAssertEqual(error, expected)
        } catch { XCTFail("\(error)") }
    }

    func testCancelStopsTheUnderlyingRequest() async {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request stopped")
        OpenAIURLProtocol.handler = { _, _ in started.fulfill() }
        OpenAIURLProtocol.onStop = { stopped.fulfill() }
        let client = OpenAIImagineClient(session: OpenAIURLProtocol.session(), keys: TestKeys(key: "test-token"))
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

    func testDefaultKeychainAccountIsOpenAIAndIsolatedFromTheOldProvider() {
        XCTAssertEqual(KeychainStore().account, "openai-imagine")
    }
}
