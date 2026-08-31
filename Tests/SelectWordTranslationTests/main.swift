import AppKit
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

@MainActor
private final class TestSourceApplicationProvider: SourceApplicationProviding {
    var application: SourceApplicationSnapshot?
    var frontmost = true

    init(application: SourceApplicationSnapshot?) { self.application = application }
    func frontmostApplication() -> SourceApplicationSnapshot? { application }
    func isFrontmost(_ application: SourceApplicationSnapshot) -> Bool { frontmost }
}

@MainActor
private final class TestAccessibilityReader: AccessibilitySelectionReading {
    var text: String?
    init(text: String?) { self.text = text }
    func selectedText(for application: SourceApplicationSnapshot) -> String? { text }
}

@MainActor
private final class TestClipboardReader: ClipboardSelectionReading {
    var text: String?
    private(set) var callCount = 0
    init(text: String?) { self.text = text }
    func selectedText(for application: SourceApplicationSnapshot) async throws -> String? {
        callCount += 1
        return text
    }
}

@MainActor
private final class TestCopyCommandSender: SelectionCopyCommandSending {
    let operation: @MainActor (SourceApplicationSnapshot) async throws -> Bool
    init(operation: @escaping @MainActor (SourceApplicationSnapshot) async throws -> Bool) {
        self.operation = operation
    }
    func sendCopy(to application: SourceApplicationSnapshot) async throws -> Bool {
        try await operation(application)
    }
}

@main
private struct CoreTestRunner {
    static func main() async {
        do {
            try selectionTests()
            try accessibilityResolverTests()
            try endpointTests()
            try credentialMigrationTest()
            try await translationTests()
            try await selectionCompatibilityTests()
            try await MainActor.run {
                try pasteboardParserTests()
                try modelStartupTest()
                try requestGenerationTest()
            }
            print("All core tests passed (10 groups).")
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

    private static func accessibilityResolverTests() throws {
        let directResolver = AccessibilitySelectionResolver<Int>(
            selectedText: { $0 == 0 ? "direct" : nil },
            selectedRangeText: { _ in "range" },
            selectedMarkerText: { _ in "marker" },
            parent: { _ in nil }
        )
        try expect(directResolver.resolve(startingAt: 0) == "direct", "Direct AX text should have priority")

        let rangeResolver = AccessibilitySelectionResolver<Int>(
            selectedText: { _ in nil },
            selectedRangeText: { $0 == 0 ? "range" : nil },
            selectedMarkerText: { _ in "marker" },
            parent: { _ in nil }
        )
        try expect(rangeResolver.resolve(startingAt: 0) == "range", "AX range text should be the second strategy")

        let markerResolver = AccessibilitySelectionResolver<Int>(
            selectedText: { _ in nil },
            selectedRangeText: { _ in nil },
            selectedMarkerText: { $0 == 0 ? "marker" : nil },
            parent: { _ in nil }
        )
        try expect(markerResolver.resolve(startingAt: 0) == "marker", "AX marker text should support web content")

        let parentResolver = AccessibilitySelectionResolver<Int>(
            selectedText: { $0 == 2 ? "parent" : nil },
            selectedRangeText: { _ in nil },
            selectedMarkerText: { _ in nil },
            parent: { $0 < 2 ? $0 + 1 : nil }
        )
        try expect(parentResolver.resolve(startingAt: 0) == "parent", "AX lookup should walk parent elements")
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
    private static func selectionCompatibilityTests() async throws {
        let source = SourceApplicationSnapshot(processIdentifier: 42, bundleIdentifier: "com.tencent.xinWeChat")
        let sourceProvider = TestSourceApplicationProvider(application: source)
        let accessibilityReader = TestAccessibilityReader(text: "AX selection")
        let clipboardReader = TestClipboardReader(text: "clipboard selection")
        let manager = TextSelectionManager(
            sourceApplications: sourceProvider,
            accessibilityReader: accessibilityReader,
            clipboardReader: clipboardReader,
            isAccessibilityTrusted: { true }
        )
        let accessibilityResult = try await manager.selectedText()
        try expect(accessibilityResult == "AX selection", "Accessibility selection should have priority")
        try expect(clipboardReader.callCount == 0, "Clipboard should not run after a successful AX lookup")

        accessibilityReader.text = nil
        let clipboardResult = try await manager.selectedText()
        try expect(clipboardResult == "clipboard selection", "Clipboard fallback should return copied text")
        try expect(clipboardReader.callCount == 1, "Clipboard fallback should run exactly once")

        let pasteboard = NSPasteboard(name: .init("SelectionDelayTests-\(UUID().uuidString)"))
        let customType = NSPasteboard.PasteboardType("com.zwalking.tests.custom")
        let originalItem = NSPasteboardItem()
        originalItem.setString("original", forType: .string)
        originalItem.setData(Data([1, 2, 3]), forType: customType)
        pasteboard.clearContents()
        pasteboard.writeObjects([originalItem])

        let delayedSender = TestCopyCommandSender { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                pasteboard.clearContents()
                pasteboard.writeObjects(["微信延迟复制" as NSString])
            }
            return true
        }
        let delayedReader = ClipboardSelectionReader(pasteboard: pasteboard, copyCommandSender: delayedSender)
        let delayedResult = try await delayedReader.selectedText(for: source)
        try expect(delayedResult == "微信延迟复制", "Clipboard reader should wait for delayed app copies")
        try expect(pasteboard.string(forType: .string) == "original", "Original clipboard text should be restored")
        try expect(pasteboard.data(forType: customType) == Data([1, 2, 3]), "All clipboard data types should be restored")

        let cancellationSender = TestCopyCommandSender { _ in true }
        let cancellationReader = ClipboardSelectionReader(pasteboard: pasteboard, copyCommandSender: cancellationSender)
        let cancellationTask = Task { try await cancellationReader.selectedText(for: source) }
        try await Task.sleep(for: .milliseconds(90))
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            throw TestFailure.assertion("Cancelled clipboard lookup should throw")
        } catch is CancellationError {}
        try expect(pasteboard.string(forType: .string) == "original", "Cancellation should restore the clipboard")

        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        let ownedChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.writeObjects(["user change" as NSString])
        try expect(
            !snapshot.restore(to: pasteboard, ifChangeCountIs: ownedChangeCount),
            "A later user clipboard change must not be overwritten"
        )
        try expect(pasteboard.string(forType: .string) == "user change", "The user's clipboard change should remain")
    }

    @MainActor
    private static func pasteboardParserTests() throws {
        let pasteboard = NSPasteboard(name: .init("SelectionParserTests-\(UUID().uuidString)"))
        let firstFile = NSPasteboardItem()
        firstFile.setString(URL(fileURLWithPath: "/private/tmp/年度报告.pdf").absoluteString, forType: .fileURL)
        firstFile.setString("file:///private/tmp/年度报告.pdf", forType: .string)
        let secondFile = NSPasteboardItem()
        secondFile.setString(URL(fileURLWithPath: "/private/tmp/资料文件夹").absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects([firstFile, secondFile])
        try expect(
            PasteboardSelectionParser.text(from: pasteboard, sourceBundleIdentifier: "com.apple.finder")
                == "年度报告.pdf\n资料文件夹",
            "Finder file URLs should become names without full paths"
        )

        pasteboard.clearContents()
        pasteboard.writeObjects(["plain text" as NSString])
        try expect(
            PasteboardSelectionParser.text(from: pasteboard, sourceBundleIdentifier: "com.tencent.xinWeChat") == "plain text",
            "Plain text parsing failed"
        )

        let rtfItem = NSPasteboardItem()
        let rtf = try NSAttributedString(string: "rich text").data(
            from: NSRange(location: 0, length: 9),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        rtfItem.setData(rtf, forType: .rtf)
        pasteboard.clearContents()
        pasteboard.writeObjects([rtfItem])
        try expect(
            PasteboardSelectionParser.text(from: pasteboard, sourceBundleIdentifier: nil) == "rich text",
            "RTF parsing failed"
        )

        let htmlItem = NSPasteboardItem()
        htmlItem.setData(Data("<b>HTML text</b>".utf8), forType: .html)
        pasteboard.clearContents()
        pasteboard.writeObjects([htmlItem])
        try expect(
            PasteboardSelectionParser.text(from: pasteboard, sourceBundleIdentifier: nil) == "HTML text",
            "HTML parsing failed"
        )
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
