import AppKit

@MainActor
protocol EventMonitoring: AnyObject {
    var activeMonitorCount: Int { get }
    func start(for panel: NSPanel, dismiss: @escaping () -> Void)
    func stop()
}

@MainActor
final class PanelEventMonitor: EventMonitoring {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var activeMonitorCount: Int { [globalMonitor, localMonitor].compactMap { $0 }.count }

    func start(for panel: NSPanel, dismiss: @escaping () -> Void) {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            let shouldDismiss = event.type == .keyDown && event.keyCode == 53
                || ((event.type == .leftMouseDown || event.type == .rightMouseDown)
                    && !(panel?.frame.contains(NSEvent.mouseLocation) ?? false))
            if shouldDismiss { Task { @MainActor in dismiss() } }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            if event.type == .keyDown && event.keyCode == 53 {
                dismiss()
                return nil
            }
            if event.window !== panel && (event.type == .leftMouseDown || event.type == .rightMouseDown) {
                dismiss()
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }

}

@MainActor
final class PopupWindowManager: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var viewModel: TranslationPopupViewModel?
    private var contentController: TranslationPanelContentController?
    private let eventMonitor: EventMonitoring
    private var anchorPosition: NSPoint?
    private(set) var isPinned = false
    var onDidClose: (() -> Void)?

    init(eventMonitor: EventMonitoring = PanelEventMonitor()) {
        self.eventMonitor = eventMonitor
    }

    func show(viewModel: TranslationPopupViewModel, at position: NSPoint, preservePosition: Bool = false) {
        anchorPosition = preservePosition ? panel?.frame.origin ?? position : position
        self.viewModel = viewModel
        viewModel.isPinned = isPinned
        viewModel.onClose = { [weak self] in self?.hide() }
        viewModel.onPinToggle = { [weak self] in self?.togglePin() }

        let panel = panel ?? makePanel()
        let controller = contentController ?? TranslationPanelContentController()
        contentController = controller
        if panel.contentViewController !== controller {
            panel.contentViewController = controller
        }
        controller.update(with: viewModel)
        let targetFrame: NSRect
        if preservePosition, panel.isVisible {
            targetFrame = resizedFrame(from: panel.frame, fittingSize: controller.desiredContentSize)
        } else {
            targetFrame = frame(for: controller.desiredContentSize, near: position)
        }
        panel.setFrame(targetFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        updateEventMonitoring()
    }

    func refreshLayout() {
        guard let panel, let viewModel, let contentController else { return }
        contentController.update(with: viewModel)
        panel.setFrame(resizedFrame(from: panel.frame, fittingSize: contentController.desiredContentSize), display: true, animate: true)
    }

    func hide(notify: Bool = true) {
        guard panel != nil || viewModel != nil else { return }
        eventMonitor.stop()
        panel?.orderOut(nil)
        viewModel?.clear()
        contentController?.clearTextStorage()
        anchorPosition = nil
        isPinned = false
        if notify { onDidClose?() }
    }

    func dispose() {
        eventMonitor.stop()
        let closingPanel = panel
        panel = nil
        closingPanel?.delegate = nil
        closingPanel?.contentViewController = nil
        closingPanel?.close()
        contentController?.clearTextStorage()
        contentController = nil
        viewModel?.clear()
        viewModel = nil
        anchorPosition = nil
        isPinned = false
    }

    func windowWillClose(_ notification: Notification) {
        eventMonitor.stop()
        panel = nil
        contentController?.clearTextStorage()
        contentController = nil
        viewModel?.clear()
        viewModel = nil
        onDidClose?()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 320, height: 160)
        panel.delegate = self
        return panel
    }

    private func togglePin() {
        isPinned.toggle()
        viewModel?.isPinned = isPinned
        if let viewModel { contentController?.update(with: viewModel) }
        updateEventMonitoring()
    }

    private func updateEventMonitoring() {
        guard let panel, panel.isVisible, !isPinned else { eventMonitor.stop(); return }
        eventMonitor.start(for: panel) { [weak self] in self?.hide() }
    }

    private func frame(for fittingSize: NSSize, near point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: min(max(fittingSize.width, 340), min(760, visible.width - 40)),
            height: min(max(fittingSize.height, 160), visible.height - 40)
        )
        var origin = NSPoint(x: point.x + 8, y: point.y - size.height - 8)
        if origin.x + size.width > visible.maxX { origin.x = point.x - size.width - 8 }
        if origin.y < visible.minY { origin.y = point.y + 8 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    private func resizedFrame(from current: NSRect, fittingSize: NSSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(current) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? current
        let size = NSSize(
            width: min(max(fittingSize.width, 340), min(760, visible.width - 40)),
            height: min(max(fittingSize.height, 160), visible.height - 40)
        )
        var origin = NSPoint(x: current.minX, y: current.maxY - size.height)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

}
