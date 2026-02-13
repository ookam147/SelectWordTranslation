import Cocoa
import Carbon

protocol HotkeyManagerDelegate: AnyObject {
    func didTriggerHotkey()
}

// MARK: - 快捷键配置
struct HotkeyConfig: Codable, Equatable {
    let keyCode: UInt32      // 键码，如 kVK_ANSI_D
    let modifiers: UInt32    // 修饰键，如 optionKey
    
    static let userDefaultsKey = "com.selectwordtranslation.hotkey"
    
    // 默认快捷键：Option+D
    static let `default` = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(optionKey)
    )
    
    // 保存到 UserDefaults
    func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(self) {
            UserDefaults.standard.set(data, forKey: HotkeyConfig.userDefaultsKey)
        }
    }
    
    // 从 UserDefaults 加载
    static func load() -> HotkeyConfig {
        guard let data = UserDefaults.standard.data(forKey: HotkeyConfig.userDefaultsKey),
              let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) else {
            return .default
        }
        return config
    }
    
    // 获取显示名称，如 "⌥D"
    var displayName: String {
        var result = ""
        
        // 修饰键符号
        if modifiers & UInt32(controlKey) != 0 {
            result += "⌃"
        }
        if modifiers & UInt32(optionKey) != 0 {
            result += "⌥"
        }
        if modifiers & UInt32(shiftKey) != 0 {
            result += "⇧"
        }
        if modifiers & UInt32(cmdKey) != 0 {
            result += "⌘"
        }
        
        // 键名
        result += keyCodeToString(keyCode)
        
        return result
    }
    
    // 键码转字符串
    private func keyCodeToString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "?"
        }
    }
}

class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    
    // 当前快捷键配置
    private(set) var currentConfig: HotkeyConfig
    
    // 使用一个唯一的 ID 来标识我们的快捷键
    private let hotKeySignature: OSType = {
        // "SWTT" 转为 OSType
        let chars: [UInt8] = [0x53, 0x57, 0x54, 0x54] // S, W, T, T
        return OSType(chars[0]) << 24 | OSType(chars[1]) << 16 | OSType(chars[2]) << 8 | OSType(chars[3])
    }()
    
    fileprivate static var sharedInstance: HotkeyManager?
    
    init() {
        // 加载保存的快捷键配置
        self.currentConfig = HotkeyConfig.load()
        HotkeyManager.sharedInstance = self
    }
    
    func start() {
        // 1. 定义事件类型
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), 
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        // 2. 安装全局事件处理器（使用静态回调）
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil, // 不传 userData，使用静态实例
            &eventHandlerRef
        )
        
        if status != noErr {
            print("❌ Failed to install event handler: \(status)")
            return
        }
        
        // 3. 注册当前配置的快捷键
        registerHotkey(config: currentConfig)
    }
    
    // 注册快捷键
    private func registerHotkey(config: HotkeyConfig) {
        var hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
        
        if registerStatus != noErr {
            print("❌ Failed to register hotkey: \(registerStatus)")
            return
        }
        
        print("✅ Hotkey \(config.displayName) registered successfully (Carbon API)")
    }
    
    // 更新快捷键（运行时动态更新）
    func updateHotkey(config: HotkeyConfig) {
        // 先注销旧的快捷键
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        
        // 注册新的快捷键
        currentConfig = config
        registerHotkey(config: config)
        
        // 保存到 UserDefaults
        config.save()
        
        print("✅ Hotkey updated to \(config.displayName)")
    }
    
    func stop() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        
        print("🛑 Hotkey unregistered")
    }
    
    fileprivate func handleHotKeyEvent() {
        print("DEBUG: Hotkey \(currentConfig.displayName) triggered (Carbon)")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didTriggerHotkey()
        }
    }
    
    deinit {
        stop()
    }
}

// 静态回调函数（Carbon API 要求）
private func hotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    HotkeyManager.sharedInstance?.handleHotKeyEvent()
    return noErr
}
