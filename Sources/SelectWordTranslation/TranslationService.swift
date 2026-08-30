import Combine
import Foundation

enum APIType: String, Codable, CaseIterable, Sendable { case local, cloud }

enum SelectionValidator {
    static let maximumCharacterCount = 20_000

    static func validated(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.noSelection }
        guard trimmed.count <= maximumCharacterCount else { throw TranslationError.selectionTooLong }
        return trimmed
    }
}

struct TargetLanguage: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let nativeName: String
    let chineseName: String
    var displayName: String { "\(nativeName) · \(chineseName)" }

    static let languages: [TargetLanguage] = [
        .init(id: "zh-CN", nativeName: "简体中文", chineseName: "简体中文"),
        .init(id: "en", nativeName: "English", chineseName: "英语"),
        .init(id: "ja", nativeName: "日本語", chineseName: "日语"),
        .init(id: "ko", nativeName: "한국어", chineseName: "韩语"),
        .init(id: "fr", nativeName: "Français", chineseName: "法语"),
        .init(id: "de", nativeName: "Deutsch", chineseName: "德语"),
        .init(id: "es", nativeName: "Español", chineseName: "西班牙语"),
        .init(id: "it", nativeName: "Italiano", chineseName: "意大利语"),
        .init(id: "pt", nativeName: "Português", chineseName: "葡萄牙语"),
        .init(id: "ru", nativeName: "Русский", chineseName: "俄语"),
        .init(id: "ar", nativeName: "العربية", chineseName: "阿拉伯语"),
        .init(id: "th", nativeName: "ไทย", chineseName: "泰语"),
        .init(id: "vi", nativeName: "Tiếng Việt", chineseName: "越南语"),
        .init(id: "id", nativeName: "Indonesia", chineseName: "印尼语"),
        .init(id: "ms", nativeName: "Melayu", chineseName: "马来语"),
        .init(id: "tr", nativeName: "Türkçe", chineseName: "土耳其语"),
        .init(id: "hi", nativeName: "हिन्दी", chineseName: "印地语")
    ]

    static let defaultLanguage = languages[0]
    static let targetLanguageKey = "targetLanguage"

    static func load(defaults: UserDefaults = .standard) -> TargetLanguage {
        let id = defaults.string(forKey: targetLanguageKey) ?? defaultLanguage.id
        return languages.first { $0.id == id } ?? defaultLanguage
    }

    static func save(_ language: TargetLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.id, forKey: targetLanguageKey)
    }
}

struct APIPreset: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var baseURL: String
    var defaultModel: String
    var isBuiltIn: Bool

    static let builtInPresets: [APIPreset] = [
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1/chat/completions", defaultModel: "deepseek-v4-flash", isBuiltIn: true)
    ]
}

@MainActor
final class PresetManager: ObservableObject {
    static let userPresetsKey = "userAPIPresets"
    @Published private(set) var allPresets: [APIPreset]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let custom = defaults.data(forKey: Self.userPresetsKey)
            .flatMap { try? JSONDecoder().decode([APIPreset].self, from: $0) } ?? []
        allPresets = APIPreset.builtInPresets + custom.filter { !$0.isBuiltIn }
    }

    @discardableResult
    func addPreset(name: String, baseURL: String, defaultModel: String) -> APIPreset {
        let preset = APIPreset(id: UUID().uuidString, name: name, baseURL: baseURL, defaultModel: defaultModel, isBuiltIn: false)
        allPresets.append(preset)
        save()
        return preset
    }

    func deletePreset(id: String) {
        allPresets.removeAll { $0.id == id && !$0.isBuiltIn }
        save()
    }

    func preset(id: String) -> APIPreset? { allPresets.first { $0.id == id } }
    func matchingPreset(for baseURL: String) -> APIPreset? { allPresets.first { $0.baseURL == baseURL } }

    private func save() {
        if let data = try? JSONEncoder().encode(allPresets.filter { !$0.isBuiltIn }) {
            defaults.set(data, forKey: Self.userPresetsKey)
        }
    }
}

struct TranslationConfiguration: Codable, Equatable, Sendable {
    var baseURL: String
    var apiKey: String
    var modelName: String
    var apiType: APIType
    var providerID: String

    static let defaultLocal = TranslationConfiguration(
        baseURL: "http://127.0.0.1:1234/v1/chat/completions",
        apiKey: "",
        modelName: "",
        apiType: .local,
        providerID: "local"
    )
}

struct TranslationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let targetLanguage: TargetLanguage
    let configuration: TranslationConfiguration

    init(id: UUID = UUID(), text: String, targetLanguage: TargetLanguage, configuration: TranslationConfiguration) {
        self.id = id
        self.text = text
        self.targetLanguage = targetLanguage
        self.configuration = configuration
    }
}

enum TranslationState: Equatable, Sendable {
    case idle, loading
    case result(String)
    case error(String)
}

@MainActor
final class RequestTracker {
    private(set) var activeID: UUID?

    func begin() -> UUID {
        let id = UUID()
        activeID = id
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { activeID == id }
    func finish(_ id: UUID) { if activeID == id { activeID = nil } }
    func cancel() { activeID = nil }
}

protocol TranslationServicing: Sendable {
    func testConnection(configuration: TranslationConfiguration) async throws
    func translate(_ request: TranslationRequest) async throws -> String
}

enum APIEndpointValidator {
    static func validatedChatURL(from value: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { throw TranslationError.invalidURL }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else { throw TranslationError.insecureRemoteURL }
        return url
    }

    static func modelsURL(from chatURL: URL) throws -> URL {
        guard var components = URLComponents(url: chatURL, resolvingAgainstBaseURL: false) else { throw TranslationError.invalidURL }
        let path = components.path
        if path.hasSuffix("/chat/completions") {
            components.path = String(path.dropLast("/chat/completions".count)) + "/models"
        } else if path.hasSuffix("/completions") {
            components.path = String(path.dropLast("/completions".count)) + "/models"
        } else {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = trimmed.isEmpty ? "/models" : "/\(trimmed)/models"
        }
        guard let url = components.url else { throw TranslationError.invalidURL }
        return url
    }
}

final class TranslationService: TranslationServicing, @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func testConnection(configuration: TranslationConfiguration) async throws {
        let chatURL = try APIEndpointValidator.validatedChatURL(from: configuration.baseURL)
        var request = URLRequest(url: try APIEndpointValidator.modelsURL(from: chatURL))
        request.timeoutInterval = 8
        applyAuthorization(configuration.apiKey, to: &request)
        let (_, response) = try await session.data(for: request)
        try validate(response: response, data: nil)
    }

    func translate(_ request: TranslationRequest) async throws -> String {
        try Task.checkCancellation()
        let configuration = request.configuration
        let url = try APIEndpointValidator.validatedChatURL(from: configuration.baseURL)
        let model = try await resolvedModel(configuration: configuration)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(configuration.apiKey, to: &urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: "You are a professional translator. Translate the following text to \(request.targetLanguage.nativeName). Only output the translation."),
                .init(role: "user", content: request.text)
            ],
            temperature: 0,
            maxTokens: 4096
        ))
        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()
        try validate(response: response, data: data)
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else { throw TranslationError.invalidResponse }
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return content
    }

    private func resolvedModel(configuration: TranslationConfiguration) async throws -> String {
        let configured = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        guard configuration.apiType == .local else { throw TranslationError.noModelSpecified }
        let chatURL = try APIEndpointValidator.validatedChatURL(from: configuration.baseURL)
        var request = URLRequest(url: try APIEndpointValidator.modelsURL(from: chatURL))
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard let model = try JSONDecoder().decode(ModelsResponse.self, from: data).data.first?.id else { throw TranslationError.noModelLoaded }
        return model
    }

    private func applyAuthorization(_ apiKey: String, to request: inout URLRequest) {
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let data, let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw TranslationError.apiError(String(apiError.error.message.prefix(500)))
            }
            throw TranslationError.httpError(http.statusCode)
        }
    }
}

struct ModelsResponse: Codable, Sendable { let data: [APIModel] }
struct APIModel: Codable, Identifiable, Sendable { let id: String }
private struct ChatMessage: Codable, Sendable { let role: String; let content: String }
private struct ChatCompletionRequest: Codable, Sendable {
    let model: String; let messages: [ChatMessage]; let temperature: Double; let maxTokens: Int
    enum CodingKeys: String, CodingKey { case model, messages, temperature; case maxTokens = "max_tokens" }
}
private struct ChatCompletionResponse: Codable, Sendable { let choices: [ChatChoice] }
private struct ChatChoice: Codable, Sendable { let message: ChatMessage }
private struct APIErrorResponse: Codable, Sendable { let error: APIError }
private struct APIError: Codable, Sendable { let message: String }

enum TranslationError: LocalizedError, Equatable, Sendable {
    case noSelection, selectionTooLong, accessibilityPermissionRequired
    case noModelLoaded, noModelSpecified, emptyResponse, invalidURL, insecureRemoteURL, invalidResponse
    case apiError(String), httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noSelection: L10n.noSelection
        case .selectionTooLong: L10n.selectionTooLong
        case .accessibilityPermissionRequired: L10n.accessibilityRequired
        case .noModelLoaded: L10n.text("No model is loaded.")
        case .noModelSpecified: L10n.text("A model name is required.")
        case .emptyResponse: L10n.text("The translation response is empty.")
        case .invalidURL: L10n.text("The API URL is invalid.")
        case .insecureRemoteURL: L10n.text("Remote API URLs must use HTTPS.")
        case .invalidResponse: L10n.text("The server returned an invalid response.")
        case .apiError(let message): message
        case .httpError(let status): "HTTP \(status)"
        }
    }
}
