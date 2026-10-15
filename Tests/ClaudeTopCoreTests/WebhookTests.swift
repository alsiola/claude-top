import Foundation
import Testing
@testable import ClaudeTopCore

@Suite struct WebhookTests {
    private func session(_ id: String, _ state: SessionState, cwd: String = "/x/proj") -> Session {
        var session = Session(id: id, state: state)
        session.cwd = cwd
        return session
    }

    private func body(_ message: WebhookMessage) throws -> [String: Any] {
        let config = WebhookConfig(url: URL(string: "http://ha.local/api/webhook/abc")!)
        let request = try WebhookClient(config: config).makeRequest(message)
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func diffFindsStateChangesNewAndEndedSessions() {
        let old = ["a": session("a", .working), "b": session("b", .review), "c": session("c", .idle)]
        let new = ["a": session("a", .attention), "c": session("c", .idle), "d": session("d", .idle)]
        let events = WebhookEvent.diff(from: old, to: new, oldLight: .amber, newLight: .red)
        #expect(events == [
            .sessionChanged(WebhookSession(new["a"]!), previous: .working),
            .sessionEnded(WebhookSession(old["b"]!)),
            .sessionChanged(WebhookSession(new["d"]!), previous: nil),
            .lightChanged(previous: .amber),
        ])
    }

    @Test func diffIgnoresReasonOnlyChanges() {
        var a = session("a", .attention)
        a.reason = "Permission: Bash"
        var b = a
        b.reason = "Needs input"
        #expect(WebhookEvent.diff(from: ["a": a], to: ["a": b], oldLight: .red, newLight: .red).isEmpty)
    }

    @Test func lightChangedBody() throws {
        let message = WebhookMessage(
            event: .lightChanged(previous: .green),
            timestamp: Date(timeIntervalSince1970: 0),
            light: .red, red: 1, amber: 2
        )
        let json = try body(message)
        #expect(json["type"] as? String == "light.changed")
        #expect(json["light"] as? String == "red")
        #expect(json["previous"] as? String == "green")
        #expect(json["red"] as? Int == 1)
        #expect(json["amber"] as? Int == 2)
        #expect(json["timestamp"] as? String == "1970-01-01T00:00:00Z")
        #expect(json["session"] == nil)
    }

    @Test func sessionChangedBody() throws {
        var s = session("abc", .attention, cwd: "/x/api-server")
        s.reason = "Permission: Bash"
        let message = WebhookMessage(
            event: .sessionChanged(WebhookSession(s), previous: nil),
            timestamp: Date(), light: .red, red: 1, amber: 0
        )
        let json = try body(message)
        #expect(json["type"] as? String == "session.changed")
        #expect(json["previous"] is NSNull)
        let payload = try #require(json["session"] as? [String: Any])
        #expect(payload["id"] as? String == "abc")
        #expect(payload["project"] as? String == "api-server")
        #expect(payload["cwd"] as? String == "/x/api-server")
        #expect(payload["state"] as? String == "attention")
        #expect(payload["color"] as? String == "red")
        #expect(payload["reason"] as? String == "Permission: Bash")
    }

    @Test func testEventHasOnlyCommonFields() throws {
        let json = try body(WebhookMessage(event: .test, timestamp: Date(), light: .green, red: 0, amber: 0))
        #expect(Set(json.keys) == ["type", "timestamp", "light", "red", "amber"])
        #expect(json["type"] as? String == "test")
    }

    @Test func requestHasMethodAndHeaders() throws {
        let config = try WebhookConfig(
            url: " https://example.com/hook ",
            headers: "Authorization: Bearer a:b\n\n  X-Extra :  1 "
        )
        let request = try WebhookClient(config: config).makeRequest(
            WebhookMessage(event: .test, timestamp: Date(), light: .off, red: 0, amber: 0)
        )
        #expect(request.url?.absoluteString == "https://example.com/hook")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a:b")
        #expect(request.value(forHTTPHeaderField: "X-Extra") == "1")
    }

    @Test func configRejectsBadInput() {
        #expect(throws: WebhookError.self) { try WebhookConfig(url: "homeassistant.local", headers: "") }
        #expect(throws: WebhookError.self) { try WebhookConfig(url: "ftp://x/y", headers: "") }
        #expect(throws: WebhookError.self) { try WebhookConfig(url: "http://x", headers: "no colon") }
        #expect(throws: WebhookError.self) { try WebhookConfig(url: "http://x", headers: ": value") }
    }

    @Test func offlineErrorPointsToLocalNetworkSetting() {
        let message = WebhookClient.explain(URLError(.notConnectedToInternet)).description
        #expect(message.contains("Privacy & Security > Local Network"))
        #expect(!WebhookClient.explain(URLError(.cannotConnectToHost)).description.contains("Local Network"))
    }

    @Test func headersTextRoundTrips() throws {
        let headers = try WebhookConfig.parseHeaders("A: 1\nB: two words")
        let config = WebhookConfig(url: URL(string: "http://x")!, headers: headers)
        #expect(try WebhookConfig.parseHeaders(config.headersText) == headers)
    }
}
