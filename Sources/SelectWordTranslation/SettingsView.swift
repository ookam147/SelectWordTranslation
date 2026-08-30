import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var modelManager: ModelManager
    @ObservedObject private var presetManager: PresetManager
    let hotkeyManager: HotkeyManager
    let translationService: TranslationServicing

    @State private var draft: TranslationConfiguration
    @State private var hotkey: HotkeyConfig
    @State private var message = ""
    @State private var showAddProvider = false

    init(modelManager: ModelManager, hotkeyManager: HotkeyManager, translationService: TranslationServicing) {
        self.modelManager = modelManager
        presetManager = modelManager.presetManager
        self.hotkeyManager = hotkeyManager
        self.translationService = translationService
        _draft = State(initialValue: modelManager.configuration)
        _hotkey = State(initialValue: hotkeyManager.currentConfig)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            serviceTab
                .tabItem { Label("Translation Service", systemImage: "network") }
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .sheet(isPresented: $showAddProvider) {
            AddProviderView { name, url, model in
                let preset = presetManager.addPreset(name: name, baseURL: url, defaultModel: model)
                draft = modelManager.configuration(for: preset)
            }
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker("Target Language", selection: Binding(
                    get: { modelManager.targetLanguage },
                    set: { modelManager.setTargetLanguage($0) }
                )) {
                    ForEach(TargetLanguage.languages) { Text($0.displayName).tag($0) }
                }
            }

            Section("Global Shortcut") {
                ShortcutRecorderView(config: $hotkey)
                    .frame(height: 38)
                HStack {
                    Button("Reset") { hotkey = .default }
                    Spacer()
                    Button("Save") { saveHotkey() }
                        .keyboardShortcut(.defaultAction)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var serviceTab: some View {
        Form {
            Section("Connection") {
                Picker("Mode", selection: Binding(
                    get: { draft.apiType },
                    set: { switchMode(to: $0) }
                )) {
                    Text("Local").tag(APIType.local)
                    Text("Cloud").tag(APIType.cloud)
                }
                .pickerStyle(.segmented)

                if draft.apiType == .cloud {
                    Picker("Provider", selection: Binding(
                        get: { draft.providerID },
                        set: { selectProvider(id: $0) }
                    )) {
                        ForEach(presetManager.allPresets) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        Button("Add Provider", systemImage: "plus") { showAddProvider = true }
                        if let selected = presetManager.preset(id: draft.providerID), !selected.isBuiltIn {
                            Button("Delete Provider", systemImage: "minus", role: .destructive) {
                                do {
                                    try modelManager.deletePreset(id: selected.id)
                                    if let first = presetManager.allPresets.first { draft = modelManager.configuration(for: first) }
                                } catch {
                                    message = error.localizedDescription
                                }
                            }
                        }
                    }
                }

                TextField("API URL", text: $draft.baseURL)
                if draft.apiType == .cloud { SecureField("API Key", text: $draft.apiKey) }
                TextField("Model", text: $draft.modelName)
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        Task { await modelManager.testConnection(using: translationService, draft: draft) }
                    }
                    .disabled(modelManager.connectionState == .testing)
                    Spacer()
                    Label(
                        modelManager.connectionState.displayText,
                        systemImage: modelManager.connectionState.isReady ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(modelManager.connectionState.isReady ? .green : .secondary)
                    Button("Save") { saveConfiguration() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }

    private func switchMode(to type: APIType) {
        if type == .local {
            draft = .defaultLocal
        } else if let preset = presetManager.allPresets.first {
            draft = modelManager.configuration(for: preset)
        }
    }

    private func selectProvider(id: String) {
        guard let preset = presetManager.preset(id: id) else { return }
        draft = modelManager.configuration(for: preset)
    }

    private func saveConfiguration() {
        do {
            try modelManager.apply(configuration: draft)
            message = L10n.text("Saved")
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveHotkey() {
        do {
            try hotkeyManager.updateHotkey(config: hotkey)
            message = L10n.text("Saved")
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct AddProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var model = ""
    let onSave: (String, String, String) -> Void

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("API URL", text: $url)
            TextField("Model", text: $model)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") { onSave(name, url, model); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || url.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var config: HotkeyConfig

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        ShortcutRecorderNSView(config: config) { self.config = $0 }
    }

    func updateNSView(_ view: ShortcutRecorderNSView, context: Context) {
        view.config = config
    }
}

@MainActor
private final class ShortcutRecorderNSView: NSView {
    var config: HotkeyConfig { didSet { label.stringValue = config.displayName } }
    private let onChange: (HotkeyConfig) -> Void
    private let label = NSTextField(labelWithString: "")

    init(config: HotkeyConfig, onChange: @escaping (HotkeyConfig) -> Void) {
        self.config = config
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.stringValue = config.displayName
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func layout() { super.layout(); label.frame = bounds.insetBy(dx: 8, dy: 8) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { NSSound.beep(); return }
        let updated = HotkeyConfig(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        config = updated
        onChange(updated)
    }
}
