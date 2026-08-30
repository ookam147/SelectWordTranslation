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
        let model = TranslationPopupViewModel(
            originalText: "",
            state: .idle,
            modelName: "",
            selectedLanguage: .defaultLanguage
        )
        var warmedResidentSize: UInt64?

        for index in 0..<iterations {
            autoreleasepool {
                model.originalText = String(repeating: "source ", count: wordCount)
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
                guard controller.presentationSnapshot.isProgressIndicatorVisible else {
                    fatalError("Loading indicator was not visible")
                }

                model.state = .result(String(repeating: "translation ", count: wordCount))
                manager.refreshLayout()
                let resultSnapshot = controller.presentationSnapshot
                guard !resultSnapshot.isStatusRowVisible, !resultSnapshot.isProgressIndicatorVisible else {
                    fatalError("Loading UI remained visible after translation at iteration \(index)")
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
