import Foundation

public struct JevError: Error, CustomStringConvertible {
    public let description: String
}

public struct JevClassifier: StopClassifier {
    public static let endpoint = URL(string: "https://openrouter.ai/api/alpha/decisions")!
    public static let defaultModel = "~typesafe/jev-latest"

    public var apiKey: String
    public var model: String
    public var thresholds: Thresholds
    public var session: URLSession

    public init(apiKey: String, model: String, thresholds: Thresholds, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.thresholds = thresholds
        self.session = session
    }

    public func classify(_ input: StopInput) async throws -> Classification {
        let request = try makeRequest(input)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw JevError(description: "HTTP \(http.statusCode): \(body)")
        }
        let parsed = try Self.parse(data)
        var result = StopDecision.decide(probabilities: parsed.probabilities, thresholds: thresholds)
        result.cost = parsed.cost
        return result
    }

    public func makeRequest(_ input: StopInput) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Claude Top", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model, input: input))
        return request
    }

    public static func body(model: String, input: StopInput) -> [String: Any] {
        var criteria: [String: String] = [:]
        criteria[StopOutcome.question.rawValue] =
            "The message asks the user a question, or asks the user to choose, decide, or approve something before the agent continues."
        criteria[StopOutcome.blocked.rawValue] =
            "The agent cannot continue because of an error, missing access, missing credentials, or missing information, and the user must fix it."
        criteria[StopOutcome.review.rawValue] =
            "In this turn the agent finished a change (code, files, a pull request, a deploy, or a document), and the result is ready now for the user to review, test, or merge."
        criteria[StopOutcome.done.rawValue] =
            "No result is ready for the user now. The message answers a question, reports status or progress, explains a plan, or says that work continues elsewhere (for example in another agent or in the background) and that the agent will report later. Optional offers such as 'let me know if you want more' do not count as a question."
        return [
            "model": model,
            "state": [
                "project": input.project,
                "background_tasks": String(input.backgroundTaskCount),
                "last_assistant_message": input.truncatedMessage,
            ],
            "questions": [
                "outcome": [
                    "type": "choice",
                    "instructions": "An AI coding agent ended its turn with this message. Pick the label that best describes what the user must do now.",
                    "criteria": criteria,
                ],
            ],
        ]
    }

    public struct Parsed: Equatable {
        public var probabilities: [String: Double]
        public var cost: Double?
    }

    public static func parse(_ data: Data) throws -> Parsed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let outcome = answers["outcome"] as? [String: Any]
        else { throw JevError(description: "The response has no answers.outcome") }

        var probabilities: [String: Double] = [:]
        if let raw = outcome["probabilities"] as? [String: Any] {
            for (key, value) in raw {
                if let number = value as? NSNumber { probabilities[key] = number.doubleValue }
            }
        }
        if probabilities.isEmpty, let choice = outcome["choice"] as? String {
            probabilities[choice] = 1
        }
        guard !probabilities.isEmpty else {
            throw JevError(description: "The response has no probabilities and no choice")
        }
        let cost = ((root["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue
        return Parsed(probabilities: probabilities, cost: cost)
    }
}
