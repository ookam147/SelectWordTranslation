import AppKit
import OSLog
import SwiftUI

@main
struct SelectWordTranslationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        coordinator = nil
    }
}

@MainActor
final class AppCoordinator: NSObject, HotkeyManagerDelegate {
    private let logger = Logger(subsystem: "com.zwalking.SelectWordTranslation", category: "Application")
    private let modelManager: ModelManager
    private let hotkeyManager: HotkeyManager
    private let selectionProvider: TextSelectionProviding
    private let translationService: TranslationServicing
    private let popupManager: PopupWindowManager
    private let popupViewModel: TranslationPopupViewModel
    private let menuBarManager: MenuBarManager
    private var translationTask: Task<Void, Never>?
    private let requestTracker = RequestTracker()
    private var currentText = ""
    private var currentPosition = NSPoint.zero

    override init() {
        let credentials = KeychainCredentialStore()
        let presets = PresetManager()
        let modelManager = ModelManager(credentials: credentials, presetManager: presets)
        let hotkeyManager = HotkeyManager()
        let service = TranslationService()
        self.modelManager = modelManager
        self.hotkeyManager = hotkeyManager
        selectionProvider = TextSelectionManager()
        translationService = service
        popupManager = PopupWindowManager()
        popupViewModel = TranslationPopupViewModel(
            originalText: "",
            state: .idle,
            modelName: "",
            selectedLanguage: modelManager.targetLanguage
        )
        menuBarManager = MenuBarManager(modelManager: modelManager, hotkeyManager: hotkeyManager, translationService: service)
        super.init()
    }

    func start() {
        hotkeyManager.delegate = self
        do {
            try hotkeyManager.start()
        } catch {
            presentError(error)
        }
        menuBarManager.onTranslateSelection = { [weak self] in self?.didTriggerHotkey() }
        menuBarManager.start()
        popupManager.onDidClose = { [weak self] in self?.cancelTranslation() }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        logger.info("Application started")
    }

    func stop() {
        cancelTranslation()
        popupManager.dispose()
        menuBarManager.stop()
        hotkeyManager.stop()
        NSApp.servicesProvider = nil
    }

    func didTriggerHotkey() {
        startSelectionTranslation(at: NSEvent.mouseLocation)
    }

    @objc(translateSelection:userData:error:)
    func translateSelection(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = L10n.noSelection as NSString
            return
        }
        startTranslation(text: text, language: modelManager.targetLanguage, at: NSEvent.mouseLocation, preservePosition: false)
    }

    private func startSelectionTranslation(at position: NSPoint) {
        cancelTranslation()
        let requestID = requestTracker.begin()
        translationTask = Task { [weak self] in
            guard let self else { return }
            var selectedText: String?
            do {
                let text = try await selectionProvider.selectedText()
                selectedText = text
                try Task.checkCancellation()
                try await performTranslation(
                    requestID: requestID,
                    text: text,
                    language: modelManager.targetLanguage,
                    position: position,
                    preservePosition: false
                )
            } catch is CancellationError {
                return
            } catch {
                guard requestTracker.isCurrent(requestID) else { return }
                if let selectedText {
                    showError(
                        error.localizedDescription,
                        text: selectedText,
                        language: modelManager.targetLanguage,
                        at: position,
                        preservePosition: false
                    )
                    finish(requestID: requestID)
                } else {
                    requestTracker.finish(requestID)
                    translationTask = nil
                    presentError(error)
                }
            }
        }
    }

    private func startTranslation(text: String, language: TargetLanguage, at position: NSPoint, preservePosition: Bool) {
        cancelTranslation(hidePopup: false)
        let requestID = requestTracker.begin()
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await performTranslation(
                    requestID: requestID,
                    text: text,
                    language: language,
                    position: position,
                    preservePosition: preservePosition
                )
            } catch is CancellationError {
                return
            } catch {
                guard requestTracker.isCurrent(requestID) else { return }
                showError(error.localizedDescription, text: text, language: language, at: position, preservePosition: preservePosition)
                finish(requestID: requestID)
            }
        }
    }

    private func performTranslation(
        requestID: UUID,
        text: String,
        language: TargetLanguage,
        position: NSPoint,
        preservePosition: Bool
    ) async throws {
        let validatedText = try SelectionValidator.validated(text)
        let configuration = modelManager.configuration
        if configuration.apiType == .cloud && configuration.apiKey.isEmpty {
            throw TranslationError.apiError(L10n.text("An API key is required."))
        }
        let request = TranslationRequest(id: requestID, text: validatedText, targetLanguage: language, configuration: configuration)
        currentText = validatedText
        currentPosition = position
        modelManager.setTargetLanguage(language)

        popupViewModel.originalText = validatedText
        popupViewModel.state = .loading
        popupViewModel.modelName = configuration.modelName
        popupViewModel.selectedLanguage = language
        popupViewModel.onLanguageChange = { [weak self] newLanguage in
            guard let self else { return }
            self.startTranslation(text: self.currentText, language: newLanguage, at: self.currentPosition, preservePosition: true)
        }
        popupManager.show(viewModel: popupViewModel, at: position, preservePosition: preservePosition)

        let translated = try await translationService.translate(request)
        try Task.checkCancellation()
        guard requestTracker.isCurrent(requestID) else { return }
        popupViewModel.state = .result(translated)
        popupManager.refreshLayout()
        finish(requestID: requestID)
    }

    private func showError(_ message: String, text: String, language: TargetLanguage, at position: NSPoint, preservePosition: Bool) {
        popupViewModel.originalText = text
        popupViewModel.state = .error(message)
        popupViewModel.modelName = modelManager.configuration.modelName
        popupViewModel.selectedLanguage = language
        popupViewModel.onLanguageChange = { [weak self] newLanguage in
            self?.startTranslation(text: text, language: newLanguage, at: position, preservePosition: true)
        }
        popupManager.show(viewModel: popupViewModel, at: position, preservePosition: preservePosition)
    }

    private func finish(requestID: UUID) {
        guard requestTracker.isCurrent(requestID) else { return }
        requestTracker.finish(requestID)
        translationTask = nil
    }

    private func cancelTranslation(hidePopup: Bool = false) {
        translationTask?.cancel()
        translationTask = nil
        requestTracker.cancel()
        if hidePopup { popupManager.hide(notify: false) }
    }

    private func presentError(_ error: Error) {
        logger.error("Operation failed: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.error
        alert.informativeText = error.localizedDescription
        if (error as? TranslationError) == .accessibilityPermissionRequired {
            alert.addButton(withTitle: L10n.openSettings)
            alert.addButton(withTitle: L10n.cancel)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.runModal()
        }
    }
}
