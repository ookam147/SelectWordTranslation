import Cocoa
import SwiftUI

class PopupWindowManager {
    private var window: NSPanel?
    private var eventMonitor: Any?
    
    // 锁定的位置坐标
    private var lockedPosition: NSPoint?
    
    // ⭐ 保存当前的 onClose 回调，以便在外部点击时调用
    private var currentOnClose: (() -> Void)?
    
    // ⭐ 标记弹窗是否已被用户取消（用于状态拦截）
    private(set) var isCancelled: Bool = false
    
    // 置顶状态
    private var isPinned: Bool = false
    
    // ⭐ 保存窗口展开方向（true = 向下展开，顶部紧贴鼠标；false = 向上展开，底部紧贴鼠标）
    private var expandsDownward: Bool = true
    
    /// 锁定当前鼠标位置（在发起翻译请求前调用）
    func lockCurrentPosition() {
        // ⭐ 先隐藏当前窗口，确保新翻译会使用新的鼠标位置
        window?.orderOut(nil)
        
        lockedPosition = NSEvent.mouseLocation
        isCancelled = false  // 重置取消状态
        print("DEBUG: Position locked at \(lockedPosition!)")
    }
    
    /// 清除锁定的位置
    func unlockPosition() {
        lockedPosition = nil
    }
    
    // ⭐ 新增：保存语言变更回调
    private var currentOnLanguageChange: ((TargetLanguage) -> Void)?
    
    // ⭐ 新增：当前选择的语言
    private var currentSelectedLanguage: TargetLanguage = TargetLanguage.load()
    
    func show(originalText: String, translatedText: String, isLoading: Bool, modelName: String = "", selectedLanguage: TargetLanguage? = nil, onLanguageChange: ((TargetLanguage) -> Void)? = nil, onClose: @escaping () -> Void) {
        // ⭐ 如果已被取消，直接返回不显示
        if isCancelled {
            print("DEBUG: Popup cancelled, not showing")
            return
        }
        
        print("DEBUG: PopupWindowManager.show called")
        
        // ⭐ 保存回调
        currentOnClose = onClose
        currentOnLanguageChange = onLanguageChange
        
        // ⭐ 更新当前选择的语言（如果传入了新值）
        if let language = selectedLanguage {
            currentSelectedLanguage = language
        }
        
        // Create window if needed
        if window == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = NSColor.clear
            panel.level = NSWindow.Level.floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.hasShadow = false  // 移除窗口阴影提升性能
            panel.isMovableByWindowBackground = true  // 允许拖动窗口
            panel.animationBehavior = .none  // 禁用动画提升响应速度
            panel.ignoresMouseEvents = false
            self.window = panel
        }
        
        let contentView = TranslationPopupView(
            originalText: originalText,
            translatedText: translatedText,
            isLoading: isLoading,
            modelName: modelName,
            onClose: { [weak self] in
                self?.hide()
            },
            onPinToggle: { [weak self] in
                self?.togglePin()
            },
            isPinned: isPinned,
            selectedLanguage: currentSelectedLanguage,
            onLanguageChange: { [weak self] language in
                self?.currentSelectedLanguage = language
                self?.currentOnLanguageChange?(language)
            }
        )
        
        window?.contentView = NSHostingView(rootView: contentView)
        
        // ⭐ 如果窗口已经显示，保留当前位置（保留用户拖动），只更新内容和调整大小
        if let existingWindow = window, existingWindow.isVisible {
            print("DEBUG: Window already visible, preserving current position, expandsDownward=\(expandsDownward)")
            
            // 获取当前位置
            let currentFrame = existingWindow.frame
            
            // 计算新的内容大小
            var windowSize = window?.contentView?.fittingSize ?? CGSize(width: 300, height: 200)
            
            // 获取屏幕信息用于限制高度
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(currentFrame.origin) }) {
                let dynamicMaxHeight = screen.visibleFrame.height - 100
                windowSize.height = min(windowSize.height, dynamicMaxHeight)
            }
            
            // ⭐ 根据展开方向决定如何调整窗口位置
            let newY: CGFloat
            if expandsDownward {
                // 向下展开时，保持窗口顶部位置不变
                // 顶部 y = currentFrame.maxY，新的底部 y = 顶部 y - 新高度
                newY = currentFrame.maxY - windowSize.height
            } else {
                // 向上展开时，保持窗口底部位置不变（左下角 y 不变）
                newY = currentFrame.minY
            }
            
            let newFrame = CGRect(
                x: currentFrame.minX,
                y: newY,
                width: windowSize.width,
                height: windowSize.height
            )
            
            window?.setFrame(newFrame, display: true)
            window?.orderFront(nil)
            setupEventMonitor()
            return
        }
        
        // ⭐ 窗口未显示，使用锁定的位置或当前鼠标位置来计算新位置
        let targetPosition = lockedPosition ?? NSEvent.mouseLocation
        print("DEBUG: Window not visible, using position \(targetPosition), locked=\(lockedPosition != nil)")
        
        // Get screen bounds first to calculate dynamic max height
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(targetPosition, $0.frame, false) }) else {
            // Fallback if we can't find the screen
            var windowSize = window?.contentView?.fittingSize ?? CGSize(width: 300, height: 200)
            let frame = CGRect(
                x: targetPosition.x + 10,
                y: targetPosition.y - 10 - windowSize.height,
                width: windowSize.width,
                height: windowSize.height
            )
            window?.setFrame(frame, display: true)
            window?.orderFront(nil)
            setupEventMonitor()
            return
        }
        
        let screenFrame = screen.visibleFrame
        
        // 动态计算最大高度：屏幕可见区域高度减去上下各50像素的边距
        let dynamicMaxHeight = screenFrame.height - 100
        
        var windowSize = window?.contentView?.fittingSize ?? CGSize(width: 300, height: 200)
        
        // 只有当内容高度超过屏幕可用空间时才限制高度（动态限制，而非固定值）
        windowSize.height = min(windowSize.height, dynamicMaxHeight)
        
        // ========== 修复：根据鼠标在屏幕中的相对位置决定展开方向 ==========
        // targetPosition 是全局坐标（已经是屏幕坐标系）
        // macOS 坐标系：左下角是原点，y 轴向上
        
        var x: CGFloat
        var y: CGFloat
        
        // 计算鼠标相对于屏幕的位置（0.0 ~ 1.0）
        let relativeX = (targetPosition.x - screenFrame.minX) / screenFrame.width
        let relativeY = (targetPosition.y - screenFrame.minY) / screenFrame.height
        
        print("DEBUG: relativeX=\(relativeX), relativeY=\(relativeY)")
        print("DEBUG: screenFrame=\(screenFrame), targetPosition=\(targetPosition)")
        print("DEBUG: windowSize=\(windowSize)")
        
        // 水平方向定位
        if relativeX < 0.5 {
            // 鼠标在屏幕左半边，浮窗向右展开（浮窗左边缘紧贴鼠标）
            x = targetPosition.x
        } else {
            // 鼠标在屏幕右半边，浮窗向左展开（浮窗右边缘紧贴鼠标）
            x = targetPosition.x - windowSize.width
        }
        
        // 垂直方向定位
        // macOS 的 NSWindow frame 的 y 是窗口左下角的 y 坐标
        if relativeY > 0.5 {
            // 鼠标在屏幕上半边，浮窗向下展开（浮窗顶部紧贴鼠标）
            // 窗口顶部 y = targetPosition.y，所以窗口左下角 y = targetPosition.y - windowSize.height
            y = targetPosition.y - windowSize.height
            expandsDownward = true  // ⭐ 保存展开方向
        } else {
            // 鼠标在屏幕下半边，浮窗向上展开（浮窗底部紧贴鼠标）
            // 窗口底部 y = targetPosition.y，所以窗口左下角 y = targetPosition.y
            y = targetPosition.y
            expandsDownward = false  // ⭐ 保存展开方向
        }
        
        print("DEBUG: Before boundary check: x=\(x), y=\(y)")
        
        // 边界检查：确保不超出屏幕
        x = max(x, screenFrame.minX)
        x = min(x, screenFrame.maxX - windowSize.width)
        y = max(y, screenFrame.minY)
        y = min(y, screenFrame.maxY - windowSize.height)
        
        print("DEBUG: After boundary check: x=\(x), y=\(y)")
        
        let frame = CGRect(
            x: x,
            y: y,
            width: windowSize.width,
            height: windowSize.height
        )
        
        window?.setFrame(frame, display: true)
        window?.orderFront(nil)
        
        setupEventMonitor()
    }
    
    private func setupEventMonitor() {
        // Remove existing monitor first
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        // 只有非置顶状态才添加自动关闭监听
        if !isPinned {
            // Add click and ESC key monitoring to dismiss
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self = self else { return }
                
                // Check if ESC key was pressed
                if event.type == .keyDown && event.keyCode == 53 {  // 53 is ESC key code
                    self.hide()
                    return
                }
                
                // 对于鼠标点击，检查点击位置是否在窗口外部
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    guard let window = self.window else { return }
                    
                    // 获取鼠标点击的全局坐标
                    let clickLocation = NSEvent.mouseLocation
                    
                    // 获取窗口的frame（屏幕坐标系）
                    let windowFrame = window.frame
                    
                    // 检查点击是否在窗口外部
                    if !windowFrame.contains(clickLocation) {
                        self.hide()
                    }
                }
            }
        }
    }
    
    /// 切换置顶状态
    private func togglePin() {
        isPinned.toggle()
        print("DEBUG: Pin toggled, isPinned=\(isPinned)")
        
        // 重新设置事件监听器
        setupEventMonitor()
        
        // 重新创建视图以更新图钉图标
        guard let hostingView = window?.contentView as? NSHostingView<TranslationPopupView>,
              let currentView = hostingView.rootView as? TranslationPopupView else {
            return
        }
        
        let updatedView = TranslationPopupView(
            originalText: currentView.originalText,
            translatedText: currentView.translatedText,
            isLoading: currentView.isLoading,
            modelName: currentView.modelName,
            onClose: { [weak self] in
                self?.hide()
            },
            onPinToggle: { [weak self] in
                self?.togglePin()
            },
            isPinned: isPinned,
            selectedLanguage: currentSelectedLanguage,
            onLanguageChange: { [weak self] language in
                self?.currentSelectedLanguage = language
                self?.currentOnLanguageChange?(language)
            }
        )
        
        window?.contentView = NSHostingView(rootView: updatedView)
    }
    
    func hide() {
        print("DEBUG: PopupWindowManager.hide called, calling onClose")
        
        window?.orderOut(nil)
        
        // ⭐ 标记为已取消
        isCancelled = true
        
        // 清除锁定的位置
        unlockPosition()
        
        // Remove monitors
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        // ⭐ 调用保存的 onClose 回调
        currentOnClose?()
        currentOnClose = nil
    }
}
