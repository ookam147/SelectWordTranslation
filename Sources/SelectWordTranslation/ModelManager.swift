import Combine
import Foundation

enum ConnectionState: Equatable, Sendable {
    case notChecked, testing, ready
    case failed(String)

    var displayText: String {
        switch self {
        case .notChecked: L10n.notChecked
        case .testing: L10n.testing
        case .ready: L10n.ready
        case .failed(let message): L10n.failed(message)
        }
    }

    var isReady: Bool { self == .ready }
}

@MainActor
final class ModelManager: ObservableObject {
    static let apiAddressKey = "apiAddress"
    static let apiKeyKey = "apiKey"
    static let modelNameKey = "modelName"
    static let apiTypeKey = "apiType"
    static let providerIDKey = "providerID"
    static let enablesThinkingKey = "enablesThinking"

    @Published private(set) var configuration: TranslationConfiguration
    @Published private(set) var connectionState: ConnectionState = .notChecked
    @Published var targetLanguage: TargetLanguage

    let presetManager: PresetManager
    private let defaults: UserDefaults
    private let credentials: CredentialStore

    init(
        defaults: UserDefaults = .standard,
        credentials: CredentialStore = KeychainCredentialStore(),
        presetManager: PresetManager? = nil
    ) {
        self.defaults = defaults
        self.credentials = credentials
        let presets = presetManager ?? PresetManager(defaults: defaults)
        self.presetManager = presets
        targetLanguage = TargetLanguage.load(defaults: defaults)

        let baseURL = defaults.string(forKey: Self.apiAddressKey) ?? TranslationConfiguration.defaultLocal.baseURL
        let apiType = APIType(rawValue: defaults.string(forKey: Self.apiTypeKey) ?? "local") ?? .local
        let providerID = defaults.string(forKey: Self.providerIDKey)
            ?? (apiType == .local ? "local" : presets.matchingPreset(for: baseURL)?.id ?? "custom:\(baseURL)")
        let initial = TranslationConfiguration(
            baseURL: baseURL,
            apiKey: "",
            modelName: defaults.string(forKey: Self.modelNameKey) ?? "",
            apiType: apiType,
            providerID: providerID,
            enablesThinking: defaults.bool(forKey: Self.enablesThinkingKey)
        )
        CredentialMigrator.migrateIfNeeded(defaults: defaults, store: credentials, configuration: initial, presets: presets.allPresets)
        var loaded = initial
        loaded.apiKey = (try? credentials.apiKey(for: providerID)) ?? ""
        configuration = loaded
    }

    func apply(configuration newValue: TranslationConfiguration) throws {
        _ = try APIEndpointValidator.validatedChatURL(from: newValue.baseURL)
        if newValue.apiType == .cloud && newValue.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TranslationError.noModelSpecified
        }
        try credentials.setAPIKey(newValue.apiKey, for: newValue.providerID)
        defaults.set(newValue.baseURL, forKey: Self.apiAddressKey)
        defaults.set(newValue.modelName, forKey: Self.modelNameKey)
        defaults.set(newValue.apiType.rawValue, forKey: Self.apiTypeKey)
        defaults.set(newValue.providerID, forKey: Self.providerIDKey)
        defaults.set(newValue.enablesThinking, forKey: Self.enablesThinkingKey)
        defaults.removeObject(forKey: Self.apiKeyKey)
        configuration = newValue
        connectionState = .notChecked
    }

    func configuration(for preset: APIPreset, apiType: APIType = .cloud) -> TranslationConfiguration {
        TranslationConfiguration(
            baseURL: preset.baseURL,
            apiKey: (try? credentials.apiKey(for: preset.id)) ?? "",
            modelName: preset.defaultModel,
            apiType: apiType,
            providerID: preset.id,
            enablesThinking: configuration.enablesThinking
        )
    }

    func deletePreset(id: String) throws {
        try credentials.removeAPIKey(for: id)
        presetManager.deletePreset(id: id)
    }

    func setTargetLanguage(_ language: TargetLanguage) {
        targetLanguage = language
        TargetLanguage.save(language, defaults: defaults)
    }

    func testConnection(using service: TranslationServicing, draft: TranslationConfiguration) async {
        connectionState = .testing
        do {
            _ = try APIEndpointValidator.validatedChatURL(from: draft.baseURL)
            try await service.testConnection(configuration: draft)
            guard !Task.isCancelled else { return }
            connectionState = .ready
        } catch is CancellationError {
            connectionState = .notChecked
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }
}
