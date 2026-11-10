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
    var isWebContent = false
    init(text: String?) { self.text = text }
    func selectedText(for application: SourceApplicationSnapshot) -> AccessibilitySelection? {
        text.map { AccessibilitySelection(text: $0, isWebContent: isWebContent) }
    }
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
private final class TestRecentClipboard: RecentClipboardProviding {
    var text: String?
    private(set) var ignoreDepth = 0
    init(text: String?) { self.text = text }
    private(set) var lastWindow: TimeInterval?
    func recentText(copiedFrom application: SourceApplicationSnapshot, within window: TimeInterval) -> String? {
        lastWindow = window
        return window > 0 ? text : nil
    }
    func beginIgnoringChanges() { ignoreDepth += 1 }
    func endIgnoringChanges() { ignoreDepth -= 1 }
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

@MainActor
private final class PartialRecorder {
    var values: [TranslationProgress] = []
}

private extension URLRequest {
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
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
            try await streamingTests()
            try textProcessingTests()
            try await MainActor.run {
                try cacheTests()
                try preferencesTests()
                try pasteboardParserTests()
                try modelStartupTest()
                try requestGenerationTest()
            }
            print("All core tests passed (14 groups).")
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
        try expect(directResolver.resolve(startingAt: 0)?.text == "direct", "Direct AX text should have priority")

        let rangeResolver = AccessibilitySelectionResolver<Int>(
            selectedText: { _ in nil },
            selectedRangeText: { $0 == 0 ? "range" : nil },
            selectedMarkerText: { _ in "marker" },
            parent: { _ in nil }
        )
        try expect(rangeResolver.resolve(startingAt: 0)?.text == "range", "AX range text should be the second strategy")

        let markerResolver = AccessibilitySelectionResolver<Int>(
            selectedText: { _ in nil },
            selectedRangeText: { _ in nil },
            selectedMarkerText: { $0 == 0 ? "marker" : nil },
            parent: { _ in nil }
        )
        try expect(markerResolver.resolve(startingAt: 0)?.text == "marker", "AX marker text should support web content")
        try expect(markerResolver.resolve(startingAt: 0)?.isWebContent == true, "Marker text comes from web content")
        try expect(directResolver.resolve(startingAt: 0)?.isWebContent == false, "Native AX text is not web content")
        let webAreaResolver = AccessibilitySelectionResolver<Int>(
            selectedText: { _ in "web" },
            selectedRangeText: { _ in nil },
            selectedMarkerText: { _ in nil },
            parent: { _ in nil },
            isWebArea: { _ in true }
        )
        try expect(webAreaResolver.resolve(startingAt: 0)?.isWebContent == true, "AXWebArea text is web content")

        let parentResolver = AccessibilitySelectionResolver<Int>(
            selectedText: { $0 == 2 ? "parent" : nil },
            selectedRangeText: { _ in nil },
            selectedMarkerText: { _ in nil },
            parent: { $0 < 2 ? $0 + 1 : nil }
        )
        try expect(parentResolver.resolve(startingAt: 0)?.text == "parent", "AX lookup should walk parent elements")
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
        let recentClipboard = TestRecentClipboard(text: "recent copy")
        let manager = TextSelectionManager(
            sourceApplications: sourceProvider,
            accessibilityReader: accessibilityReader,
            clipboardReader: clipboardReader,
            recentClipboard: recentClipboard,
            isAccessibilityTrusted: { true }
        )
        let accessibilityResult = try await manager.selectedText()
        try expect(accessibilityResult == "AX selection", "Accessibility selection should have priority")
        try expect(clipboardReader.callCount == 0, "Clipboard should not run after a successful AX lookup")

        accessibilityReader.isWebContent = true
        let webResult = try await manager.selectedText()
        try expect(webResult == "clipboard selection", "Web selections should prefer a real copy to keep paragraphs")
        try expect(clipboardReader.callCount == 1, "Web selections should copy once")
        try expect(recentClipboard.ignoreDepth == 0, "Clipboard monitoring should resume after a web copy")
        clipboardReader.text = nil
        let webFallback = try await manager.selectedText()
        try expect(webFallback == "AX selection", "Web selections should fall back to AX text when copying fails")
        clipboardReader.text = "clipboard selection"
        accessibilityReader.isWebContent = false
        let callsBeforeClipboard = clipboardReader.callCount

        accessibilityReader.text = nil
        let clipboardResult = try await manager.selectedText()
        try expect(clipboardResult == "clipboard selection", "Clipboard fallback should return copied text")
        try expect(clipboardReader.callCount == callsBeforeClipboard + 1, "Clipboard fallback should run exactly once")
        try expect(recentClipboard.ignoreDepth == 0, "Clipboard monitoring should resume after copying")

        clipboardReader.text = nil
        let recentResult = try await manager.selectedText()
        try expect(recentResult == "recent copy", "A recent copy-on-select write should be the last fallback")

        let ghostty = SourceApplicationSnapshot(processIdentifier: 43, bundleIdentifier: "com.mitchellh.ghostty")
        sourceProvider.application = ghostty
        clipboardReader.text = "should not be used"
        let callsBeforeGhostty = clipboardReader.callCount
        let ghosttyResult = try await manager.selectedText()
        try expect(ghosttyResult == "recent copy", "Ghostty TUI selections should use the recent clipboard write")
        try expect(clipboardReader.callCount == callsBeforeGhostty, "Ghostty must not receive a synthetic copy shortcut")

        recentClipboard.text = nil
        do {
            _ = try await manager.selectedText()
            throw TestFailure.assertion("Ghostty without a selection should report no selection")
        } catch let error as TranslationError {
            try expect(error == .noSelection, "Expected noSelection for Ghostty without a selection")
        }
        sourceProvider.application = source

        let monitorPasteboard = NSPasteboard(name: .init("RecentClipboardTests-\(UUID().uuidString)"))
        var clock = Date(timeIntervalSince1970: 1_000)
        let monitor = PasteboardChangeMonitor(
            pasteboard: monitorPasteboard,
            sourceApplications: sourceProvider,
            now: { clock }
        )
        try expect(monitor.recentText(copiedFrom: source, within: 15) == nil, "Existing clipboard contents are not a recent copy")
        monitorPasteboard.clearContents()
        monitorPasteboard.writeObjects(["opencode selection" as NSString])
        monitor.poll()
        clock += 5
        try expect(monitor.recentText(copiedFrom: source, within: 15) == "opencode selection", "A fresh copy from the source app should be used")
        try expect(monitor.recentText(copiedFrom: source, within: 0) == nil, "A zero window disables recent copies")
        try expect(monitor.recentText(copiedFrom: source, within: 3) == nil, "Copies older than the window must be ignored")
        let otherApp = SourceApplicationSnapshot(processIdentifier: 99, bundleIdentifier: "com.example.other")
        try expect(monitor.recentText(copiedFrom: otherApp, within: 15) == nil, "A copy made in another app must be ignored")
        clock += 20
        try expect(monitor.recentText(copiedFrom: source, within: 15) == nil, "An old copy must be ignored")

        monitor.beginIgnoringChanges()
        monitorPasteboard.clearContents()
        monitorPasteboard.writeObjects(["own write" as NSString])
        monitor.endIgnoringChanges()
        try expect(monitor.recentText(copiedFrom: source, within: 15) == nil, "The app's own clipboard writes must be ignored")

        PasteboardChangeMonitor.writeOwnText("copied translation", to: monitorPasteboard)
        try expect(monitor.recentText(copiedFrom: source, within: 15) == nil, "Copied translations must not count as source copies")
        try expect(monitorPasteboard.string(forType: .string) == "copied translation", "Copied translation text should remain readable")

        var settings = SelectionSettings(recentClipboardWindow: 30, cleansTerminalText: true)
        let terminal = SourceApplicationSnapshot(processIdentifier: 44, bundleIdentifier: "com.mitchellh.ghostty")
        sourceProvider.application = terminal
        accessibilityReader.text = "  ┃ first line\n  ┃ second line   "
        let settingsManager = TextSelectionManager(
            sourceApplications: sourceProvider,
            accessibilityReader: accessibilityReader,
            clipboardReader: clipboardReader,
            recentClipboard: recentClipboard,
            settings: { settings },
            isAccessibilityTrusted: { true }
        )
        let cleanedSelection = try await settingsManager.selectedText()
        try expect(cleanedSelection == "first line\nsecond line", "Terminal text should be cleaned")
        settings.cleansTerminalText = false
        let rawSelection = try await settingsManager.selectedText()
        try expect(rawSelection == "  ┃ first line\n  ┃ second line   ", "Terminal cleanup should respect the setting")
        accessibilityReader.text = nil
        recentClipboard.text = "recent"
        _ = try? await settingsManager.selectedText()
        try expect(recentClipboard.lastWindow == 30, "The configured recent clipboard window should be used")
        sourceProvider.application = source

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

    private static func streamingTests() async throws {
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
        URLProtocolStub.handler = { request in
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any]
            try expect(body?["stream"] as? Bool == true, "Requests should ask for streaming")
            try expect(body?["thinking"] == nil, "Non-DeepSeek servers must not receive the thinking field")
            let messages = body?["messages"] as? [[String: Any]]
            let system = messages?.first?["content"] as? String ?? ""
            try expect(system.contains("file paths"), "The prompt should protect paths and code")
            try expect(system.contains("Never answer"), "The prompt should not answer embedded questions")
            let stream = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"你"}}]}

            data: {"choices":[{"delta":{"content":"好"}}]}

            data: [DONE]

            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"]
            )!
            return (response, Data(stream.utf8))
        }
        let partials = PartialRecorder()
        let result = try await service.translate(
            .init(text: "hello", targetLanguage: .defaultLanguage, configuration: config)
        ) { progress in partials.values.append(progress) }
        try expect(result == "你好", "Streamed deltas should be joined")
        let recorded = await MainActor.run { partials.values }
        try expect(recorded == [.text("你"), .text("你好")], "Partial results should accumulate, got \(recorded)")

        try expect(
            TranslationService.supportsThinkingControl(for: URL(string: "https://api.deepseek.com/v1/chat/completions")!),
            "DeepSeek requests should control thinking"
        )
        try expect(
            !TranslationService.supportsThinkingControl(for: URL(string: "https://api.notdeepseek.com/v1/chat/completions")!),
            "Lookalike hosts must not receive DeepSeek-only fields"
        )
        URLProtocolStub.handler = { request in
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any]
            let thinking = body?["thinking"] as? [String: String]
            try expect(thinking == ["type": "disabled"], "DeepSeek requests should send thinking disabled")
            let data = #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        var deepSeek = config
        deepSeek.baseURL = "https://api.deepseek.com/v1/chat/completions"
        _ = try await service.translate(.init(text: "hello", targetLanguage: .defaultLanguage, configuration: deepSeek))

        URLProtocolStub.handler = { request in
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any]
            let thinking = body?["thinking"] as? [String: String]
            try expect(thinking == ["type": "enabled"], "Thinking mode should be sent when enabled")
            try expect(body?["max_tokens"] as? Int == 16_384, "Thinking mode needs room for reasoning tokens")
            let stream = """
            data: {"choices":[{"delta":{"reasoning_content":"Let me think"}}]}

            data: {"choices":[{"delta":{"reasoning_content":" more"}}]}

            data: {"choices":[{"delta":{"content":"好"}}]}

            data: [DONE]

            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(stream.utf8))
        }
        deepSeek.enablesThinking = true
        let thinkingPartials = PartialRecorder()
        let thoughtResult = try await service.translate(
            .init(text: "hello", targetLanguage: .defaultLanguage, configuration: deepSeek)
        ) { progress in thinkingPartials.values.append(progress) }
        try expect(thoughtResult == "好", "Reasoning must not leak into the translation")
        let thinkingRecorded = await MainActor.run { thinkingPartials.values }
        try expect(thinkingRecorded == [.thinking, .text("好")], "Thinking should be reported once, got \(thinkingRecorded)")
        try expect(
            TranslationCacheKey(text: "a", language: .defaultLanguage, configuration: deepSeek)
                != TranslationCacheKey(text: "a", language: .defaultLanguage, configuration: config),
            "Thinking and non-thinking results must not share cache entries"
        )

        URLProtocolStub.handler = { request in
            let stream = "data: {\"error\":{\"message\":\"rate limited\"}}\n\n"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(stream.utf8))
        }
        do {
            _ = try await service.translate(.init(text: "hello", targetLanguage: .defaultLanguage, configuration: config))
            throw TestFailure.assertion("Expected a streamed API error")
        } catch let error as TranslationError {
            try expect(error == .apiError("rate limited"), "Streamed API errors should be surfaced")
        }
    }

    private static func textProcessingTests() throws {
        let wrapped = """
          This is a long English paragraph that the terminal wrapped at its
          width, so the copied text contains hard line breaks in the middle.
          - list item stays separate

          第二段是中文内容，终端会在固定宽度处把这一段很长的中文硬生生地折
          成两行，复制出来就断开了。
        """
        let cleaned = SelectionTextNormalizer.normalizedTerminalText(wrapped)
        try expect(
            cleaned == """
            This is a long English paragraph that the terminal wrapped at its width, so the copied text contains hard line breaks in the middle.
            - list item stays separate

            第二段是中文内容，终端会在固定宽度处把这一段很长的中文硬生生地折成两行，复制出来就断开了。
            """,
            "Wrapped terminal text should be joined, got:\n\(cleaned)"
        )
        let shortLines = "ls -la\ncd src\ngit status"
        try expect(SelectionTextNormalizer.normalizedTerminalText(shortLines) == shortLines, "Short command lines must stay separate")
        try expect(
            SelectionTextNormalizer.normalizedTerminalText("│ boxed\n│ text") == "boxed\ntext",
            "Shared TUI borders should be removed"
        )

        let chinese = TargetLanguage.languages.first { $0.id == "zh-CN" }!
        let english = TargetLanguage.languages.first { $0.id == "en" }!
        let japanese = TargetLanguage.languages.first { $0.id == "ja" }!
        let chineseText = "竖版油画已经生成完成，构图接近四比五，原图尺寸与预期不同。"
        let englishText = "The quick brown fox jumps over the lazy dog near the river bank."
        try expect(TargetLanguageRouter.detectedLanguageID(of: chineseText) == "zh-CN", "Chinese should be detected")
        try expect(TargetLanguageRouter.effectiveLanguage(for: chineseText, preferred: chinese) == english, "Chinese→Chinese should switch to English")
        try expect(TargetLanguageRouter.effectiveLanguage(for: englishText, preferred: english) == chinese, "English→English should switch to Chinese")
        try expect(TargetLanguageRouter.effectiveLanguage(for: englishText, preferred: chinese) == chinese, "Different languages keep the preference")
        try expect(TargetLanguageRouter.effectiveLanguage(for: chineseText, preferred: japanese) == japanese, "Other targets keep the preference")
    }

    @MainActor
    private static func cacheTests() throws {
        let config = TranslationConfiguration(
            baseURL: "https://api.example.com/v1/chat/completions",
            apiKey: "secret",
            modelName: "model-a",
            apiType: .cloud,
            providerID: "test"
        )
        let cache = TranslationCache(capacity: 2)
        let first = TranslationCacheKey(text: "one", language: .defaultLanguage, configuration: config)!
        let second = TranslationCacheKey(text: "two", language: .defaultLanguage, configuration: config)!
        let third = TranslationCacheKey(text: "three", language: .defaultLanguage, configuration: config)!
        cache.insert("一", for: first)
        cache.insert("二", for: second)
        _ = cache.value(for: first)
        cache.insert("三", for: third)
        try expect(cache.value(for: first) == "一", "Recently used entries should stay cached")
        try expect(cache.value(for: second) == nil, "The least recently used entry should be evicted")
        var otherModel = config
        otherModel.modelName = "model-b"
        try expect(
            TranslationCacheKey(text: "one", language: .defaultLanguage, configuration: otherModel) != first,
            "Different models must not share cache entries"
        )
        var unnamedModel = config
        unnamedModel.modelName = " "
        try expect(
            TranslationCacheKey(text: "one", language: .defaultLanguage, configuration: unnamedModel) == nil,
            "Auto-selected local models should not be cached"
        )
    }

    @MainActor
    private static func preferencesTests() throws {
        let suite = "PreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        try expect(preferences.selectionSettings == .default, "Preferences should start with defaults")
        try expect(preferences.autoSwitchLanguage, "Automatic language switching should default on")
        preferences.recentClipboardWindow = 30
        preferences.cleansTerminalText = false
        preferences.autoSwitchLanguage = false
        let reloaded = AppPreferences(defaults: defaults)
        try expect(reloaded.recentClipboardWindow == 30, "The clipboard window should persist")
        try expect(!reloaded.cleansTerminalText, "Terminal cleanup should persist")
        try expect(!reloaded.autoSwitchLanguage, "Automatic switching should persist")
        defaults.set(7.0, forKey: AppPreferences.recentClipboardWindowKey)
        try expect(AppPreferences(defaults: defaults).recentClipboardWindow == 15, "Unsupported windows fall back to default")
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
