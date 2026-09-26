import Foundation

enum OpenAIImagineError: Error, Equatable {
    case missingKey
    case unauthorized
    case offline
    case timedOut
    case cancelled
    case badStatus(Int)
    case unreadableReply

    var message: String {
        switch self {
        case .missingKey: "Enter your OpenAI API key to use Imagine."
        case .unauthorized: "The OpenAI API key was rejected. Check it and try again."
        case .offline: "You're offline. Connect to the internet and try again."
        case .timedOut: "Imagine took too long. Try again."
        case .cancelled: "Generation cancelled."
        case .badStatus(let status): "OpenAI returned an error (\(status)). Try again."
        case .unreadableReply: "Imagine returned a plan I couldn't read. Try again."
        }
    }
}

/// Makes Imagine's explicit cloud request. No request is started by constructing this value;
/// `generate` may make one corrective request if the first plan fails local validation.
struct OpenAIImagineClient: ImagineGenerating {
    private let session: URLSession
    private let keys: any KeyProviding
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(session: URLSession = .shared, keys: any KeyProviding = KeychainStore()) {
        self.session = session
        self.keys = keys
    }

    func generate(_ input: ImagineRequest) async throws -> ImaginePlan {
        guard let key = try keys.apiKey(), !key.isEmpty else { throw OpenAIImagineError.missingKey }
        var correction: ImagineValidationError?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let plan = try await requestPlan(input, key: key, correction: correction)
            do {
                // The session checks the live document revision again immediately before applying.
                _ = try ImaginePlanValidator.validate(
                    plan, bodyCount: input.bodyCount, revision: input.revision,
                    currentRevision: input.revision, allowDelete: input.allowDelete
                )
                return plan
            } catch let error as ImagineValidationError {
                guard attempt == 0 else { throw error }
                correction = error
            }
        }
        throw OpenAIImagineError.unreadableReply
    }

    private func requestPlan(_ input: ImagineRequest, key: String,
                             correction: ImagineValidationError?) async throws -> ImaginePlan {
        let userText = """
        User request: \(input.prompt)
        Document units: \(input.units)
        Current design: \(input.designDescription)
        Selected body: \(input.selectedBody ?? "none")
        Sketch polylines (normalised 0…1): \(polylineJSON(input.polylines))
        Deletion explicitly requested: \(input.allowDelete)
        """
        let userContent: [[String: Any]] = [
            ["type": "text", "text": userText],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(input.sketchPNG.base64EncodedString())"]],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(input.designPNG.base64EncodedString())"]],
        ]
        var messages: [[String: Any]] = [
            ["role": "developer", "content": Self.systemPrompt],
            ["role": "user", "content": userContent],
        ]
        if let correction {
            messages.append(["role": "developer", "content": """
                The first plan was rejected: \(correction.message). Return a new complete JSON plan for the original request.
                A creation step (add_box, add_cylinder, extrude_profile) has no target. Every move, resize, rotate, round, add_hole or delete step must target an existing P-number or a name introduced by an earlier creation step. Do not invent a target or edit a part the user did not ask to change.
                """])
        }
        let body: [String: Any] = [
            "model": "gpt-6-sol",
            "stream": false,
            "max_completion_tokens": 8192,
            "reasoning_effort": correction == nil ? "low" : "medium",
            "response_format": ["type": "json_object"],
            "messages": messages,
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw OpenAIImagineError.unreadableReply }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw OpenAIImagineError.unauthorized
            default: throw OpenAIImagineError.badStatus(response.statusCode)
            }
            guard data.count <= 1_000_000,
                  let reply = try? JSONDecoder().decode(Completion.self, from: data),
                  let content = reply.choices.first?.message.content else { throw OpenAIImagineError.unreadableReply }
            do { return try ImaginePlan.decode(Data(content.utf8)) }
            catch { throw OpenAIImagineError.unreadableReply }
        } catch is CancellationError {
            throw OpenAIImagineError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw OpenAIImagineError.cancelled
            case .timedOut: throw OpenAIImagineError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                throw OpenAIImagineError.offline
            default: throw error
            }
        }
    }

    private func polylineJSON(_ lines: [[SIMD2<Float>]]) -> String {
        let coordinates = lines.map { $0.map { [Double($0.x), Double($0.y)] } }
        guard let data = try? JSONSerialization.data(withJSONObject: coordinates),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
    }

    private static let systemPrompt = """
    You are FoldForm Imagine, planning small, editable CAD changes. Return one JSON object only:
    {"assumptions":[{"name":"…","value":"…","unit":"…"}],"steps":[{"as":"optional_name","op":"add_box","args":{"width":30,"depth":4,"height":20,"unit":"mm"}}]}.
    At most 12 steps. Allowed ops: add_box, add_cylinder, extrude_profile, move, resize, rotate, round, add_hole, delete.
    Every length step must include a unit: mm, cm, m or in. Existing bodies are P0, P1, … as supplied. P0 is the base plate and must never be deleted. A created body may be referenced only by a prior step's as name. Add geometry to the current document; preserve unrelated bodies. Delete only when the user explicitly asked for deletion.
    A new rectangle is new geometry: use add_box or extrude_profile, never a move or resize of the base plate. A creation step has no target. If dimensions were not specified, choose modest dimensions in the document units and list them in assumptions.
    add_box requires width, depth, height. add_cylinder requires radius or diameter and height. extrude_profile requires outline as [[x,y],…] and depth; its coordinates are in the declared unit. move uses x, y, z world offsets. resize uses axis, mode (set or add), value. rotate uses axis, angle and optional unit. round uses radius. add_hole uses diameter. Every edit and deletion needs a top-level target alongside op and args, for example {"op":"move","target":"P1","args":{"x":10,"unit":"mm"}}. Use positive sizes and finite values.
    """
}
