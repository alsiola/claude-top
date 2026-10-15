import Foundation
import Testing
@testable import ClaudeTopCore

@Suite struct DecisionTests {
    let thresholds = Thresholds()

    @Test func questionIsRed() {
        let result = StopDecision.decide(
            probabilities: ["question": 0.88, "blocked": 0.04, "review": 0.05, "done": 0.03],
            thresholds: thresholds
        )
        #expect(result.state == .attention)
        #expect(result.reason == "Asks a question")
    }

    @Test func blockedIsRedWithBlockedReason() {
        let result = StopDecision.decide(
            probabilities: ["question": 0.2, "blocked": 0.6, "review": 0.1, "done": 0.1],
            thresholds: thresholds
        )
        #expect(result.state == .attention)
        #expect(result.reason == "Blocked")
    }

    @Test func questionAndBlockedAddUpToRed() {
        let result = StopDecision.decide(
            probabilities: ["question": 0.3, "blocked": 0.25, "review": 0.25, "done": 0.2],
            thresholds: thresholds
        )
        #expect(result.state == .attention)
    }

    @Test func reviewIsAmber() {
        let result = StopDecision.decide(
            probabilities: ["question": 0.05, "blocked": 0.0, "review": 0.8, "done": 0.15],
            thresholds: thresholds
        )
        #expect(result.state == .review)
        #expect(result.reason == "Ready for review")
    }

    @Test func splitBetweenRedAndAmberGoesToAmberNotGreen() {
        let result = StopDecision.decide(
            probabilities: ["question": 0.3, "blocked": 0.0, "review": 0.3, "done": 0.4],
            thresholds: thresholds
        )
        #expect(result.state == .review)
    }

    @Test func doneIsGreen() {
        let result = StopDecision.decide(
            probabilities: ["question": 0.1, "blocked": 0.0, "review": 0.2, "done": 0.7],
            thresholds: thresholds
        )
        #expect(result.state == .idle)
        #expect(result.reason == "Done")
    }

    @Test func thresholdsAreUsed() {
        let strict = Thresholds(red: 0.9, amber: 0.9)
        let result = StopDecision.decide(
            probabilities: ["question": 0.6, "review": 0.2, "done": 0.2],
            thresholds: strict
        )
        #expect(result.state == .idle)
    }

    @Test func offlineRule() {
        #expect(OfflineRule.classify("Do you want me to merge it?").state == .attention)
        #expect(OfflineRule.classify("I changed three files.").state == .review)
        #expect(OfflineRule.classify("").state == .review)
        let questionFarFromEnd = "Why? " + String(repeating: "x", count: 400)
        #expect(OfflineRule.classify(questionFarFromEnd).state == .review)
        #expect(OfflineRule.classify("x").offline)
    }

    @Test func longMessageKeepsTheEnd() {
        let message = String(repeating: "a", count: 5_000) + "END?"
        let input = StopInput(message: message, project: "p", backgroundTaskCount: 0)
        #expect(input.truncatedMessage.count == StopInput.messageLimit)
        #expect(input.truncatedMessage.hasSuffix("END?"))
    }
}

private struct FixedClassifier: StopClassifier {
    var result: Result<Classification, Error>
    var delaySeconds: Double = 0

    func classify(_ input: StopInput) async throws -> Classification {
        if delaySeconds > 0 { try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1e9)) }
        return try result.get()
    }
}

@Suite struct ChainTests {
    let input = StopInput(message: "Shall I continue?", project: "p", backgroundTaskCount: 0)

    @Test func usesPrimaryResult() async {
        let chain = StopClassifierChain(primary: FixedClassifier(result: .success(
            Classification(state: .idle, reason: "Done")
        )))
        let (result, error) = await chain.classify(input)
        #expect(result.state == .idle)
        #expect(error == nil)
    }

    @Test func noPrimaryUsesOfflineRule() async {
        let (result, error) = await StopClassifierChain(primary: nil).classify(input)
        #expect(result.state == .attention)
        #expect(result.offline)
        #expect(error == nil)
    }

    @Test func errorUsesOfflineRule() async {
        let chain = StopClassifierChain(primary: FixedClassifier(result: .failure(JevError(description: "HTTP 500"))))
        let (result, error) = await chain.classify(input)
        #expect(result.offline)
        #expect(error != nil)
    }

    @Test func timeoutUsesOfflineRule() async {
        let chain = StopClassifierChain(
            primary: FixedClassifier(result: .success(Classification(state: .idle, reason: "Done")), delaySeconds: 2),
            timeoutSeconds: 0.1
        )
        let (result, error) = await chain.classify(input)
        #expect(result.offline)
        #expect(error is TimeoutError)
    }
}

@Suite struct JevTests {
    @Test func parsesProbabilitiesAndCost() throws {
        let data = Data("""
        {"id":"x","answers":{"outcome":{"type":"choice","choice":"question","confidence":0.81,
        "probabilities":{"question":0.88,"blocked":0.04,"review":0.05,"done":0.03}}},
        "usage":{"cost":0.00004}}
        """.utf8)
        let parsed = try JevClassifier.parse(data)
        #expect(parsed.probabilities["question"] == 0.88)
        #expect(parsed.cost == 0.00004)
    }

    @Test func choiceOnlyResponseCountsAsCertain() throws {
        let data = Data(#"{"answers":{"outcome":{"type":"choice","choice":"review"}}}"#.utf8)
        #expect(try JevClassifier.parse(data).probabilities == ["review": 1])
    }

    @Test func badResponsesThrow() {
        #expect(throws: (any Error).self) { try JevClassifier.parse(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try JevClassifier.parse(Data(#"{"answers":{}}"#.utf8)) }
        #expect(throws: (any Error).self) {
            try JevClassifier.parse(Data(#"{"answers":{"outcome":{"type":"choice"}}}"#.utf8))
        }
    }

    @Test func requestShape() throws {
        let classifier = JevClassifier(apiKey: "sk-test", model: "typesafe/jev-1.14", thresholds: Thresholds())
        let input = StopInput(message: "Hi?", project: "proj", backgroundTaskCount: 2)
        let request = try classifier.makeRequest(input)
        #expect(request.url == JevClassifier.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "typesafe/jev-1.14")
        let state = try #require(body["state"] as? [String: String])
        #expect(state == ["project": "proj", "background_tasks": "2", "last_assistant_message": "Hi?"])
        let questions = try #require(body["questions"] as? [String: Any])
        let outcome = try #require(questions["outcome"] as? [String: Any])
        #expect(outcome["type"] as? String == "choice")
        let criteria = try #require(outcome["criteria"] as? [String: String])
        #expect(Set(criteria.keys) == ["question", "blocked", "review", "done"])
    }
}

@Suite struct EnvelopeTests {
    @Test func decodesHelperEnvelope() throws {
        let data = Data("""
        {"v":1,"ts_ms":1792065600123,
         "payload":{"session_id":"abc","hook_event_name":"Stop","cwd":"/x/y","last_assistant_message":"Done.",
                    "background_tasks":[{"id":1},{"id":2}],"stop_hook_active":false,"effort":{"level":"high"}},
         "context":{"ppid":10,"claude_pid":9,"term_program":"iTerm.app","iterm_session_id":"w0t1p0:AB-CD"}}
        """.utf8)
        let envelope = try Envelope.decode(data)
        #expect(envelope.tsMs == 1_792_065_600_123)
        #expect(envelope.payload.sessionID == "abc")
        #expect(envelope.payload.backgroundTaskCount == 2)
        #expect(envelope.context?.claudePID == 9)
        #expect(envelope.context?.itermSessionID == "w0t1p0:AB-CD")
    }

    @Test func unexpectedFieldTypesDoNotLoseTheEvent() throws {
        let data = Data(#"{"v":1,"ts_ms":1,"payload":{"session_id":"abc","hook_event_name":"Stop","message":42,"background_tasks":"many"}}"#.utf8)
        let envelope = try Envelope.decode(data)
        #expect(envelope.payload.hookEventName == "Stop")
        #expect(envelope.payload.message == nil)
        #expect(envelope.payload.backgroundTaskCount == nil)
    }
}
