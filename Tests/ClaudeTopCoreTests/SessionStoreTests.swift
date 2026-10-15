import Testing
@testable import ClaudeTopCore

private func event(
    _ name: String,
    at ts: Int64,
    session: String = "s1",
    notification: String? = nil,
    tool: String? = nil,
    message: String? = nil,
    agent: String? = nil,
    source: String? = nil,
    pid: Int32? = nil
) -> Envelope {
    Envelope(
        tsMs: ts,
        payload: HookPayload(
            sessionID: session,
            hookEventName: name,
            cwd: "/Users/me/Code/project-\(session)",
            notificationType: notification,
            toolName: tool,
            lastAssistantMessage: message,
            source: source,
            agentID: agent
        ),
        context: pid.map { HookContext(claudePID: $0) }
    )
}

@Suite struct SessionStoreTests {
    @Test func startIsIdleAndPromptIsWorking() {
        var store = SessionStore()
        store.apply(event("SessionStart", at: 1, source: "startup"))
        #expect(store.sessions["s1"]?.state == .idle)
        #expect(store.light == .green)
        store.apply(event("UserPromptSubmit", at: 2))
        #expect(store.sessions["s1"]?.state == .working)
        #expect(store.sessions["s1"]?.project == "project-s1")
    }

    @Test func noSessionsMeansOff() {
        #expect(SessionStore().light == .off)
    }

    @Test func permissionRequestIsRedUntilToolRuns() {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 1))
        store.apply(event("PreToolUse", at: 2, tool: "Bash"))
        store.apply(event("PermissionRequest", at: 3, tool: "Bash"))
        #expect(store.sessions["s1"]?.state == .attention)
        #expect(store.sessions["s1"]?.reason == "Permission: Bash")
        #expect(store.light == .red)

        store.apply(event("Notification", at: 4, notification: "permission_prompt"))
        #expect(store.sessions["s1"]?.reason == "Permission: Bash")

        store.apply(event("PostToolUse", at: 5, tool: "Bash"))
        #expect(store.sessions["s1"]?.state == .working)
        #expect(store.light == .green)
    }

    @Test(arguments: ["elicitation_dialog", "elicitation_url_dialog", "agent_needs_input", "permission_prompt"])
    func notificationsThatNeedInput(type: String) {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 1))
        store.apply(event("Notification", at: 2, notification: type))
        #expect(store.sessions["s1"]?.state == .attention)
    }

    @Test(arguments: ["idle_prompt", "auth_success", "agent_completed"])
    func notificationsThatDoNotChangeState(type: String) {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 1))
        store.apply(event("Notification", at: 2, notification: type))
        #expect(store.sessions["s1"]?.state == .working)
    }

    @Test func stopAsksForClassificationAndKeepsStateUntilResult() throws {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 1))
        let requestResult = store.apply(event("Stop", at: 2, message: "All done."))
        let request = try #require(requestResult)
        #expect(request.input.message == "All done.")
        #expect(request.input.project == "project-s1")
        #expect(store.sessions["s1"]?.state == .working)
        #expect(store.sessions["s1"]?.classifying == true)

        let applied = store.applyClassification(request, Classification(state: .review, reason: "Ready for review"))
        #expect(applied)
        #expect(store.sessions["s1"]?.state == .review)
        #expect(store.light == .amber)
    }

    @Test func lateClassificationIsIgnoredAfterNewEvent() throws {
        var store = SessionStore()
        let requestResult = store.apply(event("Stop", at: 2, message: "Which one?"))
        let request = try #require(requestResult)
        store.apply(event("UserPromptSubmit", at: 3))
        let applied = store.applyClassification(request, Classification(state: .attention, reason: "Asks a question"))
        #expect(!applied)
        #expect(store.sessions["s1"]?.state == .working)
    }

    @Test func notificationDuringClassificationDoesNotCancelIt() throws {
        var store = SessionStore()
        let result = store.apply(event("Stop", at: 2, message: "Done."))
        let request = try #require(result)
        store.apply(event("Notification", at: 3, notification: "agent_completed"))
        let applied = store.applyClassification(request, Classification(state: .review, reason: "Ready for review"))
        #expect(applied)
        #expect(store.sessions["s1"]?.state == .review)
    }

    @Test func dismissCancelsClassification() throws {
        var store = SessionStore()
        let result = store.apply(event("Stop", at: 2, message: "Done."))
        let request = try #require(result)
        store.dismiss("s1")
        let applied = store.applyClassification(request, Classification(state: .review, reason: "Ready for review"))
        #expect(!applied)
        #expect(store.sessions["s1"]?.state == .idle)
    }

    @Test func olderEventIsIgnored() {
        var store = SessionStore()
        store.apply(event("PermissionRequest", at: 10, tool: "Edit"))
        store.apply(event("PreToolUse", at: 9, tool: "Edit"))
        #expect(store.sessions["s1"]?.state == .attention)
    }

    @Test func subagentActivityDoesNotClearRedOrAmber() throws {
        var store = SessionStore()
        store.apply(event("PermissionRequest", at: 1, tool: "Bash"))
        store.apply(event("PreToolUse", at: 2, tool: "Read", agent: "sub-1"))
        store.apply(event("PostToolUse", at: 3, tool: "Read", agent: "sub-1"))
        #expect(store.sessions["s1"]?.state == .attention)

        let requestResult = store.apply(event("Stop", at: 4, message: "Done"))
        let request = try #require(requestResult)
        store.applyClassification(request, Classification(state: .review, reason: "Ready for review"))
        store.apply(event("PreToolUse", at: 5, tool: "Bash", agent: "background-1"))
        #expect(store.sessions["s1"]?.state == .review)
    }

    @Test func subagentStopDoesNotClassify() {
        var store = SessionStore()
        let request = store.apply(event("Stop", at: 1, agent: "sub-1"))
        #expect(request == nil)
    }

    @Test func subagentPermissionRequestIsRed() {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 1))
        store.apply(event("PermissionRequest", at: 2, tool: "Bash", agent: "sub-1"))
        #expect(store.sessions["s1"]?.state == .attention)
    }

    @Test func stopFailureIsRed() {
        var store = SessionStore()
        store.apply(event("StopFailure", at: 1))
        #expect(store.sessions["s1"]?.state == .attention)
    }

    @Test func compactStartKeepsState() {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 1))
        store.apply(event("SessionStart", at: 2, source: "compact"))
        #expect(store.sessions["s1"]?.state == .working)
    }

    @Test func sessionEndRemoves() {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 1))
        store.apply(event("SessionEnd", at: 2))
        #expect(store.sessions.isEmpty)
    }

    @Test func redBeatsAmberBeatsGreen() throws {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 1, session: "a"))
        let stopResult = store.apply(event("Stop", at: 2, session: "b"))
        let stop = try #require(stopResult)
        store.applyClassification(stop, Classification(state: .review, reason: "Ready for review"))
        #expect(store.light == .amber)
        store.apply(event("PermissionRequest", at: 3, session: "c", tool: "Bash"))
        #expect(store.light == .red)
        #expect(store.count(.attention) == 1)
        #expect(store.count(.review) == 1)
    }

    @Test func sortPutsRedThenAmberLongestWaitFirst() throws {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 50, session: "working"))
        store.apply(event("PermissionRequest", at: 20, session: "red-new", tool: "Bash"))
        store.apply(event("PermissionRequest", at: 10, session: "red-old", tool: "Bash"))
        let stopResult = store.apply(event("Stop", at: 5, session: "amber"))
        let stop = try #require(stopResult)
        store.applyClassification(stop, Classification(state: .review, reason: "Ready for review"))
        #expect(store.sorted.map(\.id) == ["red-old", "red-new", "amber", "working"])
    }

    @Test func dismissClearsToIdle() {
        var store = SessionStore()
        store.apply(event("PermissionRequest", at: 1, tool: "Bash"))
        store.dismiss("s1")
        #expect(store.sessions["s1"]?.state == .idle)
        #expect(store.light == .green)
    }

    @Test func pruneRemovesDeadAndStaleSessions() {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", at: 1_000, session: "alive", pid: 100))
        store.apply(event("UserPromptSubmit", at: 1_000, session: "dead", pid: 200))
        store.apply(event("UserPromptSubmit", at: 1_000, session: "no-pid-stale"))
        store.apply(event("UserPromptSubmit", at: 9_000, session: "no-pid-fresh"))
        let removed = store.prune(nowMs: 10_000, maxIdleMs: 5_000) { $0 == 100 }
        #expect(Set(removed) == ["dead", "no-pid-stale"])
        #expect(Set(store.sessions.keys) == ["alive", "no-pid-fresh"])
    }

    @Test func eventWithoutSessionIDIsIgnored() {
        var store = SessionStore()
        let envelope = Envelope(tsMs: 1, payload: HookPayload(sessionID: nil, hookEventName: "Stop"))
        let request = store.apply(envelope)
        #expect(request == nil)
        #expect(store.sessions.isEmpty)
    }
}
