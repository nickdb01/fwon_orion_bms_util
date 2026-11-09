import SwiftUI
import BMSCore

@main enum Launcher {
    @MainActor static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--export-demo"), index + 1 < CommandLine.arguments.count {
            do {
                let service = DiagnosticService()
                _ = try await service.connect(path: "", demo: true)
                let report = try await service.download { _ in }
                let parent = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                let output = try ReportFiles.exportBundle(report, into: parent)
                print(output.path)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        OrionDiagnosticsApp.main()
    }
}
@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private let termination = TerminationCoordinator()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !termination.isReady, let model else { return .terminateNow }
        termination.request(shutdown: { await model.prepareToQuit() }, onReady: { sender.terminate(nil) })
        // Keep the normal event loop running while asynchronous cleanup finishes.
        // A second terminate call, once ready, returns terminateNow above.
        return .terminateCancel
    }
}
struct OrionDiagnosticsApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { delegate.model = model }
                .task { await model.watchConnections() }
                .task {
                    if CommandLine.arguments.contains("--demo") {
                        model.connect(demo: true)
                        while model.busy { do { try await Task.sleep(for: .milliseconds(50)) } catch { return } }
                        if model.device != nil { model.download() }
                    }
                }
        }.defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Report…") { model.openReport() }.keyboardShortcut("o").disabled(model.busy || model.device != nil)
                Button("Save JSON…") { model.saveJSON() }.keyboardShortcut("s").disabled(model.report == nil || model.busy)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(WorkspacePage.allCases.enumerated()), id: \.element.id) { index, page in
                    Button(page.rawValue) { model.page = page }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
            CommandMenu("Diagnostics") {
                Button("Download Diagnostics") { model.download() }.keyboardShortcut("d").disabled(model.device == nil || model.busy)
                Button("Cancel Download") { model.cancel() }.keyboardShortcut(".").disabled(!model.busy)
                Divider()
                Button("Refresh Connections") { model.refreshPorts() }.disabled(model.busy)
                Button("Explore Password-Protected Demo") { model.connect(demo:true,demoProfilePassword:"demo") }.disabled(model.busy || model.device != nil)
                Button("Explore Offline Demo") { model.connect(demo: true) }.disabled(model.busy || model.device != nil)
            }
        }
    }
}
