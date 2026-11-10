import Foundation

enum L10n {
    static var appName: String { text("SelectWordTranslation") }
    static var translateSelection: String { text("Translate Selection") }
    static var settings: String { text("Settings…") }
    static var quit: String { text("Quit SelectWordTranslation") }
    static var notChecked: String { text("Not checked") }
    static var ready: String { text("Ready") }
    static var testing: String { text("Testing connection…") }
    static var translating: String { text("Translating…") }
    static var thinking: String { text("Thinking…") }
    static var original: String { text("Original") }
    static var result: String { text("Result") }
    static var copy: String { text("Copy Translation") }
    static var pin: String { text("Pin Window") }
    static var unpin: String { text("Unpin Window") }
    static var close: String { text("Close") }
    static var noSelection: String { text("No text is selected.") }
    static var selectionTooLong: String { text("The selection exceeds the 20,000 character limit.") }
    static var accessibilityRequired: String { text("Accessibility permission is required to read selected text.") }
    static var error: String { text("Error") }

    static func seconds(_ value: Int) -> String {
        String(format: text("Within %d seconds"), locale: .current, value)
    }

    static func failed(_ message: String) -> String {
        String(format: text("Failed: %@"), locale: .current, message)
    }

    static func text(_ key: String.LocalizationValue) -> String {
#if SWIFT_PACKAGE
        String(localized: key, bundle: .module)
#else
        String(localized: key, bundle: .main)
#endif
    }
}
