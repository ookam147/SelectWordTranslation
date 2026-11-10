import Combine
import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    static let autoSwitchLanguageKey = "autoSwitchLanguage"
    static let cleansTerminalTextKey = "cleansTerminalText"
    static let recentClipboardWindowKey = "recentClipboardWindow"
    static let recentClipboardWindowOptions: [TimeInterval] = [0, 5, 15, 30, 60]

    @Published var autoSwitchLanguage: Bool {
        didSet { defaults.set(autoSwitchLanguage, forKey: Self.autoSwitchLanguageKey) }
    }
    @Published var cleansTerminalText: Bool {
        didSet { defaults.set(cleansTerminalText, forKey: Self.cleansTerminalTextKey) }
    }
    @Published var recentClipboardWindow: TimeInterval {
        didSet { defaults.set(recentClipboardWindow, forKey: Self.recentClipboardWindowKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoSwitchLanguage = defaults.object(forKey: Self.autoSwitchLanguageKey) as? Bool ?? true
        cleansTerminalText = defaults.object(forKey: Self.cleansTerminalTextKey) as? Bool
            ?? SelectionSettings.default.cleansTerminalText
        let window = defaults.object(forKey: Self.recentClipboardWindowKey) as? TimeInterval
            ?? SelectionSettings.default.recentClipboardWindow
        recentClipboardWindow = Self.recentClipboardWindowOptions.contains(window)
            ? window
            : SelectionSettings.default.recentClipboardWindow
    }

    var selectionSettings: SelectionSettings {
        SelectionSettings(recentClipboardWindow: recentClipboardWindow, cleansTerminalText: cleansTerminalText)
    }
}
