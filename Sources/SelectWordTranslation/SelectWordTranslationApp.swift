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
    private let preferences: AppPreferences
    private let hotkeyManager: HotkeyManager
    private let selectionProvider: TextSelectionProviding
    private let translationService: TranslationServicing
    private let popupManager: PopupWindowManager
    private let popupViewModel: TranslationPopupViewModel
    private let menuBarManager: MenuBarManager
    private var translationTask: Task<Void, Never>?
    private let requestTracker = RequestTracker()
    private let translationCache = TranslationCache()
    private var lastPartialRefresh = Date.distantPast
    private var currentText = ""
    private var currentPosition = NSPoint.zero

    override init() {
        let credentials = KeychainCredentialStore()
        let presets = PresetManager()
        let modelManager = ModelManager(credentials: credentials, presetManager: presets)
        let preferences = AppPreferences()
        let hotkeyManager = HotkeyManager()
        let service = TranslationService()
        self.modelManager = modelManager
        self.preferences = preferences
        self.hotkeyManager = hotkeyManager
        selectionProvider = TextSelectionManager { [weak preferences] in
            preferences?.selectionSettings ?? .default
        }
        translationService = service
        popupManager = PopupWindowManager()
        popupViewModel = TranslationPopupViewModel(
            originalText: "",
            state: .idle,
            modelName: "",
            selectedLanguage: modelManager.targetLanguage
        )
        menuBarManager = MenuBarManager(
            modelManager: modelManager,
            preferences: preferences,
            hotkeyManager: hotkeyManager,
            translationService: service
        )
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
        startTranslation(
            text: text,
            language: automaticLanguage(for: text),
            at: NSEvent.mouseLocation,
            preservePosition: false,
            persistLanguage: false
        )
    }

    private func automaticLanguage(for text: String) -> TargetLanguage {
        let preferred = modelManager.targetLanguage
        guard preferences.autoSwitchLanguage else { return preferred }
        return TargetLanguageRouter.effectiveLanguage(for: text, preferred: preferred)
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
                    language: automaticLanguage(for: text),
                    position: position,
                    preservePosition: false,
                    persistLanguage: false
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

    private func startTranslation(
        text: String,
        language: TargetLanguage,
        at position: NSPoint,
        preservePosition: Bool,
        persistLanguage: Bool
    ) {
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
                    preservePosition: preservePosition,
                    persistLanguage: persistLanguage
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
        preservePosition: Bool,
        persistLanguage: Bool
    ) async throws {
        let validatedText = try SelectionValidator.validated(text)
        let configuration = modelManager.configuration
        if configuration.apiType == .cloud && configuration.apiKey.isEmpty {
            throw TranslationError.apiError(L10n.text("An API key is required."))
        }
        let request = TranslationRequest(id: requestID, text: validatedText, targetLanguage: language, configuration: configuration)
        currentText = validatedText
        currentPosition = position
        if persistLanguage { modelManager.setTargetLanguage(language) }

        popupViewModel.originalText = validatedText
        popupViewModel.modelName = configuration.modelName
        popupViewModel.selectedLanguage = language
        popupViewModel.onLanguageChange = { [weak self] newLanguage in
            guard let self else { return }
            self.startTranslation(
                text: self.currentText,
                language: newLanguage,
                at: self.currentPosition,
                preservePosition: true,
                persistLanguage: true
            )
        }

        let cacheKey = TranslationCacheKey(text: validatedText, language: language, configuration: configuration)
        if let cacheKey, let cached = translationCache.value(for: cacheKey) {
            popupViewModel.state = .result(cached)
            popupManager.show(viewModel: popupViewModel, at: position, preservePosition: preservePosition)
            finish(requestID: requestID)
            return
        }

        popupViewModel.state = .loading
        popupManager.show(viewModel: popupViewModel, at: position, preservePosition: preservePosition)

        lastPartialRefresh = .distantPast
        let translated = try await translationService.translate(request) { [weak self] progress in
            self?.showProgress(progress, requestID: requestID)
        }
        try Task.checkCancellation()
        guard requestTracker.isCurrent(requestID) else { return }
        if let cacheKey { translationCache.insert(translated, for: cacheKey) }
        popupViewModel.state = .result(translated)
        popupManager.refreshLayout()
        finish(requestID: requestID)
    }

    private func showProgress(_ progress: TranslationProgress, requestID: UUID) {
        guard requestTracker.isCurrent(requestID) else { return }
        guard case .text(let partial) = progress else {
            popupViewModel.state = .thinking
            popupManager.refreshLayout()
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastPartialRefresh) >= 0.08 else { return }
        lastPartialRefresh = now
        popupViewModel.state = .streaming(partial)
        popupManager.refreshLayout()
    }

    private func showError(_ message: String, text: String, language: TargetLanguage, at position: NSPoint, preservePosition: Bool) {
        popupViewModel.originalText = text
        popupViewModel.state = .error(message)
        popupViewModel.modelName = modelManager.configuration.modelName
        popupViewModel.selectedLanguage = language
        popupViewModel.onLanguageChange = { [weak self] newLanguage in
            self?.startTranslation(
                text: text,
                language: newLanguage,
                at: position,
                preservePosition: true,
                persistLanguage: true
            )
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
        // macOS already shows its own Accessibility permission prompt; a second alert would only duplicate it.
        if (error as? TranslationError) == .accessibilityPermissionRequired { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.error
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
