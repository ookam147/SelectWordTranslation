import Foundation
import NaturalLanguage

enum TerminalApplications {
    static let bundleIdentifiers: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "dev.warp.Warp-Stable",
        "org.tabby",
        "co.zeit.hyper"
    ]

    static func contains(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(bundleIdentifiers.contains) ?? false
    }
}

/// Repairs text copied out of terminal screens: TUI borders, shared indentation,
/// trailing padding, and hard line breaks inserted at the terminal width.
enum SelectionTextNormalizer {
    private static let borderCharacters: Set<Character> = ["│", "┃", "▌", "▎", "▏", "║"]
    private static let minimumWrapWidth = 40
    private static let wrappedLineFillRatio = 0.7

    static func normalizedTerminalText(_ text: String) -> String {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map(trimmingTrailingWhitespace)
        lines = strippingSharedBorder(lines)
        lines = dedented(lines)
        return joiningWrappedLines(lines).joined(separator: "\n")
    }

    private static func strippingSharedBorder(_ lines: [String]) -> [String] {
        let contentLines = lines.filter { !isBlank($0) }
        guard let border = contentLines.first?.drop(while: { $0 == " " }).first,
              borderCharacters.contains(border),
              contentLines.allSatisfy({ $0.drop(while: { $0 == " " }).first == border }) else { return lines }
        return lines.map { line in
            guard !isBlank(line) else { return "" }
            let content = line.drop(while: { $0 == " " }).dropFirst()
            return String(content.first == " " ? content.dropFirst() : content)
        }
    }

    private static func dedented(_ lines: [String]) -> [String] {
        let indentation = lines
            .filter { !isBlank($0) }
            .map { $0.prefix(while: { $0 == " " }).count }
            .min() ?? 0
        guard indentation > 0 else { return lines }
        return lines.map { isBlank($0) ? "" : String($0.dropFirst(indentation)) }
    }

    private static func joiningWrappedLines(_ lines: [String]) -> [String] {
        let maximumWidth = lines.map(displayWidth).max() ?? 0
        guard maximumWidth >= minimumWrapWidth else { return lines }
        let threshold = Int(Double(maximumWidth) * wrappedLineFillRatio)

        var result: [String] = []
        var previousLineWidth = 0
        for line in lines {
            guard let last = result.last,
                  !isBlank(last), !isBlank(line),
                  previousLineWidth >= threshold,
                  !startsBlock(line),
                  !last.hasSuffix("```") else {
                result.append(line)
                previousLineWidth = displayWidth(line)
                continue
            }
            let continuation = line.drop(while: { $0 == " " })
            let separator = needsSpace(between: last.last, and: continuation.first) ? " " : ""
            result[result.count - 1] = last + separator + continuation
            previousLineWidth = displayWidth(line)
        }
        return result
    }

    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        if trimmed.hasPrefix("```") || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || trimmed.hasPrefix("#") {
            return true
        }
        if let first = trimmed.first, "-*+•".contains(first), trimmed.dropFirst().first == " " { return true }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, let marker = trimmed.dropFirst(digits.count).first, marker == "." || marker == ")",
           trimmed.dropFirst(digits.count + 1).first == " " {
            return true
        }
        return false
    }

    private static func needsSpace(between previous: Character?, and next: Character?) -> Bool {
        guard let previous, let next else { return false }
        return !isWide(previous) && !isWide(next)
    }

    static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var line = line
        while let last = line.last, last.isWhitespace { line.removeLast() }
        return line
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }
}

/// Picks a more useful target when the selection is already written in the preferred language.
enum TargetLanguageRouter {
    private static let minimumConfidence = 0.6

    static func detectedLanguageID(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence else { return nil }
        let id = language == .simplifiedChinese ? "zh-CN" : language.rawValue
        return TargetLanguage.languages.contains { $0.id == id } ? id : nil
    }

    static func effectiveLanguage(for text: String, preferred: TargetLanguage) -> TargetLanguage {
        guard detectedLanguageID(of: text) == preferred.id else { return preferred }
        let fallbackID = preferred.id == "en" ? "zh-CN" : "en"
        return TargetLanguage.languages.first { $0.id == fallbackID } ?? preferred
    }
}
