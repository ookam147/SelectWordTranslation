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
                model.state = .result(String(repeating: "translation ", count: wordCount))
                model.modelName = "stress-model"
                manager.show(viewModel: model, at: NSPoint(x: 300, y: 300))
                guard monitor.activeMonitorCount == 2 else { fatalError("Event monitors were not installed") }
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
