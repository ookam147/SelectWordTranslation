import AppKit
import ApplicationServices
import OSLog

@MainActor
protocol TextSelectionProviding: AnyObject {
    func selectedText() async throws -> String
}

struct SourceApplicationSnapshot: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

@MainActor
protocol SourceApplicationProviding: AnyObject {
    func frontmostApplication() -> SourceApplicationSnapshot?
    func isFrontmost(_ application: SourceApplicationSnapshot) -> Bool
}

@MainActor
final class WorkspaceSourceApplicationProvider: SourceApplicationProviding {
    func frontmostApplication() -> SourceApplicationSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return SourceApplicationSnapshot(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    func isFrontmost(_ application: SourceApplicationSnapshot) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }
}

struct AccessibilitySelection: Equatable, Sendable {
    let text: String
    /// Web content (browsers, Electron) joins block elements without line breaks in its AX text,
    /// so a real copy is preferred there to keep paragraphs.
    var isWebContent = false
}

struct AccessibilitySelectionResolver<Element> {
    let selectedText: (Element) -> String?
    let selectedRangeText: (Element) -> String?
    let selectedMarkerText: (Element) -> String?
    let parent: (Element) -> Element?
    var isWebArea: (Element) -> Bool = { _ in false }
    var maximumDepth = 8

    func resolve(startingAt element: Element) -> AccessibilitySelection? {
        var current: Element? = element
        for _ in 0..<maximumDepth {
            guard let candidate = current else { break }
            if let text = nonempty(selectedText(candidate)) {
                return AccessibilitySelection(text: text, isWebContent: isWebArea(candidate))
            }
            if let text = nonempty(selectedRangeText(candidate)) {
                return AccessibilitySelection(text: text, isWebContent: isWebArea(candidate))
            }
            if let text = nonempty(selectedMarkerText(candidate)) {
                return AccessibilitySelection(text: text, isWebContent: true)
            }
            current = parent(candidate)
        }
        return nil
    }

    private func nonempty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

@MainActor
protocol AccessibilitySelectionReading: AnyObject {
    func selectedText(for application: SourceApplicationSnapshot) -> AccessibilitySelection?
}

@MainActor
final class SystemAccessibilitySelectionReader: AccessibilitySelectionReading {
    func selectedText(for application: SourceApplicationSnapshot) -> AccessibilitySelection? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let focusedElement = Self.elementAttribute(applicationElement, kAXFocusedUIElementAttribute)
            ?? focusedSystemElement(for: application.processIdentifier)
        guard let focusedElement else { return nil }

        let resolver = AccessibilitySelectionResolver<AXUIElement>(
            selectedText: Self.directSelectedText,
            selectedRangeText: Self.selectedRangeText,
            selectedMarkerText: Self.selectedMarkerText,
            parent: { Self.elementAttribute($0, kAXParentAttribute) },
            isWebArea: { Self.attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }
        )
        return resolver.resolve(startingAt: focusedElement)
    }

    private func focusedSystemElement(for expectedPID: pid_t) -> AXUIElement? {
        guard let element = Self.elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else {
            return nil
        }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == expectedPID else { return nil }
        return element
    }

    private static func directSelectedText(from element: AXUIElement) -> String? {
        attribute(element, kAXSelectedTextAttribute) as? String
    }

    private static func selectedRangeText(from element: AXUIElement) -> String? {
        guard let range = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        return parameterizedString(element, attribute: kAXStringForRangeParameterizedAttribute, parameter: range)
    }

    private static func selectedMarkerText(from element: AXUIElement) -> String? {
        guard let markerRange = attribute(element, kAXSelectedTextMarkerRangeAttribute) else { return nil }
        return parameterizedString(
            element,
            attribute: kAXStringForTextMarkerRangeParameterizedAttribute,
            parameter: markerRange
        )
    }

    private static func parameterizedString(
        _ element: AXUIElement,
        attribute: String,
        parameter: CFTypeRef
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

@MainActor
protocol SelectionCopyCommandSending: AnyObject {
    func sendCopy(to application: SourceApplicationSnapshot) async throws -> Bool
}

@MainActor
final class SystemSelectionCopyCommandSender: SelectionCopyCommandSending {
    private let sourceApplications: SourceApplicationProviding
    private static let blockingModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    init(sourceApplications: SourceApplicationProviding) {
        self.sourceApplications = sourceApplications
    }

    func sendCopy(to application: SourceApplicationSnapshot) async throws -> Bool {
        for _ in 0..<20 {
            let activeModifiers = CGEventSource.flagsState(.combinedSessionState).intersection(Self.blockingModifiers)
            if activeModifiers.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard sourceApplications.isFrontmost(application),
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

enum PasteboardSelectionParser {
    static func text(from pasteboard: NSPasteboard, sourceBundleIdentifier: String?) -> String? {
        if sourceBundleIdentifier == "com.apple.finder", let names = finderItemNames(from: pasteboard) {
            return names
        }
        if let text = plainText(from: pasteboard) { return text }
        if let text = attributedText(from: pasteboard, type: .rtf, documentType: .rtf) { return text }
        if let text = attributedText(from: pasteboard, type: .html, documentType: .html) { return text }
        return nil
    }

    private static func finderItemNames(from pasteboard: NSPasteboard) -> String? {
        let names = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value), url.isFileURL else { return nil }
            return nonempty(url.lastPathComponent)
        }
        return names.isEmpty ? nil : names.joined(separator: "\n")
    }

    private static func plainText(from pasteboard: NSPasteboard) -> String? {
        let values = (pasteboard.pasteboardItems ?? []).compactMap { nonempty($0.string(forType: .string)) }
        if !values.isEmpty { return values.joined(separator: "\n") }
        return nonempty(pasteboard.string(forType: .string))
    }

    private static func attributedText(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType,
        documentType: NSAttributedString.DocumentType
    ) -> String? {
        for item in pasteboard.pasteboardItems ?? [] {
            guard let data = item.data(forType: type),
                  let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: documentType],
                    documentAttributes: nil
                  ),
                  let text = nonempty(attributed.string) else { continue }
            return text
        }
        return nil
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

@MainActor
protocol ClipboardSelectionReading: AnyObject {
    func selectedText(for application: SourceApplicationSnapshot) async throws -> String?
}

@MainActor
final class ClipboardSelectionReader: ClipboardSelectionReading {
    private let pasteboard: NSPasteboard
    private let copyCommandSender: SelectionCopyCommandSending

    init(pasteboard: NSPasteboard = .general, copyCommandSender: SelectionCopyCommandSending) {
        self.pasteboard = pasteboard
        self.copyCommandSender = copyCommandSender
    }

    func selectedText(for application: SourceApplicationSnapshot) async throws -> String? {
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        let baselineChangeCount = pasteboard.changeCount

        do {
            guard try await copyCommandSender.sendCopy(to: application) else {
                _ = snapshot.restore(to: pasteboard, ifChangeCountIs: baselineChangeCount)
                return nil
            }

            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(30))
                try Task.checkCancellation()
                guard pasteboard.changeCount != baselineChangeCount else { continue }
                let copiedChangeCount = pasteboard.changeCount
                let text = PasteboardSelectionParser.text(
                    from: pasteboard,
                    sourceBundleIdentifier: application.bundleIdentifier
                )
                _ = snapshot.restore(to: pasteboard, ifChangeCountIs: copiedChangeCount)
                return text
            }

            _ = snapshot.restore(to: pasteboard, ifChangeCountIs: baselineChangeCount)
            return nil
        } catch {
            _ = snapshot.restore(to: pasteboard, ifChangeCountIs: baselineChangeCount)
            throw error
        }
    }
}

struct SelectionSettings: Equatable, Sendable {
    /// How long a clipboard write from the source app counts as a fresh copy. Zero disables it.
    var recentClipboardWindow: TimeInterval
    var cleansTerminalText: Bool

    static let `default` = SelectionSettings(recentClipboardWindow: 15, cleansTerminalText: true)
}

@MainActor
protocol RecentClipboardProviding: AnyObject {
    func recentText(copiedFrom application: SourceApplicationSnapshot, within window: TimeInterval) -> String?
    func beginIgnoringChanges()
    func endIgnoringChanges()
}

/// Tracks clipboard writes so text copied in the source app shortly before the shortcut
/// (for example with Ctrl+C inside a terminal TUI) can be used when no native selection exists.
@MainActor
final class PasteboardChangeMonitor: RecentClipboardProviding {
    /// Marks clipboard contents written by this app so they are never treated as a source-app copy.
    static let ownContentType = NSPasteboard.PasteboardType("com.zwalking.SelectWordTranslation.own")

    private struct Change {
        let changeCount: Int
        let date: Date
        let processIdentifier: pid_t?
    }

    private let pasteboard: NSPasteboard
    private let sourceApplications: SourceApplicationProviding
    private let now: () -> Date
    private var observedChangeCount: Int
    private var latestChange: Change?
    private var ignoreDepth = 0
    private var timer: Timer?

    init(
        pasteboard: NSPasteboard = .general,
        sourceApplications: SourceApplicationProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.sourceApplications = sourceApplications
        self.now = now
        observedChangeCount = pasteboard.changeCount
    }

    func start(interval: TimeInterval = 0.25) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != observedChangeCount else { return }
        observedChangeCount = changeCount
        guard ignoreDepth == 0, !(pasteboard.types ?? []).contains(Self.ownContentType) else {
            latestChange = nil
            return
        }
        latestChange = Change(
            changeCount: changeCount,
            date: now(),
            processIdentifier: sourceApplications.frontmostApplication()?.processIdentifier
        )
    }

    func recentText(copiedFrom application: SourceApplicationSnapshot, within window: TimeInterval) -> String? {
        poll()
        guard window > 0,
              let change = latestChange,
              change.changeCount == pasteboard.changeCount,
              change.processIdentifier == application.processIdentifier,
              now().timeIntervalSince(change.date) <= window else { return nil }
        return PasteboardSelectionParser.text(from: pasteboard, sourceBundleIdentifier: application.bundleIdentifier)
    }

    func beginIgnoringChanges() {
        poll()
        ignoreDepth += 1
    }

    func endIgnoringChanges() {
        poll()
        ignoreDepth = max(0, ignoreDepth - 1)
    }

    static func writeOwnText(_ text: String, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: ownContentType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}

@MainActor
final class TextSelectionManager: TextSelectionProviding {
    /// Apps whose Accessibility selection is authoritative. Synthesizing ⌘C there adds nothing
    /// and can be harmful: Ghostty only copies its own selection (already exposed through AX),
    /// and users may remap ⌘C to send input to the running terminal program.
    static let accessibilityOnlyBundleIdentifiers: Set<String> = ["com.mitchellh.ghostty"]

    private let logger = Logger(subsystem: "com.zwalking.SelectWordTranslation", category: "TextSelection")
    private let sourceApplications: SourceApplicationProviding
    private let accessibilityReader: AccessibilitySelectionReading
    private let clipboardReader: ClipboardSelectionReading
    private let recentClipboard: RecentClipboardProviding
    private let settings: () -> SelectionSettings
    private let isAccessibilityTrusted: () -> Bool

    convenience init(settings: @escaping () -> SelectionSettings = { .default }) {
        let sourceApplications = WorkspaceSourceApplicationProvider()
        let monitor = PasteboardChangeMonitor(sourceApplications: sourceApplications)
        monitor.start()
        self.init(
            sourceApplications: sourceApplications,
            accessibilityReader: SystemAccessibilitySelectionReader(),
            clipboardReader: ClipboardSelectionReader(
                copyCommandSender: SystemSelectionCopyCommandSender(sourceApplications: sourceApplications)
            ),
            recentClipboard: monitor,
            settings: settings,
            isAccessibilityTrusted: AXIsProcessTrusted
        )
    }

    init(
        sourceApplications: SourceApplicationProviding,
        accessibilityReader: AccessibilitySelectionReading,
        clipboardReader: ClipboardSelectionReading,
        recentClipboard: RecentClipboardProviding,
        settings: @escaping () -> SelectionSettings = { .default },
        isAccessibilityTrusted: @escaping () -> Bool
    ) {
        self.sourceApplications = sourceApplications
        self.accessibilityReader = accessibilityReader
        self.clipboardReader = clipboardReader
        self.recentClipboard = recentClipboard
        self.settings = settings
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    func selectedText() async throws -> String {
        guard let sourceApplication = sourceApplications.frontmostApplication() else {
            throw TranslationError.noSelection
        }
        let settings = settings()
        let text = try await rawSelectedText(from: sourceApplication, settings: settings)
        guard settings.cleansTerminalText, TerminalApplications.contains(sourceApplication.bundleIdentifier) else {
            return text
        }
        return SelectionTextNormalizer.normalizedTerminalText(text)
    }

    private func rawSelectedText(
        from sourceApplication: SourceApplicationSnapshot,
        settings: SelectionSettings
    ) async throws -> String {
        let bundleIdentifier = sourceApplication.bundleIdentifier ?? "unknown"
        let trusted = isAccessibilityTrusted()

        let canSendCopy = !Self.accessibilityOnlyBundleIdentifiers.contains(bundleIdentifier)
        if let selection = accessibilityReader.selectedText(for: sourceApplication), !selection.text.isEmpty {
            if selection.isWebContent, canSendCopy,
               let copied = try await copiedSelection(from: sourceApplication),
               !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.debug("Web selection read through clipboard from \(bundleIdentifier, privacy: .public)")
                return copied
            }
            logger.debug("Selection read through Accessibility from \(bundleIdentifier, privacy: .public)")
            return selection.text
        }
        let recentText = recentClipboard.recentText(
            copiedFrom: sourceApplication,
            within: settings.recentClipboardWindow
        )
        if canSendCopy,
           let text = try await copiedSelection(from: sourceApplication), !text.isEmpty {
            logger.debug("Selection read through clipboard from \(bundleIdentifier, privacy: .public)")
            return text
        }
        if let recentText, !recentText.isEmpty {
            logger.debug("Selection read from a recent clipboard write by \(bundleIdentifier, privacy: .public)")
            return recentText
        }
        if !trusted {
            logger.notice("Accessibility permission is unavailable for \(bundleIdentifier, privacy: .public)")
            promptForAccessibilityPermission()
            throw TranslationError.accessibilityPermissionRequired
        }
        logger.notice("No selection was exposed by \(bundleIdentifier, privacy: .public)")
        throw TranslationError.noSelection
    }

    private func copiedSelection(from application: SourceApplicationSnapshot) async throws -> String? {
        recentClipboard.beginIgnoringChanges()
        defer { recentClipboard.endIgnoringChanges() }
        return try await clipboardReader.selectedText(for: application)
    }

    private func promptForAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

@MainActor
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifChangeCountIs expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let restoredItems = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restoredItems)
        return true
    }
}
