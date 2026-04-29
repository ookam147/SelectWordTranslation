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
    
    // ⭐ 智能布局判断：当文本过长时切换为横向布局
    private var useHorizontalLayout: Bool {
        let totalLength = originalText.count + translatedText.count
        let maxSingleLength = max(originalText.count, translatedText.count)
        // 当总字符数超过100，或任一文本超过80字符时，切换为横向布局
        return totalLength > 100 || maxSingleLength > 80
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ========== 顶部工具栏（始终横向） ==========
            headerBar
            
            // ========== 内容区域：根据文本长度智能切换布局 ==========
            if useHorizontalLayout {
                horizontalContentLayout
            } else {
                verticalContentLayout
            }
        }
        .padding()
        .frame(minWidth: useHorizontalLayout ? 500 : 300,
               maxWidth: useHorizontalLayout ? 700 : 400)
        // 不设置maxHeight，让内容自然展开，窗口管理器会限制不超出屏幕
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - 顶部工具栏
    private var headerBar: some View {
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
    }
    
    // MARK: - 翻译结果标题栏（语言选择 + 复制按钮）
    private var translationResultHeader: some View {
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
    }
    
    // MARK: - 翻译结果文本内容（加载中 / 已完成）
    private var translationResultContent: some View {
        Group {
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
    
    // MARK: - 纵向布局（上原下译，短文本默认）
    private var verticalContentLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 原文区域
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
            
            // 译文区域
            VStack(alignment: .leading, spacing: 4) {
                translationResultHeader
                translationResultContent
            }
        }
    }
    
    // MARK: - 横向布局（左原右译，长文本自动切换）
    private var horizontalContentLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 横向布局时，把标题栏放在上方
            translationResultHeader
            
            // 左右分屏内容
            HStack(alignment: .top, spacing: 12) {
                // 左侧：原文
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedStrings.original)
                        .font(.caption)
                        .foregroundColor(.gray)
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(originalText)
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 4)
                    }
                    .frame(minHeight: 180, maxHeight: 1000)
                }
                .frame(maxWidth: .infinity)
                
                // 中间分隔线
                Divider()
                    .background(Color.gray)
                
                // 右侧：译文
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedStrings.result)
                        .font(.caption)
                        .foregroundColor(.gray)
                    ScrollView(.vertical, showsIndicators: true) {
                        translationResultContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 4)
                    }
                    .frame(minHeight: 180, maxHeight: 1000)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 200)
        }
    }
}

#if DEBUG || canImport(SwiftUI)
struct TranslationPopupView_Previews: PreviewProvider {
    static var previews: some View {
        // 短文本预览（纵向布局）
        TranslationPopupView(
            originalText: "Hello, world!",
            translatedText: "你好，世界！",
            isLoading: false,
            modelName: "GPT-4",
            onClose: {},
            onPinToggle: {},
            isPinned: false,
            selectedLanguage: TargetLanguage.load(),
            onLanguageChange: { _ in }
        )
        .previewDisplayName("短文本 - 纵向布局")
        
        // 长文本预览（横向布局）
        TranslationPopupView(
            originalText: "This is a much longer text that should trigger the horizontal layout mode. When the total character count exceeds the threshold, the view automatically switches to a side-by-side layout for better readability.",
            translatedText: "这是一段更长的文本，应该触发横向布局模式。当总字符数超过阈值时，视图会自动切换为左右并排的布局，以提供更好的可读性。",
            isLoading: false,
            modelName: "GPT-4",
            onClose: {},
            onPinToggle: {},
            isPinned: false,
            selectedLanguage: TargetLanguage.load(),
            onLanguageChange: { _ in }
        )
        .previewDisplayName("长文本 - 横向布局")
    }
}
#endif
