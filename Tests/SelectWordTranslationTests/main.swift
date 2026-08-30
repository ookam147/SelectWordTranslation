import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): message }
    }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure.assertion(message) }
}

private func expectError<T: Equatable & Error>(_ expected: T, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw TestFailure.assertion("Expected error \(expected)")
    } catch let error as T {
        try expect(error == expected, "Expected \(expected), got \(error)")
    }
}

private final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func apiKey(for account: String) throws -> String? { lock.withLock { values[account] } }
    func setAPIKey(_ apiKey: String, for account: String) throws { lock.withLock { values[account] = apiKey } }
    func removeAPIKey(for account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
private struct CoreTestRunner {
    static func main() async {
        do {
            try selectionTests()
            try endpointTests()
            try credentialMigrationTest()
            try await translationTests()
            try await MainActor.run {
                try modelStartupTest()
                try requestGenerationTest()
            }
            print("All core tests passed (6 groups).")
        } catch {
            fputs("Core tests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func selectionTests() throws {
        try expect(SelectionValidator.validated("  hello  ") == "hello", "Selection should be trimmed")
        try expectError(TranslationError.noSelection) { _ = try SelectionValidator.validated(" \n ") }
        let maximum = String(repeating: "a", count: SelectionValidator.maximumCharacterCount)
        try expect(SelectionValidator.validated(maximum) == maximum, "Maximum-length selection should pass")
        try expectError(TranslationError.selectionTooLong) { _ = try SelectionValidator.validated(maximum + "a") }
    }

    private static func endpointTests() throws {
        let remote = try APIEndpointValidator.validatedChatURL(from: "https://api.example.com/v1/chat/completions")
        try expect(try APIEndpointValidator.modelsURL(from: remote).absoluteString == "https://api.example.com/v1/models", "Models URL derivation failed")
        _ = try APIEndpointValidator.validatedChatURL(from: "http://127.0.0.1:1234/v1/chat/completions")
        try expectError(TranslationError.insecureRemoteURL) {
            _ = try APIEndpointValidator.validatedChatURL(from: "http://api.example.com/v1/chat/completions")
        }
    }

    private static func credentialMigrationTest() throws {
        let suite = "CredentialMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-secret", forKey: "apiKey")
        let store = MemoryCredentialStore()
        let config = TranslationConfiguration(
            baseURL: APIPreset.builtInPresets[0].baseURL,
            apiKey: "",
            modelName: "deepseek-chat",
            apiType: .cloud,
            providerID: "deepseek"
        )
        CredentialMigrator.migrateIfNeeded(defaults: defaults, store: store, configuration: config, presets: APIPreset.builtInPresets)
        try expect(try store.apiKey(for: "deepseek") == "legacy-secret", "Legacy key was not migrated")
        try expect(defaults.string(forKey: "apiKey") == nil, "Legacy plaintext key was not removed")
    }

    private static func translationTests() async throws {
        URLProtocolStub.handler = { request in
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret", "Authorization header missing")
            let data = #"{"choices":[{"message":{"role":"assistant","content":"你好"}}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = TranslationService(session: URLSession(configuration: configuration))
        let config = TranslationConfiguration(
            baseURL: "https://api.example.com/v1/chat/completions",
            apiKey: "secret",
            modelName: "test-model",
            apiType: .cloud,
            providerID: "test"
        )
        let result = try await service.translate(.init(text: "hello", targetLanguage: .defaultLanguage, configuration: config))
        try expect(result == "你好", "Translation response was not decoded")

        URLProtocolStub.handler = { request in
            let data = #"{"error":{"message":"invalid model"}}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, data)
        }
        do {
            _ = try await service.translate(.init(text: "hello", targetLanguage: .defaultLanguage, configuration: config))
            throw TestFailure.assertion("Expected API error")
        } catch let error as TranslationError {
            try expect(error == .apiError("invalid model"), "Detailed API error was not retained")
        }
    }

    @MainActor
    private static func modelStartupTest() throws {
        let suite = "ModelStartupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ModelManager(defaults: defaults, credentials: MemoryCredentialStore())
        try expect(manager.connectionState == .notChecked, "Model manager should not perform startup network work")
    }

    @MainActor
    private static func requestGenerationTest() throws {
        let tracker = RequestTracker()
        let old = tracker.begin()
        let current = tracker.begin()
        try expect(!tracker.isCurrent(old), "An older request must become stale")
        try expect(tracker.isCurrent(current), "The newest request must remain current")
        tracker.finish(old)
        try expect(tracker.isCurrent(current), "An old result must not clear the current request")
        tracker.finish(current)
        try expect(tracker.activeID == nil, "The current request should clear on completion")
    }
}
