import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject var modelManager: ModelManager
    @ObservedObject var presetManager = PresetManager.shared
    @ObservedObject var localizedStrings = LocalizedStrings.shared  // ⭐ 本地化字符串
    var onQuit: () -> Void = {}
    var hotkeyManager: HotkeyManager?  // ⭐ 新增：快捷键管理器引用
    
    // 编辑状态
    @State private var editingAPIAddress: String = ""
    @State private var editingAPIKey: String = ""
    @State private var editingModelName: String = ""
    @State private var selectedAPIType: APIType = .local
    
    // ⭐ 目标语言
    @State private var selectedLanguage: TargetLanguage = TargetLanguage.defaultLanguage
    
    // 分别记住 Local 和 Cloud 模式的地址
    @State private var localAPIAddress: String = "http://127.0.0.1:1234/v1/chat/completions"
    @State private var cloudAPIAddress: String = "https://api.deepseek.com/v1/chat/completions"
    
    // 添加预设弹窗
    @State private var showAddPreset: Bool = false
    @State private var newPresetName: String = ""
    @State private var newPresetURL: String = ""
    @State private var newPresetModel: String = ""
    
    // ⭐ 快捷键设置弹窗
    @State private var showHotkeySettings: Bool = false
    @State private var currentHotkey: HotkeyConfig = HotkeyConfig.default
    
    // ⭐ API Key 可见性
    @State private var isAPIKeyVisible: Bool = false
    
    // 定时器刷新
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题 + 快捷键设置
            HStack {
                Text("SelectWordTranslation")
                    .font(.headline)
                
                Spacer()
                
                // ⭐ 快捷键设置按钮
                Button(action: {
                    showHotkeySettings = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard")
                            .foregroundColor(.secondary)
                        Text(currentHotkey.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("设置快捷键")
                
                // 状态图标
                Image(systemName: modelManager.isModelLoaded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(modelManager.isModelLoaded ? .green : .orange)
            }
            
            Divider()
            
            // API 类型选择
            Picker(localizedStrings.mode, selection: $selectedAPIType) {
                ForEach(APIType.allCases, id: \.self) { type in
                    Text(type == .local ? localizedStrings.local : localizedStrings.cloud).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedAPIType) { newValue in
                // ⭐ 立即保存用户选择的模式
                UserDefaults.standard.set(newValue.rawValue, forKey: TranslationService.apiTypeKey)
                
                // 切换模式时，保存当前 API Key 并恢复目标模式的地址和 Key
                if newValue == .local {
                    // 保存 Cloud 的地址和 Key
                    presetManager.setAPIKey(editingAPIKey, for: cloudAPIAddress)
                    cloudAPIAddress = editingAPIAddress
                    // 恢复 Local 地址
                    editingAPIAddress = localAPIAddress
                    editingAPIKey = ""  // Local 模式不需要 Key
                } else {
                    // 保存 Local 地址
                    localAPIAddress = editingAPIAddress
                    // 恢复 Cloud 地址和 Key
                    editingAPIAddress = cloudAPIAddress
                    editingAPIKey = presetManager.getAPIKey(for: cloudAPIAddress)
                }
            }
            
            // API 地址
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedStrings.apiAddress)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    TextField(selectedAPIType == .local ? "http://127.0.0.1:1234/v1/chat/completions" : "https://api.deepseek.com/v1/chat/completions", text: $editingAPIAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onChange(of: editingAPIAddress) { newURL in
                            // ⭐ 切换 URL 时，保存旧 URL 的 Model Name，加载新 URL 的 Key 和 Model
                            if selectedAPIType == .cloud {
                                // 保存旧 URL 的 Model Name
                                if !cloudAPIAddress.isEmpty {
                                    presetManager.setModelName(editingModelName, for: cloudAPIAddress)
                                }
                                // 加载新 URL 的配置
                                editingAPIKey = presetManager.getAPIKey(for: newURL)
                                // 先找预设的默认模型，如果没有则用用户保存的
                                if let preset = presetManager.allPresets.first(where: { $0.baseURL == newURL }) {
                                    editingModelName = presetManager.getModelName(for: newURL, defaultValue: preset.defaultModel)
                                } else {
                                    editingModelName = presetManager.getModelName(for: newURL)
                                }
                            }
                        }
                    
                    // 云端模式才显示预设选择菜单
                    if selectedAPIType == .cloud {
                        Menu {
                            // 所有预设
                            ForEach(presetManager.allPresets) { preset in
                                Button(action: {
                                    // ⭐ 保存当前 URL 的 Key 和 Model Name
                                    presetManager.setAPIKey(editingAPIKey, for: editingAPIAddress)
                                    presetManager.setModelName(editingModelName, for: editingAPIAddress)
                                    
                                    // 加载新预设
                                    editingAPIAddress = preset.baseURL
                                    cloudAPIAddress = preset.baseURL
                                    // ⭐ 加载用户保存的 Model 或预设默认值
                                    editingModelName = presetManager.getModelName(for: preset.baseURL, defaultValue: preset.defaultModel)
                                    // 加载新预设对应的 Key
                                    editingAPIKey = presetManager.getAPIKey(for: preset.baseURL)
                                }) {
                                    HStack {
                                        Text(preset.name)
                                        if !preset.isBuiltIn {
                                            Text("(custom)")
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            
                            Divider()
                            
                            // 添加新预设
                            Button(action: {
                                newPresetURL = editingAPIAddress
                                newPresetModel = editingModelName
                                newPresetName = ""
                                showAddPreset = true
                            }) {
                                Label(localizedStrings.addCustom, systemImage: "plus")
                            }
                            
                            // 管理预设
                            if presetManager.allPresets.contains(where: { !$0.isBuiltIn }) {
                                Menu(localizedStrings.deleteCustom) {
                                    ForEach(presetManager.allPresets.filter { !$0.isBuiltIn }) { preset in
                                        Button(role: .destructive) {
                                            presetManager.deletePreset(preset)
                                        } label: {
                                            Text(preset.name)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                    }
                }
            }
            
            // 云端模式额外配置
            if selectedAPIType == .cloud {
                // API Key
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedStrings.apiKey)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 0) {
                        if isAPIKeyVisible {
                            TextField("sk-xxxxxxxx", text: $editingAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        } else {
                            SecureField("sk-xxxxxxxx", text: $editingAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        }
                        
                        // 眼睛图标切换按钮
                        Button(action: {
                            isAPIKeyVisible.toggle()
                        }) {
                            Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(isAPIKeyVisible ? "Hide API Key" : "Show API Key")
                        .padding(.leading, 4)
                    }
                }
                
                // Model Name
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedStrings.modelName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextField("deepseek-v4-flash", text: $editingModelName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            
            // 连接按钮 + 刷新时间
            HStack {
                Button(action: {
                    // 保存当前模式的地址
                    if selectedAPIType == .local {
                        localAPIAddress = editingAPIAddress
                    } else {
                        cloudAPIAddress = editingAPIAddress
                        // ⭐ 保存当前 URL 的 API Key 和 Model Name
                        presetManager.setAPIKey(editingAPIKey, for: editingAPIAddress)
                        presetManager.setModelName(editingModelName, for: editingAPIAddress)
                    }
                    
                    Task {
                        await modelManager.updateConfig(
                            baseURL: editingAPIAddress,
                            apiKey: editingAPIKey,
                            modelName: editingModelName,
                            apiType: selectedAPIType
                        )
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text(localizedStrings.connect)
                    }
                }
                .buttonStyle(.bordered)
                
                // 刷新时间
                if let lastRefresh = modelManager.lastRefreshTime {
                    Text(timeAgoString(from: lastRefresh))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // 状态消息
                Text(modelManager.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Divider()
            
            // 底部：语言切换 + Quit
            HStack {
                // ⭐ 语言切换按钮
                Button(action: {
                    let newLanguage: AppLanguage = localizedStrings.currentLanguage == .english ? .simplifiedChinese : .english
                    localizedStrings.setLanguage(newLanguage)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                        Text(localizedStrings.systemLanguage)
                            .font(.caption)
                        Text(localizedStrings.currentLanguage.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(localizedStrings.currentLanguage == .english ? "Switch to 简体中文" : "切换到 English")
                
                Spacer()
                
                Button(action: onQuit) {
                    HStack(spacing: 4) {
                        Text(localizedStrings.quit)
                        Text("⌘Q")
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 360)  // 稍微加宽以容纳语言选择器
        .onAppear {
            loadCurrentConfig()
        }
        .onReceive(timer) { time in
            currentTime = time
        }
        .sheet(isPresented: $showAddPreset) {
            AddPresetView(
                isPresented: $showAddPreset,
                presetName: $newPresetName,
                presetURL: $newPresetURL,
                presetModel: $newPresetModel,
                onSave: {
                    presetManager.addPreset(
                        name: newPresetName,
                        baseURL: newPresetURL,
                        defaultModel: newPresetModel
                    )
                }
            )
        }
        .sheet(isPresented: $showHotkeySettings) {
            HotkeySettingsView(
                isPresented: $showHotkeySettings,
                currentConfig: $currentHotkey,
                onSave: { newConfig in
                    hotkeyManager?.updateHotkey(config: newConfig)
                    currentHotkey = newConfig
                }
            )
        }
    }
    
    private func loadCurrentConfig() {
        editingAPIAddress = modelManager.currentAPIAddress
        editingAPIKey = modelManager.currentAPIKey
        editingModelName = modelManager.currentModelName
        selectedAPIType = modelManager.currentAPIType
        
        // ⭐ 加载保存的目标语言
        selectedLanguage = TargetLanguage.load()
        
        // ⭐ 加载保存的快捷键配置
        currentHotkey = hotkeyManager?.currentConfig ?? HotkeyConfig.load()
        
        // 初始化两个模式的地址
        if modelManager.currentAPIType == .local {
            localAPIAddress = modelManager.currentAPIAddress
            editingAPIKey = ""
        } else {
            cloudAPIAddress = modelManager.currentAPIAddress
            editingAPIKey = presetManager.getAPIKey(for: modelManager.currentAPIAddress)
        }
    }
    
    private func timeAgoString(from date: Date) -> String {
        let seconds = Int(currentTime.timeIntervalSince(date))
        
        if seconds < 5 {
            return localizedStrings.justNow
        } else if seconds < 60 {
            return "\(seconds)s \(localizedStrings.ago)"
        } else {
            let minutes = seconds / 60
            return "\(minutes)m \(localizedStrings.ago)"
        }
    }
}

// MARK: - 添加预设弹窗

struct AddPresetView: View {
    @Binding var isPresented: Bool
    @Binding var presetName: String
    @Binding var presetURL: String
    @Binding var presetModel: String
    var onSave: () -> Void
    @ObservedObject var localizedStrings = LocalizedStrings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localizedStrings.addCustomPreset)
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedStrings.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("My Custom API", text: $presetName)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedStrings.apiURL)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("https://api.example.com", text: $presetURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedStrings.defaultModel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("model-name", text: $presetModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            
            HStack {
                Button(localizedStrings.cancel) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(localizedStrings.save) {
                    onSave()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(presetName.isEmpty || presetURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - 快捷键设置弹窗

struct HotkeySettingsView: View {
    @Binding var isPresented: Bool
    @Binding var currentConfig: HotkeyConfig
    var onSave: (HotkeyConfig) -> Void
    
    @State private var recordedConfig: HotkeyConfig
    @State private var isRecording: Bool = false
    @State private var errorMessage: String = ""
    @ObservedObject var localizedStrings = LocalizedStrings.shared
    
    init(isPresented: Binding<Bool>, currentConfig: Binding<HotkeyConfig>, onSave: @escaping (HotkeyConfig) -> Void) {
        self._isPresented = isPresented
        self._currentConfig = currentConfig
        self.onSave = onSave
        // 初始化时使用当前配置
        self._recordedConfig = State(initialValue: currentConfig.wrappedValue)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localizedStrings.hotkeySettings)
                .font(.headline)
            
            Text(localizedStrings.clickAreaThenPress)
                .font(.caption)
                .foregroundColor(.secondary)
            
            // 快捷键录制区域
            Button(action: {
                isRecording = true
                errorMessage = ""
            }) {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 32))
                            .foregroundColor(isRecording ? .blue : .gray)
                        
                        Text(isRecording ? localizedStrings.pressKeys : recordedConfig.displayName)
                            .font(.title2)
                            .foregroundColor(isRecording ? .blue : .primary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isRecording ? Color.blue : Color.gray.opacity(0.3), lineWidth: 2)
                    )
            )
            .onAppear {
                // 监听键盘事件
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if isRecording {
                        handleKeyPress(event: event)
                        return nil // 阻止事件传递
                    }
                    return event
                }
            }
            
            // 错误信息
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            // 提示信息
            Text(localizedStrings.hotkeyTip)
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Divider()
            
            HStack {
                Button(localizedStrings.resetToDefault) {
                    recordedConfig = HotkeyConfig.default
                    errorMessage = ""
                }
                
                Spacer()
                
                Button(localizedStrings.cancel) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button(localizedStrings.save) {
                    onSave(recordedConfig)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recordedConfig == currentConfig)
            }
        }
        .padding(20)
        .frame(width: 350)
    }
    
    private func handleKeyPress(event: NSEvent) {
        let keyCode = event.keyCode
        let modifierFlags = event.modifierFlags
        
        // 构建修饰键
        var modifiers: UInt32 = 0
        if modifierFlags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if modifierFlags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if modifierFlags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if modifierFlags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        
        // 验证：必须有修饰键
        if modifiers == 0 {
            errorMessage = localizedStrings.hotkeyMustIncludeModifier
            isRecording = false
            return
        }
        
        // 创建新配置
        let newConfig = HotkeyConfig(keyCode: UInt32(keyCode), modifiers: modifiers)
        recordedConfig = newConfig
        isRecording = false
        errorMessage = ""
        
        print("✅ 录制快捷键: \(newConfig.displayName)")
    }
}
#if DEBUG || canImport(SwiftUI)
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(modelManager: ModelManager())
    }
}
#endif
