import ClaudeTopCore
import Foundation
import Security

// Runs the Jev classifier on labeled Stop messages and prints the result for each.
// Usage: swift run claude-top-eval [fixtures.json]
// The API key comes from OPENROUTER_API_KEY, or else from the app's Keychain item.

struct Fixture: Decodable {
    var expected: String
    var message: String
}

func keychainKey() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ClaudeTop",
        kSecAttrAccount as String: "openrouter-api-key",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures/stop-messages.json"
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
guard let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? keychainKey(), !apiKey.isEmpty else {
    FileHandle.standardError.write(Data("No API key. Set OPENROUTER_API_KEY, or save a key in Claude Top Settings.\n".utf8))
    exit(1)
}
let model = ProcessInfo.processInfo.environment["JEV_MODEL"] ?? JevClassifier.defaultModel
let classifier = JevClassifier(apiKey: apiKey, model: model, thresholds: Thresholds())

var passed = 0
var cost = 0.0
for (index, fixture) in fixtures.enumerated() {
    let input = StopInput(message: fixture.message, project: "eval", backgroundTaskCount: 0)
    let request = try classifier.makeRequest(input)
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            print("#\(index + 1) HTTP \(http.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
            continue
        }
        let parsed = try JevClassifier.parse(data)
        cost += parsed.cost ?? 0
        let result = StopDecision.decide(probabilities: parsed.probabilities, thresholds: Thresholds())
        let ok = result.state.rawValue == fixture.expected
        if ok { passed += 1 }
        let probabilities = StopOutcome.allCases
            .map { "\($0.rawValue)=\(String(format: "%.2f", parsed.probabilities[$0.rawValue] ?? 0))" }
            .joined(separator: " ")
        let preview = fixture.message.replacingOccurrences(of: "\n", with: " ").prefix(70)
        print("\(ok ? "PASS" : "FAIL") #\(index + 1) expected=\(fixture.expected) got=\(result.state.rawValue)  \(probabilities)  \"\(preview)…\"")
    } catch {
        print("#\(index + 1) error: \(error)")
    }
}
print("\n\(passed)/\(fixtures.count) correct, model \(model), cost $\(String(format: "%.5f", cost))")
