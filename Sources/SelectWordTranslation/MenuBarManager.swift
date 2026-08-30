import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarManager: NSObject, NSWindowDelegate {
    var onTranslateSelection: (() -> Void)?

    private let modelManager: ModelManager
    private let hotkeyManager: HotkeyManager
    private let translationService: TranslationServicing
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var settingsWindowController: NSWindowController?
    private var cancellables = Set<AnyCancellable>()

    init(modelManager: ModelManager, hotkeyManager: HotkeyManager, translationService: TranslationServicing) {
        self.modelManager = modelManager
        self.hotkeyManager = hotkeyManager
        self.translationService = translationService
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: L10n.appName)
        item.menu = makeMenu()
        statusItem = item

        modelManager.$connectionState
            .sink { [weak self] state in self?.statusMenuItem?.title = state.displayText }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        settingsWindowController?.close()
        settingsWindowController = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func translateSelection() { onTranslateSelection?() }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            let rootView = SettingsView(
                modelManager: modelManager,
                hotkeyManager: hotkeyManager,
                translationService: translationService
            )
            let controller = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: controller)
            window.title = L10n.settings.replacingOccurrences(of: "…", with: "")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 420))
            window.center()
            window.delegate = self
            settingsWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func windowWillClose(_ notification: Notification) {
        settingsWindowController?.window?.contentViewController = nil
        settingsWindowController = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: modelManager.connectionState.displayText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.translateSelection, action: #selector(translateSelection), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: L10n.settings, action: #selector(showSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        let quit = menu.addItem(withTitle: L10n.quit, action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        return menu
    }
}
