import Foundation
import AppKit
import SwiftUI
import Testing
@testable import BMSCore
@testable import OrionDiagnostics

@MainActor private final class PortFixture {
    var ports: [SerialPortInfo] = [.init(path:"/dev/cu.debug-console",name:"debug-console")]
}
@Test @MainActor func applicationWatcherDetectsUSBAddedAfterWindowStartup() async throws {
    let fixture = PortFixture()
    let model = AppModel(portProvider: { fixture.ports })
    #expect(model.selectedPort.isEmpty)
    let watcher = Task { await model.watchConnections() }
    defer { watcher.cancel() }
    let usb = SerialPortInfo(path:"/dev/cu.usbserial-HOTPLUG",name:"usbserial-HOTPLUG")
    fixture.ports.append(usb)
    try await Task.sleep(for:.milliseconds(1200))
    #expect(model.ports.contains(usb))
    #expect(model.selectedPort == usb.path)
    #expect(model.device == nil) // Discovery must not open the adapter.
    await model.prepareToQuit()
}
@Test @MainActor func reconnectStartsFreshMonitoringWithoutCancelledTaskClearingConnection() async throws {
    let model = AppModel(portProvider:{ [] })
    model.connect(demo:true)
    for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(for:.milliseconds(20)) }
    #expect(model.device?.isDemo == true)
    #expect(model.isMonitoring)
    model.reconnect()
    for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(for:.milliseconds(20)) }
    try await Task.sleep(for:.milliseconds(120))
    #expect(model.device?.isDemo == true)
    #expect(model.isMonitoring)
    #expect(model.latest != nil)
    await model.prepareToQuit()
}

@Test @MainActor func workspaceSelectionSurvivesLivePollingAndPortRefresh() async throws {
    let model = AppModel(portProvider: { [] })
    model.connect(demo: true)
    for _ in 0..<100 {
        if !model.busy, model.latest != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let initialSample = model.latest?.id
    model.page = .cells
    model.refreshPorts()
    try await Task.sleep(for: .milliseconds(2200))
    #expect(model.latest != nil)
    #expect(model.latest?.id != initialSample)
    #expect(model.page == .cells)
    await model.prepareToQuit()
}

@Test @MainActor func emptyDiagnosticsFitsWindowBeforeAndAfterConnection() {
    _ = NSApplication.shared
    for connected in [false, true] {
        let model = AppModel(portProvider: { [] })
        model.page = .diagnostics
        if connected {
            model.device = DeviceInfo(signature: "ORIONBMS04", port: "Layout fixture", isDemo: true)
        }
        let controller = NSHostingController(rootView: ContentView(model: model))
        for height in [670.0, 780.0] {
            let proposed = CGSize(width: 1180, height: height)
            let fitted = controller.sizeThatFits(in: proposed)
            #expect(fitted.height <= height + 1, "Empty Diagnostics exceeds window height (connected: \(connected)): \(fitted)")
            #expect(fitted.width <= proposed.width + 1)
        }
    }
}

@Test @MainActor func profileAuthenticationPromptAndRetryPreserveReadonlyWorkflow() async throws {
    let model = AppModel(portProvider:{ [] })
    model.connect(demo:true,demoProfilePassword:"demo")
    for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(for:.milliseconds(20)) }
    model.downloadProfile()
    for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(for:.milliseconds(20)) }
    #expect(model.profileNeedsPassword)
    #expect(model.profileSnapshot == nil)
    model.downloadProfile(password:"wrong")
    for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(for:.milliseconds(20)) }
    #expect(model.profileNeedsPassword)
    #expect(model.profileSnapshot == nil)
    model.downloadProfile(password:"demo")
    for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(for:.milliseconds(20)) }
    #expect(!model.profileNeedsPassword)
    #expect(model.profileSnapshot?.data.count == 3474)
    #expect(model.profileSnapshot?.authenticated == true)
    #expect(model.device?.isDemo == true)
    await model.prepareToQuit()
}

@Test @MainActor func quittingFinishesCleanupOnceDespiteRepeatedRequests() async throws {
    let coordinator = TerminationCoordinator()
    var cleanups = 0
    var replies = 0
    for _ in 0..<3 {
        coordinator.request(timeout: .milliseconds(150), shutdown: {
            cleanups += 1
            try? await Task.sleep(for: .milliseconds(20))
        }, onReady: { replies += 1 })
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(coordinator.isReady)
    #expect(cleanups == 1)
    #expect(replies == 1)
}

@Test @MainActor func quittingHasDeadlineEvenWhenCleanupIgnoresCancellation() async throws {
    let coordinator = TerminationCoordinator()
    var release: CheckedContinuation<Void, Never>?
    var replies = 0
    coordinator.request(timeout: .milliseconds(40), shutdown: {
        await withCheckedContinuation { release = $0 }
    }, onReady: { replies += 1 })
    try await Task.sleep(for: .milliseconds(100))
    #expect(coordinator.isReady)
    #expect(replies == 1)
    release?.resume()
    try await Task.sleep(for: .milliseconds(20))
    #expect(replies == 1) // Late cleanup must not trigger termination twice.
}

@Test @MainActor func quittingCancelsConnectionAndPreventsReopening() async throws {
    let model = AppModel(portProvider: { [] })
    model.connect(demo: true)
    await model.prepareToQuit()
    #expect(model.device == nil)
    #expect(!model.isMonitoring)
    #expect(!model.busy)
    model.connect(demo: true)
    model.reconnect()
    model.download()
    model.downloadProfile()
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.device == nil)
    #expect(!model.isMonitoring)
    #expect(!model.busy)
}
