import AppKit
import Carbon
import Foundation

@MainActor
protocol HotkeyManagerDelegate: AnyObject {
    func didTriggerHotkey()
}

struct HotkeyConfig: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    static let userDefaultsKey = "com.selectwordtranslation.hotkey"
    static let `default` = HotkeyConfig(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey))

    var displayName: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        value += Self.keyNames[Int(keyCode)] ?? "Key \(keyCode)"
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.userDefaultsKey) }
    }

    static func load(defaults: UserDefaults = .standard) -> HotkeyConfig {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let value = try? JSONDecoder().decode(HotkeyConfig.self, from: data) else { return .default }
        return value
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9", kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
        kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]
}

enum HotkeyError: LocalizedError, Sendable {
    case eventHandler(OSStatus)
    case registration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandler(let status): "Unable to install the shortcut handler (\(status))."
        case .registration(let status): "The shortcut is unavailable (\(status))."
        }
    }
}

@MainActor
final class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?
    private(set) var currentConfig: HotkeyConfig
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let signature: OSType = 0x53575454 // SWTT

    init(defaults: UserDefaults = .standard) {
        currentConfig = HotkeyConfig.load(defaults: defaults)
    }

    func start() throws {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            selectWordHotkeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard status == noErr else { throw HotkeyError.eventHandler(status) }
        do {
            try register(currentConfig)
        } catch {
            stop()
            throw error
        }
    }

    func updateHotkey(config: HotkeyConfig, defaults: UserDefaults = .standard) throws {
        let previous = currentConfig
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        do {
            try register(config)
            currentConfig = config
            config.save(defaults: defaults)
        } catch {
            try? register(previous)
            throw error
        }
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef); self.eventHandlerRef = nil }
    }

    fileprivate func handleHotkey() { delegate?.didTriggerHotkey() }

    private func register(_ config: HotkeyConfig) throws {
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else { throw HotkeyError.registration(status) }
    }

}

private func selectWordHotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in manager.handleHotkey() }
    return noErr
}
