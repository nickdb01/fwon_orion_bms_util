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
