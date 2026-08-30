import AppKit
import Combine

@MainActor
final class TranslationPopupViewModel: ObservableObject {
    @Published var originalText: String
    @Published var state: TranslationState
    @Published var modelName: String
    @Published var selectedLanguage: TargetLanguage
    @Published var isPinned = false

    var onClose: (() -> Void)?
    var onPinToggle: (() -> Void)?
    var onLanguageChange: ((TargetLanguage) -> Void)?

    init(originalText: String, state: TranslationState, modelName: String, selectedLanguage: TargetLanguage) {
        self.originalText = originalText
        self.state = state
        self.modelName = modelName
        self.selectedLanguage = selectedLanguage
    }

    var translatedText: String {
        if case .result(let value) = state { return value }
        return ""
    }

    func clear() {
        originalText = ""
        state = .idle
        modelName = ""
        onClose = nil
        onPinToggle = nil
        onLanguageChange = nil
    }
}

@MainActor
final class TranslationPanelContentController: NSViewController {
    private weak var model: TranslationPopupViewModel?
    private let modelLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let pinButton = NSButton()
    private let closeButton = NSButton()
    private let originalTextView = TranslationPanelContentController.makeTextView()
    private let resultTextView = TranslationPanelContentController.makeTextView()
    private let originalScrollView = TranslationPanelContentController.makeScrollView()
    private let resultScrollView = TranslationPanelContentController.makeScrollView()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusStack = NSStackView()
    private let copyButton = NSButton()

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        view = effectView

        originalScrollView.documentView = originalTextView
        resultScrollView.documentView = resultTextView
        originalScrollView.translatesAutoresizingMaskIntoConstraints = false
        resultScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            originalScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            resultScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])

        let header = makeHeader()
        let originalHeader = makeSectionHeader(title: L10n.original)
        let resultHeader = makeResultHeader()
        statusStack.addArrangedSubview(progressIndicator)
        statusStack.addArrangedSubview(statusLabel)
        statusStack.orientation = .horizontal
        statusStack.spacing = 8
        statusStack.alignment = .centerY
        statusStack.detachesHiddenViews = true
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [
            header,
            originalHeader,
            originalScrollView,
            divider,
            resultHeader,
            statusStack,
            resultScrollView
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effectView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            originalHeader.widthAnchor.constraint(equalTo: header.widthAnchor),
            originalScrollView.widthAnchor.constraint(equalTo: header.widthAnchor),
            divider.widthAnchor.constraint(equalTo: header.widthAnchor),
            resultHeader.widthAnchor.constraint(equalTo: header.widthAnchor),
            statusStack.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor),
            resultScrollView.widthAnchor.constraint(equalTo: header.widthAnchor)
        ])
    }

    func update(with model: TranslationPopupViewModel) {
        loadViewIfNeeded()
        self.model = model
        modelLabel.stringValue = model.modelName.isEmpty ? L10n.appName : model.modelName
        originalTextView.string = model.originalText
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: TargetLanguage.languages.map(\.displayName))
        languagePopup.selectItem(at: TargetLanguage.languages.firstIndex(of: model.selectedLanguage) ?? 0)
        pinButton.image = NSImage(systemSymbolName: model.isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pinButton.toolTip = model.isPinned ? L10n.unpin : L10n.pin

        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusStack.isHidden = true
        statusLabel.textColor = .secondaryLabelColor
        switch model.state {
        case .idle:
            statusLabel.stringValue = ""
            resultTextView.string = ""
        case .loading:
            statusStack.isHidden = false
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            statusLabel.stringValue = L10n.translating
            resultTextView.string = ""
        case .result(let text):
            statusLabel.stringValue = ""
            resultTextView.string = text
        case .error(let message):
            statusStack.isHidden = false
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = message
            resultTextView.string = ""
        }
        copyButton.isEnabled = !model.translatedText.isEmpty
        originalTextView.scrollToBeginningOfDocument(nil)
        resultTextView.scrollToBeginningOfDocument(nil)
    }

    var desiredContentSize: NSSize {
        guard let model else { return NSSize(width: 400, height: 220) }
        let textLength = model.originalText.count + model.translatedText.count
        let width: CGFloat = textLength > 240 ? 600 : 420
        let estimatedLines = min(18, max(2, textLength / (textLength > 240 ? 80 : 52)))
        let height = min(560, max(220, 190 + CGFloat(estimatedLines) * 18))
        return NSSize(width: width, height: height)
    }

    func clearTextStorage() {
        originalTextView.string = ""
        resultTextView.string = ""
        statusLabel.stringValue = ""
        progressIndicator.stopAnimation(nil)
        model = nil
    }

    var presentationSnapshot: TranslationPanelPresentationSnapshot {
        TranslationPanelPresentationSnapshot(
            isStatusRowVisible: !statusStack.isHidden,
            isProgressIndicatorVisible: !progressIndicator.isHidden,
            statusText: statusLabel.stringValue,
            resultText: resultTextView.string
        )
    }

    private func makeHeader() -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "translate", accessibilityDescription: L10n.appName) ?? NSImage())
        modelLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.controlSize = .small
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: L10n.pin)
        pinButton.bezelStyle = .accessoryBarAction
        pinButton.isBordered = false
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.close)
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(close)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, modelLabel, spacer, languagePopup, pinButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func makeSectionHeader(title: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        return stack
    }

    private func makeResultHeader() -> NSStackView {
        let label = NSTextField(labelWithString: L10n.result)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L10n.copy)
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.isBordered = false
        copyButton.toolTip = L10n.copy
        copyButton.target = self
        copyButton.action = #selector(copyTranslation)
        let stack = NSStackView(views: [label, spacer, copyButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }

    @objc private func languageChanged() {
        guard languagePopup.indexOfSelectedItem >= 0 else { return }
        let language = TargetLanguage.languages[languagePopup.indexOfSelectedItem]
        model?.selectedLanguage = language
        model?.onLanguageChange?(language)
    }

    @objc private func togglePin() { model?.onPinToggle?() }
    @objc private func close() { model?.onClose?() }

    @objc private func copyTranslation() {
        guard let text = model?.translatedText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        return scrollView
    }

    private static func makeTextView() -> NSTextView {
        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }
}

struct TranslationPanelPresentationSnapshot: Equatable {
    let isStatusRowVisible: Bool
    let isProgressIndicatorVisible: Bool
    let statusText: String
    let resultText: String
}
