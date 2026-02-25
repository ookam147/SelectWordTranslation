import SwiftUI

struct TranslationPopupView: View {
    let originalText: String
    let translatedText: String
    let isLoading: Bool
    let modelName: String  // 新增：模型名称
    let onClose: () -> Void
    let onPinToggle: () -> Void  // 新增：置顶切换回调
    let isPinned: Bool  // 新增：置顶状态
    let selectedLanguage: TargetLanguage  // ⭐ 新增：当前选择的语言
    let onLanguageChange: (TargetLanguage) -> Void  // ⭐ 新增：语言变更回调
    
    @ObservedObject var localizedStrings = LocalizedStrings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // 模型图标 + Models: + 模型名称
                Image(systemName: "cpu")
                    .foregroundColor(.white)
                Text(localizedStrings.models)
                    .font(.headline)
                    .foregroundColor(.gray)
                Text(modelName.isEmpty ? "Unknown" : modelName)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                // 图钉按钮
                Button(action: onPinToggle) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 14))
                        .foregroundColor(isPinned ? .blue : .gray)
                }
                .buttonStyle(.plain)
                .help(isPinned ? localizedStrings.unpinWindow : localizedStrings.pinWindow)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedStrings.original)
                    .font(.caption)
                    .foregroundColor(.gray)
                Text(originalText)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Divider()
                .background(Color.gray)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(localizedStrings.result)
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                    
                    // ⭐ 语言选择菜单
                    Menu {
                        ForEach(TargetLanguage.languages) { language in
                            Button(action: {
                                onLanguageChange(language)
                            }) {
                                HStack {
                                    Text(language.displayName)
                                    if language.id == selectedLanguage.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "globe")
                                .font(.system(size: 11))
                            Text(selectedLanguage.nativeName)
                                .font(.system(size: 11))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.gray)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    
                    // 复制按钮放在Result行
                    Button(action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(translatedText, forType: .string)
                        print("Copied to clipboard")
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
                if isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text(localizedStrings.translating)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                } else {
                    Text(translatedText)
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .frame(minWidth: 300, maxWidth: 400)
        // 不设置maxHeight，让内容自然展开，窗口管理器会限制不超出屏幕
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#if DEBUG || canImport(SwiftUI)
struct TranslationPopupView_Previews: PreviewProvider {
    static var previews: some View {
        TranslationPopupView(modelManager: ModelManager(), textSelectionManager: TextSelectionManager.shared)
    }
}
#endif
