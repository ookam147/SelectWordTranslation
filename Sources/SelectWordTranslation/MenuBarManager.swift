import SwiftUI
import AppKit

class MenuBarManager: NSObject {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var modelManager: ModelManager?
    var hotkeyManager: HotkeyManager?  // ⭐ 新增：快捷键管理器引用
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Translate")
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
        
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 140)
        popover?.behavior = .transient
        
        updatePopoverContent()
    }
    
    private func updatePopoverContent() {
        guard let modelManager = modelManager else {
            fatalError("ModelManager must be set before setupMenuBar()")
        }
        
        popover?.contentViewController = NSHostingController(
            rootView: SettingsView(
                modelManager: modelManager,
                onQuit: { [weak self] in
                    self?.quitApp()
                },
                hotkeyManager: hotkeyManager  // ⭐ 传递快捷键管理器
            )
        )
    }
    
    @objc func handleStatusBarClick(_ sender: NSStatusBarButton) {
        // 左键和右键都打开同一个 popover
        togglePopover(sender)
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem?.button {
            if let popover = popover {
                if popover.isShown {
                    popover.performClose(sender)
                } else {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    popover.contentViewController?.view.window?.makeKey()
                }
            }
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
