import AppKit
import Darwin.Mach
import Foundation

@MainActor
private final class StressEventMonitor: EventMonitoring {
    private(set) var activeMonitorCount = 0
    func start(for panel: NSPanel, dismiss: @escaping () -> Void) { activeMonitorCount = 2 }
    func stop() { activeMonitorCount = 0 }
}

@main
private struct PopupStressRunner {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        verifyStateTransitions()
        let monitor = StressEventMonitor()
        let manager = PopupWindowManager(eventMonitor: monitor)
        let environment = ProcessInfo.processInfo.environment
        let iterations = Int(environment["SWT_STRESS_ITERATIONS"] ?? "500") ?? 500
        let wordCount = Int(environment["SWT_STRESS_WORDS"] ?? "500") ?? 500
        let warmupIteration = max(1, iterations / 5)
        let selectionPasteboard = NSPasteboard(name: .init("SelectionStress-\(UUID().uuidString)"))
        let model = TranslationPopupViewModel(
            originalText: "",
            state: .idle,
            modelName: "",
            selectedLanguage: .defaultLanguage
        )
        verifyDynamicLayoutTransitions(manager: manager, model: model)
        var warmedResidentSize: UInt64?

        for index in 0..<iterations {
            autoreleasepool {
                verifySelectionCycle(pasteboard: selectionPasteboard, iteration: index)
                let usesLongLayout = index.isMultiple(of: 2)
                model.originalText = usesLongLayout
                    ? longText(prefix: "source", lineCount: 12, wordsPerLine: max(8, wordCount / 12))
                    : "Short source \(index)"
                model.state = .loading
                model.modelName = "stress-model"
                manager.show(viewModel: model, at: NSPoint(x: 300, y: 300))
                guard monitor.activeMonitorCount == 2 else { fatalError("Event monitors were not installed") }
                guard let panel = NSApp.windows.first(where: { $0.isVisible }) as? NSPanel else {
                    fatalError("Popup panel was not visible")
                }
                verifyPanelConfiguration(panel)
                guard let controller = panel.contentViewController as? TranslationPanelContentController else {
                    fatalError("Popup content controller was unavailable")
                }
                var layoutSnapshot = controller.presentationSnapshot
                guard layoutSnapshot.isProgressIndicatorVisible else {
                    fatalError("Loading indicator was not visible")
                }
                verifyLayout(
                    layoutSnapshot,
                    expectedMode: usesLongLayout ? .sideBySide : .compactStacked,
                    context: "new translation at iteration \(index)"
                )

                if index == 0 {
                    controller.setSplitRatio(0)
                    layoutSnapshot = controller.presentationSnapshot
                    guard layoutSnapshot.originalPaneWidth >= 239.5,
                          layoutSnapshot.resultPaneWidth >= 239.5 else {
                        fatalError("Side-by-side panes could collapse below their minimum width")
                    }
                }

                controller.setSplitRatio(0.4)
                let draggedRatio = controller.presentationSnapshot.splitRatio
                guard !usesLongLayout || abs(draggedRatio - 0.4) <= 0.02 else {
                    fatalError("Dragged split ratio was not applied")
                }

                model.state = .result(
                    usesLongLayout
                        ? longText(prefix: "translation", lineCount: 12, wordsPerLine: max(8, wordCount / 12))
                        : "Short translation \(index)"
                )
                manager.refreshLayout()
                let resultSnapshot = controller.presentationSnapshot
                guard !resultSnapshot.isStatusRowVisible, !resultSnapshot.isProgressIndicatorVisible else {
                    fatalError("Loading UI remained visible after translation at iteration \(index)")
                }
                guard abs(resultSnapshot.splitRatio - draggedRatio) <= 0.02 else {
                    fatalError(
                        "Split ratio changed after translation at iteration \(index): "
                            + "\(draggedRatio) -> \(resultSnapshot.splitRatio)"
                    )
                }
                verifyLayout(
                    resultSnapshot,
                    expectedMode: usesLongLayout ? .sideBySide : .compactStacked,
                    context: "completed translation at iteration \(index)"
                )

                manager.show(viewModel: model, at: NSPoint(x: 300, y: 300), preservePosition: true)
                guard abs(controller.presentationSnapshot.splitRatio - draggedRatio) <= 0.02 else {
                    fatalError("Split ratio changed while preserving the popup at iteration \(index)")
                }
                manager.hide(notify: false)
                guard monitor.activeMonitorCount == 0 else { fatalError("Event monitors were not removed") }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
            guard model.originalText.isEmpty, model.translatedText.isEmpty else {
                fatalError("Popup retained text at iteration \(index)")
            }
            if index == warmupIteration - 1 { warmedResidentSize = residentSize() }
        }

        let finalResidentSize = residentSize()
        if let warmedResidentSize {
            let growth = finalResidentSize > warmedResidentSize ? finalResidentSize - warmedResidentSize : 0
            guard growth <= 10 * 1_024 * 1_024 else {
                fatalError("Resident memory grew by \(growth) bytes after warm-up")
            }
            print("Resident memory growth after warm-up: \(growth) bytes.")
        }
        manager.dispose()
        print("Popup stress test passed (\(iterations) open/close cycles).")
    }

    @MainActor
    private static func verifySelectionCycle(pasteboard: NSPasteboard, iteration: Int) {
        let customType = NSPasteboard.PasteboardType("com.zwalking.stress.custom")
        let originalItem = NSPasteboardItem()
        originalItem.setString("original", forType: .string)
        originalItem.setData(Data([0, 1, 2, 3]), forType: customType)
        pasteboard.clearContents()
        pasteboard.writeObjects([originalItem])
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        let copiedChangeCount = pasteboard.changeCount
        let expected: String
        let bundleIdentifier: String
        if iteration.isMultiple(of: 2) {
            expected = "微信选中文字"
            bundleIdentifier = "com.tencent.xinWeChat"
            pasteboard.writeObjects([expected as NSString])
        } else {
            expected = "测试文件-\(iteration).pdf"
            bundleIdentifier = "com.apple.finder"
            let item = NSPasteboardItem()
            item.setString(
                URL(fileURLWithPath: "/private/tmp/\(expected)").absoluteString,
                forType: .fileURL
            )
            pasteboard.writeObjects([item])
        }

        guard PasteboardSelectionParser.text(
            from: pasteboard,
            sourceBundleIdentifier: bundleIdentifier
        ) == expected else {
            fatalError("Selection parser failed at iteration \(iteration)")
        }
        guard snapshot.restore(to: pasteboard, ifChangeCountIs: copiedChangeCount),
              pasteboard.string(forType: .string) == "original",
              pasteboard.data(forType: customType) == Data([0, 1, 2, 3]) else {
            fatalError("Pasteboard restoration failed at iteration \(iteration)")
        }
    }

    @MainActor
    private static func verifyStateTransitions() {
        let controller = TranslationPanelContentController()
        let model = TranslationPopupViewModel(
            originalText: "source",
            state: .idle,
            modelName: "test-model",
            selectedLanguage: .defaultLanguage
        )

        controller.update(with: model)
        var snapshot = controller.presentationSnapshot
        guard !snapshot.isStatusRowVisible, !snapshot.isProgressIndicatorVisible, snapshot.resultText.isEmpty else {
            fatalError("Idle presentation was incorrect")
        }

        model.state = .loading
        controller.update(with: model)
        snapshot = controller.presentationSnapshot
        guard snapshot.isStatusRowVisible, snapshot.isProgressIndicatorVisible, !snapshot.statusText.isEmpty else {
            fatalError("Loading presentation was incorrect")
        }

        model.state = .result("translated")
        controller.update(with: model)
        snapshot = controller.presentationSnapshot
        guard !snapshot.isStatusRowVisible,
              !snapshot.isProgressIndicatorVisible,
              snapshot.statusText.isEmpty,
              snapshot.resultText == "translated" else {
            fatalError("Result presentation was incorrect")
        }
        guard snapshot.layoutMode == .compactStacked,
              !snapshot.isVerticalSplit,
              snapshot.targetContentSize.width >= 360,
              snapshot.targetContentSize.height >= 190 else {
            fatalError("Short result did not use the compact layout")
        }

        model.state = .loading
        controller.update(with: model)
        model.state = .error("failed")
        controller.update(with: model)
        snapshot = controller.presentationSnapshot
        guard snapshot.isStatusRowVisible,
              !snapshot.isProgressIndicatorVisible,
              snapshot.statusText == "failed",
              snapshot.resultText.isEmpty else {
            fatalError("Error presentation was incorrect")
        }
    }

    @MainActor
    private static func verifyPanelConfiguration(_ panel: NSPanel) {
        guard !panel.styleMask.contains(.resizable),
              !panel.styleMask.contains(.fullSizeContentView),
              !panel.styleMask.contains(.titled),
              !panel.isOpaque,
              panel.backgroundColor.alphaComponent == 0,
              panel.isMovableByWindowBackground else {
            fatalError("Popup panel configuration was incorrect")
        }
        let cornerRadius = panel.contentViewController?.view.layer?.cornerRadius ?? 0
        guard cornerRadius == 0 else { fatalError("Popup content was not square") }
    }

    @MainActor
    private static func verifyDynamicLayoutTransitions(
        manager: PopupWindowManager,
        model: TranslationPopupViewModel
    ) {
        let policyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let sixLineLayout = TranslationPanelLayoutPolicy.layout(
            originalText: longText(prefix: "six", lineCount: 6, wordsPerLine: 1),
            resultText: "",
            statusRowVisible: true,
            font: policyFont
        )
        guard sixLineLayout.mode == .compactStacked else {
            fatalError("Six rendered lines should remain compact")
        }
        let sevenLineLayout = TranslationPanelLayoutPolicy.layout(
            originalText: longText(prefix: "seven", lineCount: 7, wordsPerLine: 1),
            resultText: "",
            statusRowVisible: true,
            font: policyFont
        )
        guard sevenLineLayout.mode == .sideBySide else {
            fatalError("More than six rendered lines should use side-by-side layout")
        }

        model.originalText = "Short source"
        model.state = .loading
        model.modelName = "resize-model"
        manager.show(viewModel: model, at: NSPoint(x: 300, y: 300))
        guard let panel = NSApp.windows.first(where: { $0.isVisible }) as? NSPanel,
              let controller = panel.contentViewController as? TranslationPanelContentController else {
            fatalError("Resize test popup was unavailable")
        }
        var snapshot = controller.presentationSnapshot
        verifyLayout(snapshot, expectedMode: .compactStacked, context: "short loading text")
        guard panel.frame.width >= 359.5,
              panel.frame.height >= 189.5,
              panel.frame.width <= 520.5,
              panel.frame.height <= 420.5 else {
            fatalError("Compact popup size was outside its bounds")
        }

        model.state = .result(longText(prefix: "short-result", lineCount: 4, wordsPerLine: 2))
        let loadingSize = panel.frame.size
        manager.refreshLayout()
        snapshot = controller.presentationSnapshot
        verifyLayout(snapshot, expectedMode: .compactStacked, context: "short result")
        guard panel.frame.height >= loadingSize.height else {
            fatalError("Compact popup did not grow for its result")
        }

        model.state = .result(longText(prefix: "translation", lineCount: 8, wordsPerLine: 4))
        manager.refreshLayout()
        snapshot = controller.presentationSnapshot
        verifyLayout(snapshot, expectedMode: .sideBySide, context: "result-driven mode switch")
        guard abs(snapshot.splitRatio - 0.5) <= 0.02 else {
            fatalError("Side-by-side layout did not reset to an even split")
        }

        controller.setSplitRatio(0.4)
        let draggedRatio = controller.presentationSnapshot.splitRatio
        model.state = .result(longText(prefix: "updated", lineCount: 10, wordsPerLine: 4))
        manager.refreshLayout()
        snapshot = controller.presentationSnapshot
        guard abs(snapshot.splitRatio - draggedRatio) <= 0.02 else {
            fatalError("Side-by-side ratio changed while its mode stayed the same")
        }

        model.originalText = "New short source"
        model.state = .loading
        manager.show(viewModel: model, at: NSPoint(x: 300, y: 300))
        snapshot = controller.presentationSnapshot
        verifyLayout(snapshot, expectedMode: .compactStacked, context: "new compact translation")
        controller.setSplitRatio(0)
        snapshot = controller.presentationSnapshot
        guard snapshot.originalPaneHeight >= 63.5,
              snapshot.resultPaneHeight >= 63.5 else {
            fatalError("Compact panes could collapse below their minimum height")
        }
        manager.hide(notify: false)
    }

    private static func verifyLayout(
        _ snapshot: TranslationPanelPresentationSnapshot,
        expectedMode: TranslationPanelLayoutMode,
        context: String
    ) {
        guard snapshot.layoutMode == expectedMode,
              snapshot.isVerticalSplit == (expectedMode == .sideBySide) else {
            fatalError("Popup used the wrong layout mode for \(context)")
        }
        switch expectedMode {
        case .compactStacked:
            guard snapshot.originalPaneHeight >= 63.5,
                  snapshot.resultPaneHeight >= 63.5,
                  snapshot.targetContentSize.width >= 360,
                  snapshot.targetContentSize.width <= 520,
                  snapshot.targetContentSize.height >= 190,
                  snapshot.targetContentSize.height <= 420 else {
                fatalError("Compact layout was outside its constraints for \(context)")
            }
        case .sideBySide:
            guard snapshot.originalPaneWidth >= 239.5,
                  snapshot.resultPaneWidth >= 239.5,
                  snapshot.targetContentSize.width == 760,
                  snapshot.targetContentSize.height >= 320,
                  snapshot.targetContentSize.height <= 560 else {
                fatalError("Side-by-side layout was outside its constraints for \(context)")
            }
        }
    }

    private static func longText(prefix: String, lineCount: Int, wordsPerLine: Int) -> String {
        (0..<lineCount).map { line in
            Array(repeating: "\(prefix)-\(line)", count: wordsPerLine).joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func residentSize() -> UInt64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(information.resident_size) : 0
    }
}
