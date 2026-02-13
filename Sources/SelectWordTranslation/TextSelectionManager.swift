import Cocoa
import ApplicationServices

class TextSelectionManager {
    static let shared = TextSelectionManager()
    
    private init() {}
    
    func getSelectedText() -> String? {
        // 方法 1：尝试通过辅助功能 API 获取选中文字
        if let text = getSelectedTextViaAccessibility() {
            return text
        }
        
        // 方法 2：Fallback - 通过剪贴板获取（模拟 Cmd+C）
        print("DEBUG: Accessibility failed, trying clipboard fallback...")
        return getSelectedTextViaClipboard()
    }
    
    private func getSelectedTextViaAccessibility() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        
        let error = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        if error == .success, let element = focusedElement {
            let axElement = element as! AXUIElement
            var selectedTextValue: AnyObject?
            
            let textError = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selectedTextValue)
            
            if textError == .success, let text = selectedTextValue as? String, !text.isEmpty {
                print("DEBUG: Got text via Accessibility API")
                return text
            }
        }
        
        return nil
    }
    
    private func getSelectedTextViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        
        // 1. 保存当前剪贴板内容
        let oldContents = pasteboard.string(forType: .string)
        let oldChangeCount = pasteboard.changeCount
        
        // 2. 模拟 Cmd+C 复制选中文字
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key down: C with Command
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // 0x08 = C
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        
        // Key up: C with Command
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
        
        // 3. 等待剪贴板更新（需要一点时间）
        usleep(100_000) // 100ms
        
        // 4. 读取新的剪贴板内容
        var selectedText: String? = nil
        
        // 检查剪贴板是否有变化
        if pasteboard.changeCount != oldChangeCount {
            selectedText = pasteboard.string(forType: .string)
            print("DEBUG: Got text via clipboard: \(selectedText ?? "nil")")
        }
        
        // 5. 恢复原来的剪贴板内容（如果有）
        if let old = oldContents, selectedText != nil {
            pasteboard.clearContents()
            pasteboard.setString(old, forType: .string)
        }
        
        return selectedText
    }
}
