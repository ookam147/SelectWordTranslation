import Foundation

// MARK: - 应用语言

enum AppLanguage: String, Codable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    
    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }
    
    var icon: String {
        switch self {
        case .english:
            return "🇺🇸"
        case .simplifiedChinese:
            return "🇨🇳"
        }
    }
    
    static let userDefaultsKey = "com.selectwordtranslation.appLanguage"
    
    static let `default` = AppLanguage.english
    
    // 保存到 UserDefaults
    func save() {
        UserDefaults.standard.set(self.rawValue, forKey: AppLanguage.userDefaultsKey)
    }
    
    // 从 UserDefaults 加载
    static func load() -> AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: AppLanguage.userDefaultsKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .default
        }
        return language
    }
}

// MARK: - 本地化字符串

class LocalizedStrings: ObservableObject {
    @Published var currentLanguage: AppLanguage
    
    static let shared = LocalizedStrings()
    
    init() {
        self.currentLanguage = AppLanguage.load()
    }
    
    func setLanguage(_ language: AppLanguage) {
        currentLanguage = language
        language.save()
    }
    
    // MARK: - SettingsView
    
    var mode: String {
        currentLanguage == .english ? "Mode" : "模式"
    }
    
    var local: String {
        currentLanguage == .english ? "Local" : "本地"
    }
    
    var cloud: String {
        currentLanguage == .english ? "Cloud" : "云端"
    }
    
    var apiAddress: String {
        currentLanguage == .english ? "API Address" : "API 地址"
    }
    
    var apiKey: String {
        currentLanguage == .english ? "API Key" : "API 密钥"
    }
    
    var modelName: String {
        currentLanguage == .english ? "Model Name" : "模型名称"
    }
    
    var connect: String {
        currentLanguage == .english ? "Connect" : "连接"
    }
    
    var ready: String {
        currentLanguage == .english ? "Ready" : "就绪"
    }
    
    var justNow: String {
        currentLanguage == .english ? "just now" : "刚刚"
    }
    
    var ago: String {
        currentLanguage == .english ? "ago" : "前"
    }
    
    var quit: String {
        currentLanguage == .english ? "Quit" : "退出"
    }
    
    var systemLanguage: String {
        currentLanguage == .english ? "System Language:" : "系统语言："
    }
    
    var addCustomPreset: String {
        currentLanguage == .english ? "Add Custom Preset" : "添加自定义预设"
    }
    
    var name: String {
        currentLanguage == .english ? "Name" : "名称"
    }
    
    var apiURL: String {
        currentLanguage == .english ? "API URL" : "API 地址"
    }
    
    var defaultModel: String {
        currentLanguage == .english ? "Default Model (optional)" : "默认模型（可选）"
    }
    
    var cancel: String {
        currentLanguage == .english ? "Cancel" : "取消"
    }
    
    var save: String {
        currentLanguage == .english ? "Save" : "保存"
    }
    
    var custom: String {
        currentLanguage == .english ? "custom" : "自定义"
    }
    
    var addCustom: String {
        currentLanguage == .english ? "Add Custom..." : "添加自定义..."
    }
    
    var deleteCustom: String {
        currentLanguage == .english ? "Delete Custom" : "删除自定义"
    }
    
    // MARK: - HotkeySettingsView
    
    var hotkeySettings: String {
        currentLanguage == .english ? "Hotkey Settings" : "快捷键设置"
    }
    
    var clickAreaThenPress: String {
        currentLanguage == .english 
            ? "Click the area below, then press your desired key combination"
            : "点击下方区域，然后按下您想要的快捷键组合"
    }
    
    var pressKeys: String {
        currentLanguage == .english ? "Press keys..." : "按下快捷键..."
    }
    
    var hotkeyTip: String {
        currentLanguage == .english 
            ? "Tip: Hotkey must include modifier keys (⌃⌥⇧⌘)"
            : "提示：快捷键必须包含修饰键（⌃⌥⇧⌘）"
    }
    
    var resetToDefault: String {
        currentLanguage == .english ? "Reset to Default" : "恢复默认"
    }
    
    var hotkeyMustIncludeModifier: String {
        currentLanguage == .english 
            ? "Hotkey must include at least one modifier key (⌃⌥⇧⌘)"
            : "快捷键必须包含至少一个修饰键（⌃⌥⇧⌘）"
    }
    
    var setHotkey: String {
        currentLanguage == .english ? "Set Hotkey" : "设置快捷键"
    }
    
    // MARK: - TranslationPopupView
    
    var models: String {
        currentLanguage == .english ? "Models:" : "模型："
    }
    
    var original: String {
        currentLanguage == .english ? "Original:" : "原文："
    }
    
    var result: String {
        currentLanguage == .english ? "Result:" : "结果："
    }
    
    var translating: String {
        currentLanguage == .english ? "Translating..." : "翻译中..."
    }
    
    var pinWindow: String {
        currentLanguage == .english ? "Pin window" : "置顶窗口"
    }
    
    var unpinWindow: String {
        currentLanguage == .english ? "Unpin window" : "取消置顶"
    }
    
    // MARK: - Status Messages (ModelManager)
    
    var checking: String {
        currentLanguage == .english ? "Checking..." : "检查中..."
    }
    
    var connecting: String {
        currentLanguage == .english ? "Connecting..." : "连接中..."
    }
    
    var apiKeyRequired: String {
        currentLanguage == .english ? "⚠️ API Key required" : "⚠️ 需要 API 密钥"
    }
    
    var modelNameRequired: String {
        currentLanguage == .english ? "⚠️ Model name required" : "⚠️ 需要模型名称"
    }
    
    var cannotConnectToAPI: String {
        currentLanguage == .english ? "⚠️ Cannot connect to API" : "⚠️ 无法连接到 API"
    }
    
    var lmStudioNotRunning: String {
        currentLanguage == .english ? "⚠️ LM Studio not running" : "⚠️ LM Studio 未运行"
    }
    
    var noModelLoaded: String {
        currentLanguage == .english ? "⚠️ No model loaded" : "⚠️ 未加载模型"
    }
    
    var translatingStatus: String {
        currentLanguage == .english ? "Translating..." : "翻译中..."
    }
    
    var translationComplete: String {
        currentLanguage == .english ? "✅ Translation complete" : "✅ 翻译完成"
    }
    
    func readyWithModel(_ model: String) -> String {
        currentLanguage == .english ? "Ready (\(model))" : "就绪 (\(model))"
    }
}
