import SwiftUI

@main
struct SelectWordTranslationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, HotkeyManagerDelegate {
    var menuBarManager = MenuBarManager()
    var hotkeyManager = HotkeyManager()
    var popupManager = PopupWindowManager()
    var modelManager = ModelManager()
    
    // ⭐ 保存当前正在翻译的原文（用于语言变更时重新翻译）
    private var currentOriginalText: String = ""
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== SelectWordTranslation App Started ===")
        
        // Inject model manager into MenuBarManager -> SettingsView
        menuBarManager.modelManager = modelManager
        menuBarManager.hotkeyManager = hotkeyManager  // ⭐ 传递快捷键管理器
        menuBarManager.setupMenuBar()
        print("Menu bar setup complete")
        
        hotkeyManager.delegate = self
        hotkeyManager.start()
        print("Hotkey manager started with \(hotkeyManager.currentConfig.displayName)")
    }
    
    func didTriggerHotkey() {
        print("Hotkey triggered!")
        
        // 1. Get Selected Text
        guard let text = TextSelectionManager.shared.getSelectedText(), !text.isEmpty else {
            print("No text selected")
            NSSound.beep()
            return
        }
        print("Selected text: \(text)")
        
        // ⭐ 保存原文用于后续重新翻译
        currentOriginalText = text
        
        // 锁定当前鼠标位置（同时重置取消状态）
        popupManager.lockCurrentPosition()
        
        // 获取当前模型名称和语言
        let currentModelName = modelManager.selectedModelId ?? "Translation"
        let currentLanguage = TargetLanguage.load()
        
        // 2. Show Popup (Loading)
        popupManager.show(
            originalText: text,
            translatedText: "",
            isLoading: true,
            modelName: currentModelName,
            selectedLanguage: currentLanguage,
            onLanguageChange: { [weak self] newLanguage in
                self?.handleLanguageChange(newLanguage)
            },
            onClose: {
                print("DEBUG: Popup closed by user")
            }
        )
        
        // 3. Translate (异步)
        Task {
            let translation = await modelManager.generateTranslation(for: text)
            
            // 4. ⭐ 状态拦截：检查是否已被取消
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                
                // 如果弹窗已被用户取消，直接返回
                if self.popupManager.isCancelled {
                    print("DEBUG: Translation completed but popup was cancelled, skipping")
                    return
                }
                
                // 弹窗未被取消，显示翻译结果
                print("DEBUG: Showing translation result")
                let currentLanguage = TargetLanguage.load()
                self.popupManager.show(
                    originalText: text,
                    translatedText: translation,
                    isLoading: false,
                    modelName: currentModelName,
                    selectedLanguage: currentLanguage,
                    onLanguageChange: { [weak self] newLanguage in
                        self?.handleLanguageChange(newLanguage)
                    },
                    onClose: {
                        print("DEBUG: Result popup closed")
                    }
                )
            }
        }
    }
    
    // ⭐ 处理语言变更
    private func handleLanguageChange(_ newLanguage: TargetLanguage) {
        print("DEBUG: Language changed to \(newLanguage.nativeName)")
        
        // 1. 保存新语言到 UserDefaults（同步后台设置）
        TargetLanguage.save(newLanguage)
        
        // 2. 显示加载状态
        let currentModelName = modelManager.selectedModelId ?? "Translation"
        popupManager.show(
            originalText: currentOriginalText,
            translatedText: "",
            isLoading: true,
            modelName: currentModelName,
            selectedLanguage: newLanguage,
            onLanguageChange: { [weak self] language in
                self?.handleLanguageChange(language)
            },
            onClose: {
                print("DEBUG: Popup closed during retranslation")
            }
        )
        
        // 3. 重新翻译
        Task {
            let translation = await modelManager.generateTranslation(for: currentOriginalText)
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                
                // 如果弹窗已被用户取消，直接返回
                if self.popupManager.isCancelled {
                    print("DEBUG: Retranslation completed but popup was cancelled")
                    return
                }
                
                // 显示新的翻译结果
                print("DEBUG: Showing retranslation result")
                self.popupManager.show(
                    originalText: self.currentOriginalText,
                    translatedText: translation,
                    isLoading: false,
                    modelName: currentModelName,
                    selectedLanguage: newLanguage,
                    onLanguageChange: { [weak self] language in
                        self?.handleLanguageChange(language)
                    },
                    onClose: {
                        print("DEBUG: Retranslation popup closed")
                    }
                )
            }
        }
    }
}

