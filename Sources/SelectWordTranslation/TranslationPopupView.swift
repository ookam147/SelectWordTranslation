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

enum TranslationPanelLayoutMode: Equatable, Sendable {
    case compactStacked
    case sideBySide
}

struct TranslationPanelLayout: Equatable {
    let mode: TranslationPanelLayoutMode
    let contentSize: NSSize
    let originalPaneExtent: CGFloat
    let resultPaneExtent: CGFloat

    var defaultSplitRatio: CGFloat {
        guard mode == .compactStacked else { return 0.5 }
        let total = originalPaneExtent + resultPaneExtent
        return total > 0 ? originalPaneExtent / total : 0.5
    }
}

@MainActor
struct TranslationPanelLayoutPolicy {
    static let compactMinimumSize = NSSize(width: 360, height: 190)
    static let compactMaximumSize = NSSize(width: 520, height: 420)
    static let sideBySideWidth: CGFloat = 760
    static let sideBySideMinimumHeight: CGFloat = 320
    static let sideBySideMaximumHeight: CGFloat = 560
    static let compactMinimumPaneExtent: CGFloat = 64
    static let sideBySideMinimumPaneExtent: CGFloat = 240

    private static let horizontalChrome: CGFloat = 40
    private static let verticalChrome: CGFloat = 63
    private static let paneHeaderHeight: CGFloat = 17
    private static let paneSpacing: CGFloat = 8
    private static let textVerticalInset: CGFloat = 8
    private static let statusRowHeight: CGFloat = 20
    private static let compactLineLimit: CGFloat = 6

    static func layout(
        originalText: String,
        resultText: String,
        statusRowVisible: Bool,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    ) -> TranslationPanelLayout {
        let maximumTextWidth = compactMaximumSize.width - horizontalChrome
        let originalCompactHeight = measuredTextHeight(originalText, width: maximumTextWidth, font: font)
        let resultCompactHeight = measuredTextHeight(resultText, width: maximumTextWidth, font: font)
        let lineHeight = max(1, defaultLineHeight(font: font))
        let originalLines = ceil(originalCompactHeight / lineHeight)
        let resultLines = ceil(resultCompactHeight / lineHeight)

        if originalLines > compactLineLimit || resultLines > compactLineLimit {
            return sideBySideLayout(
                originalText: originalText,
                resultText: resultText,
                statusRowVisible: statusRowVisible,
                font: font
            )
        }

        let longestLineWidth = max(
            longestUnwrappedLineWidth(originalText, font: font),
            longestUnwrappedLineWidth(resultText, font: font)
        )
        let width = clamp(
            ceil(longestLineWidth + horizontalChrome),
            minimum: compactMinimumSize.width,
            maximum: compactMaximumSize.width
        )
        let textWidth = width - horizontalChrome
        let originalPane = paneExtent(
            textHeight: measuredTextHeight(originalText, width: textWidth, font: font),
            statusRowVisible: false
        )
        let resultPane = paneExtent(
            textHeight: measuredTextHeight(resultText, width: textWidth, font: font),
            statusRowVisible: statusRowVisible
        )
        let height = clamp(
            ceil(verticalChrome + originalPane + resultPane),
            minimum: compactMinimumSize.height,
            maximum: compactMaximumSize.height
        )
        return TranslationPanelLayout(
            mode: .compactStacked,
            contentSize: NSSize(width: width, height: height),
            originalPaneExtent: originalPane,
            resultPaneExtent: resultPane
        )
    }

    private static func sideBySideLayout(
        originalText: String,
        resultText: String,
        statusRowVisible: Bool,
        font: NSFont
    ) -> TranslationPanelLayout {
        let paneTextWidth = (sideBySideWidth - horizontalChrome) / 2
        let originalPane = paneExtent(
            textHeight: measuredTextHeight(originalText, width: paneTextWidth, font: font),
            statusRowVisible: false
        )
        let resultPane = paneExtent(
            textHeight: measuredTextHeight(resultText, width: paneTextWidth, font: font),
            statusRowVisible: statusRowVisible
        )
        let height = clamp(
            ceil(verticalChrome + max(originalPane, resultPane)),
            minimum: sideBySideMinimumHeight,
            maximum: sideBySideMaximumHeight
        )
        return TranslationPanelLayout(
            mode: .sideBySide,
            contentSize: NSSize(width: sideBySideWidth, height: height),
            originalPaneExtent: originalPane,
            resultPaneExtent: resultPane
        )
    }

    private static func paneExtent(textHeight: CGFloat, statusRowVisible: Bool) -> CGFloat {
        let textExtent = max(defaultLineHeight(font: .systemFont(ofSize: NSFont.systemFontSize)), textHeight)
            + textVerticalInset
        let statusExtent = statusRowVisible ? statusRowHeight + paneSpacing : 0
        return max(
            compactMinimumPaneExtent,
            paneHeaderHeight + paneSpacing + statusExtent + textExtent
        )
    }

    private static func measuredTextHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return defaultLineHeight(font: font) }
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(defaultLineHeight(font: font), ceil(bounds.height))
    }

    private static func longestUnwrappedLineWidth(_ text: String, font: NSFont) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    private static func defaultLineHeight(font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    private static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

@MainActor
final class TranslationPanelContentController: NSViewController, NSSplitViewDelegate {
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
    private let splitView = NSSplitView()
    private let originalPane = NSStackView()
    private let resultPane = NSStackView()
    private var compactPaneConstraints: [NSLayoutConstraint] = []
    private var sideBySidePaneConstraints: [NSLayoutConstraint] = []
    private var currentLayout = TranslationPanelLayoutPolicy.layout(
        originalText: "",
        resultText: "",
        statusRowVisible: false
    )
    private var shouldResetSplitOnNextLayout = true

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
        originalScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        resultScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        originalScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        resultScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            originalScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            resultScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
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

        configurePane(originalPane, views: [originalHeader, originalScrollView])
        configurePane(resultPane, views: [resultHeader, statusStack, resultScrollView])

        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        splitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        splitView.addArrangedSubview(originalPane)
        splitView.addArrangedSubview(resultPane)
        compactPaneConstraints = [
            originalPane.heightAnchor.constraint(
                greaterThanOrEqualToConstant: TranslationPanelLayoutPolicy.compactMinimumPaneExtent
            ),
            resultPane.heightAnchor.constraint(
                greaterThanOrEqualToConstant: TranslationPanelLayoutPolicy.compactMinimumPaneExtent
            )
        ]
        sideBySidePaneConstraints = [
            originalPane.widthAnchor.constraint(
                greaterThanOrEqualToConstant: TranslationPanelLayoutPolicy.sideBySideMinimumPaneExtent
            ),
            resultPane.widthAnchor.constraint(
                greaterThanOrEqualToConstant: TranslationPanelLayoutPolicy.sideBySideMinimumPaneExtent
            )
        ]
        NSLayoutConstraint.activate(compactPaneConstraints)

        let stack = NSStackView(views: [
            header,
            splitView
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
            splitView.widthAnchor.constraint(equalTo: header.widthAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyPendingSplitResetIfPossible()
    }

    func update(with model: TranslationPopupViewModel, resetSplit: Bool = false) {
        loadViewIfNeeded()
        self.model = model
        modelLabel.stringValue = model.modelName.isEmpty ? L10n.appName : model.modelName
        originalTextView.string = model.originalText
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: TargetLanguage.languages.map(\.nativeName))
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
        case .loading, .thinking:
            statusStack.isHidden = false
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            statusLabel.stringValue = model.state == .thinking ? L10n.thinking : L10n.translating
            resultTextView.string = ""
        case .streaming(let text), .result(let text):
            statusLabel.stringValue = ""
            resultTextView.string = text
        case .error(let message):
            statusStack.isHidden = false
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = message
            resultTextView.string = ""
        }
        copyButton.isEnabled = !model.translatedText.isEmpty
        let nextLayout = TranslationPanelLayoutPolicy.layout(
            originalText: model.originalText,
            resultText: resultTextView.string,
            statusRowVisible: !statusStack.isHidden,
            font: originalTextView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        )
        let modeChanged = nextLayout.mode != currentLayout.mode
        currentLayout = nextLayout
        if modeChanged {
            splitView.isVertical = nextLayout.mode == .sideBySide
            NSLayoutConstraint.deactivate(nextLayout.mode == .sideBySide ? compactPaneConstraints : sideBySidePaneConstraints)
            NSLayoutConstraint.activate(nextLayout.mode == .sideBySide ? sideBySidePaneConstraints : compactPaneConstraints)
        }
        if resetSplit || modeChanged { shouldResetSplitOnNextLayout = true }
        originalTextView.scrollToBeginningOfDocument(nil)
        resultTextView.scrollToBeginningOfDocument(nil)
    }

    var desiredContentSize: NSSize {
        currentLayout.contentSize
    }

    func desiredContentSize(preservingSplitRatio ratio: CGFloat) -> NSSize {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        let smallerFraction = min(max(ratio, 0.001), max(1 - ratio, 0.001))
        let requiredSplitExtent = minimumPaneExtent / smallerFraction + splitView.dividerThickness
        var size = currentLayout.contentSize
        if splitView.isVertical {
            let nonSplitWidth = max(0, view.bounds.width - splitView.bounds.width)
            size.width = max(size.width, ceil(nonSplitWidth + requiredSplitExtent))
        } else {
            let nonSplitHeight = max(0, view.bounds.height - splitView.bounds.height)
            size.height = max(size.height, ceil(nonSplitHeight + requiredSplitExtent))
        }
        return size
    }

    func clearTextStorage() {
        originalTextView.string = ""
        resultTextView.string = ""
        statusLabel.stringValue = ""
        progressIndicator.stopAnimation(nil)
        model = nil
        currentLayout = TranslationPanelLayoutPolicy.layout(
            originalText: "",
            resultText: "",
            statusRowVisible: false
        )
        splitView.isVertical = false
        NSLayoutConstraint.deactivate(sideBySidePaneConstraints)
        NSLayoutConstraint.activate(compactPaneConstraints)
        shouldResetSplitOnNextLayout = true
    }

    var presentationSnapshot: TranslationPanelPresentationSnapshot {
        TranslationPanelPresentationSnapshot(
            isStatusRowVisible: !statusStack.isHidden,
            isProgressIndicatorVisible: !progressIndicator.isHidden,
            statusText: statusLabel.stringValue,
            resultText: resultTextView.string,
            layoutMode: currentLayout.mode,
            targetContentSize: currentLayout.contentSize,
            isVerticalSplit: splitView.isVertical,
            originalPaneWidth: originalPane.frame.width,
            resultPaneWidth: resultPane.frame.width,
            originalPaneHeight: originalPane.frame.height,
            resultPaneHeight: resultPane.frame.height,
            splitRatio: currentSplitRatio
        )
    }

    func setSplitRatio(_ ratio: CGFloat) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        setSplitPosition(ratio: ratio)
    }

    func applyPendingSplitLayout() {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        applyPendingSplitResetIfPossible()
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, minimumPaneExtent)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(
            proposedMaximumPosition,
            splitViewExtent - splitView.dividerThickness - minimumPaneExtent
        )
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    private func makeHeader() -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "translate", accessibilityDescription: L10n.appName) ?? NSImage())
        modelLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        let stack = NSStackView(views: [icon, modelLabel, spacer, pinButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func configurePane(_ pane: NSStackView, views: [NSView]) {
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 8
        pane.detachesHiddenViews = true
        pane.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            pane.addArrangedSubview(view)
            if view === statusStack {
                view.widthAnchor.constraint(lessThanOrEqualTo: pane.widthAnchor).isActive = true
            } else {
                view.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
            }
        }
    }

    private var currentSplitRatio: CGFloat {
        let originalExtent = splitView.isVertical ? originalPane.frame.width : originalPane.frame.height
        let resultExtent = splitView.isVertical ? resultPane.frame.width : resultPane.frame.height
        let totalExtent = originalExtent + resultExtent
        guard totalExtent > 0 else { return currentLayout.defaultSplitRatio }
        return originalExtent / totalExtent
    }

    private func applyPendingSplitResetIfPossible() {
        guard shouldResetSplitOnNextLayout,
              splitViewExtent >= minimumPaneExtent * 2 + splitView.dividerThickness else { return }
        shouldResetSplitOnNextLayout = false
        setSplitPosition(ratio: currentLayout.defaultSplitRatio)
    }

    private func setSplitPosition(ratio: CGFloat) {
        let availableExtent = splitViewExtent - splitView.dividerThickness
        guard availableExtent > 0 else { return }
        let minimumRatio = min(0.5, minimumPaneExtent / availableExtent)
        let clampedRatio = min(max(ratio, minimumRatio), 1 - minimumRatio)
        splitView.setPosition(availableExtent * clampedRatio, ofDividerAt: 0)
        splitView.adjustSubviews()
    }

    private var splitViewExtent: CGFloat {
        splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    }

    private var minimumPaneExtent: CGFloat {
        splitView.isVertical
            ? TranslationPanelLayoutPolicy.sideBySideMinimumPaneExtent
            : TranslationPanelLayoutPolicy.compactMinimumPaneExtent
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
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.controlSize = .small
        languagePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        languagePopup.isBordered = false
        languagePopup.toolTip = L10n.text("Target Language")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L10n.copy)
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.isBordered = false
        copyButton.toolTip = L10n.copy
        copyButton.target = self
        copyButton.action = #selector(copyTranslation)
        let stack = NSStackView(views: [label, languagePopup, spacer, copyButton])
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
        PasteboardChangeMonitor.writeOwnText(text)
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
    let layoutMode: TranslationPanelLayoutMode
    let targetContentSize: NSSize
    let isVerticalSplit: Bool
    let originalPaneWidth: CGFloat
    let resultPaneWidth: CGFloat
    let originalPaneHeight: CGFloat
    let resultPaneHeight: CGFloat
    let splitRatio: CGFloat
}
