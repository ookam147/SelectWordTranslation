import Foundation

// MARK: - API 类型枚举

enum APIType: String, CaseIterable {
    case local = "local"
    case cloud = "cloud"
    
    var displayName: String {
        let localizedStrings = LocalizedStrings.shared
        switch self {
        case .local: return localizedStrings.local
        case .cloud: return localizedStrings.cloud
        }
    }
}

// MARK: - 目标语言

struct TargetLanguage: Identifiable, Equatable {
    let id: String           // 英文标识
    let nativeName: String   // 原生语言名称
    let chineseName: String  // 简体中文名称
    
    var displayName: String {
        return "\(chineseName) (\(nativeName))"
    }
    
    // 常用语言列表
    static let languages: [TargetLanguage] = [
        TargetLanguage(id: "zh-CN", nativeName: "简体中文", chineseName: "简体中文"),
        TargetLanguage(id: "zh-TW", nativeName: "繁體中文", chineseName: "繁体中文"),
        TargetLanguage(id: "en", nativeName: "English", chineseName: "英语"),
        TargetLanguage(id: "ja", nativeName: "日本語", chineseName: "日语"),
        TargetLanguage(id: "ko", nativeName: "한국어", chineseName: "韩语"),
        TargetLanguage(id: "es", nativeName: "Español", chineseName: "西班牙语"),
        TargetLanguage(id: "de", nativeName: "Deutsch", chineseName: "德语"),
        TargetLanguage(id: "fr", nativeName: "Français", chineseName: "法语"),
        TargetLanguage(id: "pt", nativeName: "Português", chineseName: "葡萄牙语"),
        TargetLanguage(id: "ru", nativeName: "Русский", chineseName: "俄语"),
        TargetLanguage(id: "ar", nativeName: "العربية", chineseName: "阿拉伯语"),
        TargetLanguage(id: "it", nativeName: "Italiano", chineseName: "意大利语"),
        TargetLanguage(id: "nl", nativeName: "Nederlands", chineseName: "荷兰语"),
        TargetLanguage(id: "pl", nativeName: "Polski", chineseName: "波兰语"),
        TargetLanguage(id: "th", nativeName: "ไทย", chineseName: "泰语"),
        TargetLanguage(id: "vi", nativeName: "Tiếng Việt", chineseName: "越南语"),
        TargetLanguage(id: "id", nativeName: "Indonesia", chineseName: "印尼语"),
        TargetLanguage(id: "ms", nativeName: "Melayu", chineseName: "马来语"),
        TargetLanguage(id: "tr", nativeName: "Türkçe", chineseName: "土耳其语"),
        TargetLanguage(id: "hi", nativeName: "हिन्दी", chineseName: "印地语"),
    ]
    
    static let defaultLanguage = languages[0]  // 默认简体中文
    
    static let targetLanguageKey = "targetLanguage"
    
    static func load() -> TargetLanguage {
        let id = UserDefaults.standard.string(forKey: targetLanguageKey) ?? "zh-CN"
        return languages.first { $0.id == id } ?? defaultLanguage
    }
    
    static func save(_ language: TargetLanguage) {
        UserDefaults.standard.set(language.id, forKey: targetLanguageKey)
    }
}

// MARK: - 预设服务商

struct APIPreset: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var baseURL: String
    var defaultModel: String
    var isBuiltIn: Bool  // 是否为内置预设（不可删除）
    
    // 内置预设 - 只保留 DeepSeek
    static let builtInPresets: [APIPreset] = [
        APIPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1/chat/completions", defaultModel: "deepseek-chat", isBuiltIn: true),
    ]
}

// MARK: - 预设管理器

class PresetManager: ObservableObject {
    static let shared = PresetManager()
    static let userPresetsKey = "userAPIPresets"
    static let apiKeysPrefix = "apiKey_"     // 每个预设的 API Key 前缀
    static let modelNamesPrefix = "modelName_"  // 每个预设的 Model Name 前缀
    
    @Published var allPresets: [APIPreset] = []
    
    private init() {
        loadPresets()
    }
    
    /// 加载所有预设（内置 + 用户自定义）
    func loadPresets() {
        var presets = APIPreset.builtInPresets
        
        // 加载用户自定义预设
        if let data = UserDefaults.standard.data(forKey: PresetManager.userPresetsKey),
           let userPresets = try? JSONDecoder().decode([APIPreset].self, from: data) {
            presets.append(contentsOf: userPresets)
        }
        
        allPresets = presets
    }
    
    /// 添加用户自定义预设
    func addPreset(name: String, baseURL: String, defaultModel: String) {
        let newPreset = APIPreset(
            id: UUID().uuidString,
            name: name,
            baseURL: baseURL,
            defaultModel: defaultModel,
            isBuiltIn: false
        )
        
        allPresets.append(newPreset)
        saveUserPresets()
    }
    
    /// 删除用户自定义预设
    func deletePreset(_ preset: APIPreset) {
        guard !preset.isBuiltIn else { return }  // 不能删除内置预设
        allPresets.removeAll { $0.id == preset.id }
        // 同时删除该预设的 API Key 和 Model Name
        deleteAPIKey(for: preset.baseURL)
        deleteModelName(for: preset.baseURL)
        saveUserPresets()
    }
    
    /// 保存用户自定义预设到 UserDefaults
    private func saveUserPresets() {
        let userPresets = allPresets.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(userPresets) {
            UserDefaults.standard.set(data, forKey: PresetManager.userPresetsKey)
        }
    }
    
    // MARK: - 每个预设独立的 API Key 存储
    
    /// 获取指定 URL 对应的 API Key
    func getAPIKey(for baseURL: String) -> String {
        let key = PresetManager.apiKeysPrefix + baseURL.hashValue.description
        return UserDefaults.standard.string(forKey: key) ?? ""
    }
    
    /// 保存指定 URL 对应的 API Key
    func setAPIKey(_ apiKey: String, for baseURL: String) {
        let key = PresetManager.apiKeysPrefix + baseURL.hashValue.description
        UserDefaults.standard.set(apiKey, forKey: key)
    }
    
    /// 删除指定 URL 对应的 API Key
    func deleteAPIKey(for baseURL: String) {
        let key = PresetManager.apiKeysPrefix + baseURL.hashValue.description
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    // MARK: - 每个预设独立的 Model Name 存储
    
    /// 获取指定 URL 对应的 Model Name（优先用户保存的，否则用预设默认值）
    func getModelName(for baseURL: String, defaultValue: String = "") -> String {
        let key = PresetManager.modelNamesPrefix + baseURL.hashValue.description
        return UserDefaults.standard.string(forKey: key) ?? defaultValue
    }
    
    /// 保存指定 URL 对应的 Model Name
    func setModelName(_ modelName: String, for baseURL: String) {
        let key = PresetManager.modelNamesPrefix + baseURL.hashValue.description
        UserDefaults.standard.set(modelName, forKey: key)
    }
    
    /// 删除指定 URL 对应的 Model Name
    func deleteModelName(for baseURL: String) {
        let key = PresetManager.modelNamesPrefix + baseURL.hashValue.description
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - 翻译服务

class TranslationService {
    private var baseURL: String
    private var apiKey: String
    private var modelName: String
    private var apiType: APIType
    private let session: URLSession
    
    // UserDefaults 键名
    static let apiAddressKey = "apiAddress"
    static let apiKeyKey = "apiKey"
    static let modelNameKey = "modelName"
    static let apiTypeKey = "apiType"
    static let defaultAPIAddress = "http://127.0.0.1:1234/v1/chat/completions"
    
    init() {
        self.baseURL = UserDefaults.standard.string(forKey: TranslationService.apiAddressKey) 
            ?? TranslationService.defaultAPIAddress
        self.apiKey = UserDefaults.standard.string(forKey: TranslationService.apiKeyKey) ?? ""
        self.modelName = UserDefaults.standard.string(forKey: TranslationService.modelNameKey) ?? ""
        
        let typeString = UserDefaults.standard.string(forKey: TranslationService.apiTypeKey) ?? "local"
        self.apiType = APIType(rawValue: typeString) ?? .local
        
        self.session = URLSession.shared
    }
    
    // MARK: - 配置更新
    
    func updateConfig(baseURL: String, apiKey: String, modelName: String, apiType: APIType) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.apiType = apiType
        
        UserDefaults.standard.set(baseURL, forKey: TranslationService.apiAddressKey)
        UserDefaults.standard.set(apiKey, forKey: TranslationService.apiKeyKey)
        UserDefaults.standard.set(modelName, forKey: TranslationService.modelNameKey)
        UserDefaults.standard.set(apiType.rawValue, forKey: TranslationService.apiTypeKey)
    }
    
    func getCurrentConfig() -> (baseURL: String, apiKey: String, modelName: String, apiType: APIType) {
        return (baseURL, apiKey, modelName, apiType)
    }
    
    // MARK: - 状态检查
    
    func checkStatus() async throws -> Bool {
        // 如果 baseURL 已包含完整路径，直接使用；否则尝试添加 /models 检查端点
        let checkURL = baseURL.hasSuffix("/completions") 
            ? baseURL.replacingOccurrences(of: "/chat/completions", with: "/models")
            : "\(baseURL)/models"
        
        guard let url = URL(string: checkURL) else {
            return false
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        
        // 云端模式添加认证头
        if apiType == .cloud && !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }
        
        return httpResponse.statusCode == 200
    }
    
    // MARK: - 验证模型（云端模式）
    
    /// 通过发送测试请求验证模型是否存在且可用
    func validateModel() async throws -> Bool {
        guard apiType == .cloud, !modelName.isEmpty else {
            return true  // 本地模式或未指定模型时跳过验证
        }
        
        guard let url = URL(string: baseURL) else {
            throw TranslationError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10  // 较短的超时时间用于验证
        
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        // 发送一个简单的测试消息
        let messages = [
            ChatMessage(role: "user", content: "test")
        ]
        
        let body = ChatCompletionRequest(
            model: modelName,
            messages: messages,
            temperature: 0.0,
            max_tokens: 5  // 只需要很少的 token
        )
        
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }
        
        // 检查状态码
        if httpResponse.statusCode != 200 {
            // 尝试解析错误信息以提供更详细的反馈
            if let errorResponse = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw TranslationError.apiError(errorResponse.error.message)
            }
            throw TranslationError.httpError(httpResponse.statusCode)
        }
        
        return true
    }
    
    // MARK: - 模型列表（本地模式）
    
    func listModels() async throws -> [APIModel] {
        guard apiType == .local else {
            // 云端模式返回用户指定的模型
            if !modelName.isEmpty {
                return [APIModel(id: modelName, object: nil, created: nil)]
            }
            return []
        }
        
        let modelsURL = baseURL.hasSuffix("/completions") 
            ? baseURL.replacingOccurrences(of: "/chat/completions", with: "/models")
            : "\(baseURL)/models"
        
        guard let url = URL(string: modelsURL) else {
            throw TranslationError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return response.data
    }
    
    // MARK: - 翻译
    
    func translate(_ text: String, model: String? = nil) async throws -> String {
        let selectedModel: String
        
        if apiType == .cloud {
            // 云端模式使用配置的模型名
            selectedModel = model ?? modelName
            guard !selectedModel.isEmpty else {
                throw TranslationError.noModelSpecified
            }
        } else {
            // 本地模式自动检测模型
            if let model = model {
                selectedModel = model
            } else {
                let models = try await listModels()
                guard let firstModel = models.first else {
                    throw TranslationError.noModelLoaded
                }
                selectedModel = firstModel.id
            }
        }
        
        // 使用 Chat Completions API（云端和本地都兼容）
        return try await translateWithChatAPI(text: text, model: selectedModel)
    }
    
    private func translateWithChatAPI(text: String, model: String) async throws -> String {
        // 直接使用用户提供的完整 URL
        guard let url = URL(string: baseURL) else {
            throw TranslationError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        
        // 添加认证头（云端必需，本地可选）
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        // ⭐ 加载用户选择的目标语言
        let targetLanguage = TargetLanguage.load()
        let languageName = targetLanguage.nativeName
        
        let messages = [
            ChatMessage(role: "system", content: "You are a professional translator. Translate the following text to \(languageName). Only output the translation, nothing else."),
            ChatMessage(role: "user", content: text)
        ]
        
        let body = ChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: 0.0,
            max_tokens: 1024
        )
        
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await session.data(for: request)
        
        // 检查 HTTP 状态码
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            // 尝试解析错误信息
            if let errorResponse = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw TranslationError.apiError(errorResponse.error.message)
            }
            throw TranslationError.httpError(httpResponse.statusCode)
        }
        
        let chatResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        
        guard let firstChoice = chatResponse.choices.first else {
            throw TranslationError.emptyResponse
        }
        
        return firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 数据模型

struct ModelsResponse: Codable {
    let data: [APIModel]
}

struct APIModel: Codable, Identifiable {
    let id: String
    let object: String?
    let created: Int?
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let max_tokens: Int
}

struct ChatCompletionResponse: Codable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [ChatChoice]
}

struct ChatChoice: Codable {
    let index: Int?
    let message: ChatMessage
    let finish_reason: String?
}

struct APIErrorResponse: Codable {
    let error: APIError
}

struct APIError: Codable {
    let message: String
    let type: String?
    let code: String?
}

// MARK: - 错误类型

enum TranslationError: LocalizedError {
    case noModelLoaded
    case noModelSpecified
    case emptyResponse
    case invalidURL
    case apiError(String)
    case httpError(Int)
    
    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No model loaded in LM Studio"
        case .noModelSpecified:
            return "Please specify a model name for cloud API"
        case .emptyResponse:
            return "Empty response from API"
        case .invalidURL:
            return "Invalid API URL"
        case .apiError(let message):
            return message
        case .httpError(let code):
            return "HTTP Error: \(code)"
        }
    }
}
