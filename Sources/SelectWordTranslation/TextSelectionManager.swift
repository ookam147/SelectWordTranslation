import AppKit
import ApplicationServices

@MainActor
protocol TextSelectionProviding: AnyObject {
    func selectedText() async throws -> String
}

@MainActor
final class TextSelectionManager: TextSelectionProviding {
    func selectedText() async throws -> String {
        let trusted = AXIsProcessTrusted()
        if let text = selectedTextViaAccessibility(), !text.isEmpty { return text }
        if let text = await selectedTextViaClipboard(), !text.isEmpty { return text }
        if !trusted {
            promptForAccessibilityPermission()
            throw TranslationError.accessibilityPermissionRequired
        }
        throw TranslationError.noSelection
    }

    private func selectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }

        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success else { return nil }
        return selectedValue as? String
    }

    private func selectedTextViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        let baselineChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            snapshot.restore(to: pasteboard)
            return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return nil }
            if pasteboard.changeCount != baselineChangeCount {
                let copiedChangeCount = pasteboard.changeCount
                let text = pasteboard.string(forType: .string)
                if pasteboard.changeCount == copiedChangeCount { snapshot.restore(to: pasteboard) }
                return text
            }
        }

        if pasteboard.changeCount == baselineChangeCount { snapshot.restore(to: pasteboard) }
        return nil
    }

    private func promptForAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

@MainActor
private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restoredItems = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
