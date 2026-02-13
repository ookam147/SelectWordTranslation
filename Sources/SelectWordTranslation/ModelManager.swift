import Foundation
import Combine

class ModelManager: ObservableObject {
    @Published var statusMessage: String = LocalizedStrings.shared.checking
    @Published var isModelLoaded: Bool = false
    @Published var availableModels: [APIModel] = []
    @Published var selectedModelId: String? = nil
    
    // API 配置
    @Published var currentAPIAddress: String = TranslationService.defaultAPIAddress
    @Published var currentAPIKey: String = ""
    @Published var currentModelName: String = ""
    @Published var currentAPIType: APIType = .local
    
    // 上次刷新时间
    @Published var lastRefreshTime: Date? = nil
    
    private var translationService: TranslationService
    
    // ⭐ 防止重复验证
    private var isValidating: Bool = false
    
    init() {
        self.translationService = TranslationService()
        
        // 加载配置
        let config = translationService.getCurrentConfig()
        self.currentAPIAddress = config.baseURL
        self.currentAPIKey = config.apiKey
        self.currentModelName = config.modelName
        self.currentAPIType = config.apiType
        
        Task {
            await checkStatus()
        }
    }
    
    /// 更新 API 配置
    @MainActor
    func updateConfig(baseURL: String, apiKey: String, modelName: String, apiType: APIType) async {
        currentAPIAddress = baseURL
        currentAPIKey = apiKey
        currentModelName = modelName
        currentAPIType = apiType
        
        translationService.updateConfig(baseURL: baseURL, apiKey: apiKey, modelName: modelName, apiType: apiType)
        await checkStatus()
    }
    
    @MainActor
    func checkStatus() async {
        // ⭐ 防止重复验证（避免浪费 token）
        if isValidating {
            print("⚠️ 验证已在进行中，跳过重复请求")
            return
        }
        
        isValidating = true
        defer { isValidating = false }  // 确保验证完成后重置标志
        
        statusMessage = LocalizedStrings.shared.connecting
        
        do {
            if currentAPIType == .cloud {
                // 云端模式：检查 API 和模型是否可用
                if currentAPIKey.isEmpty {
                    statusMessage = LocalizedStrings.shared.apiKeyRequired
                    isModelLoaded = false
                } else if currentModelName.isEmpty {
                    statusMessage = LocalizedStrings.shared.modelNameRequired
                    isModelLoaded = false
                } else {
                    // ⭐ 真正验证模型是否存在和可用
                    do {
                        let isValid = try await translationService.validateModel()
                        if isValid {
                            isModelLoaded = true
                            selectedModelId = currentModelName
                            statusMessage = LocalizedStrings.shared.readyWithModel(currentModelName)
                        } else {
                            statusMessage = LocalizedStrings.shared.cannotConnectToAPI
                            isModelLoaded = false
                        }
                    } catch let error as TranslationError {
                        // 捕获详细的错误信息
                        switch error {
                        case .apiError(let message):
                            // API 返回的详细错误（如"模型不存在"）
                            statusMessage = "❌ \(message)"
                        case .httpError(let code):
                            statusMessage = "❌ HTTP Error: \(code)"
                        default:
                            statusMessage = "❌ \(error.localizedDescription)"
                        }
                        isModelLoaded = false
                    }
                }
            } else {
                // 本地模式：检测 LM Studio
                let isRunning = try await translationService.checkStatus()
                if isRunning {
                    await loadAvailableModels()
                } else {
                    statusMessage = LocalizedStrings.shared.lmStudioNotRunning
                    isModelLoaded = false
                }
            }
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
            isModelLoaded = false
        }
        
        lastRefreshTime = Date()
    }
    
    @MainActor
    private func loadAvailableModels() async {
        do {
            availableModels = try await translationService.listModels()
            
            if !availableModels.isEmpty {
                isModelLoaded = true
                selectedModelId = availableModels.first?.id
                statusMessage = LocalizedStrings.shared.ready
            } else {
                isModelLoaded = false
                statusMessage = LocalizedStrings.shared.noModelLoaded
            }
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
            isModelLoaded = false
        }
    }
    
    @MainActor
    func generateTranslation(for text: String) async -> String {
        guard isModelLoaded else {
            if currentAPIType == .cloud {
                return "Error: Please configure API Key and Model Name."
            } else {
                return "Error: No model loaded. Please load a model in LM Studio."
            }
        }
        
        do {
            statusMessage = LocalizedStrings.shared.translatingStatus
            let translation = try await translationService.translate(text, model: selectedModelId)
            statusMessage = LocalizedStrings.shared.translationComplete
            return translation
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
            return "Translation error: \(error.localizedDescription)"
        }
    }
}
