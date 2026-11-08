import SwiftUI
import BMSCore

private let ink = Color.primary

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    private var teal: Color {
        colorScheme == .dark ? Color(red: 0.32, green: 0.82, blue: 0.73) : Color(red: 0.02, green: 0.43, blue: 0.42)
    }
    var body: some View {
        NavigationSplitView {
            GeometryReader { bounds in
                sidebar
                    .frame(width: bounds.size.width, height: bounds.size.height, alignment: .topLeading)
                    .clipped()
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 275, max: 320)
        } detail: {
            GeometryReader { bounds in
            VStack(alignment: .leading, spacing: 0) {
                if model.page == .diagnostics {
                    header.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 18)
                    diagnosticActions
                        .padding(.horizontal, 28).padding(.bottom, 20)
                    if let report = model.report {
                        if report.device.isDemo { demoBanner }
                        reportView(report)
                    } else { welcome }
                } else { MonitoringWorkspace(model: model) }
                footer
            }
            .frame(width: bounds.size.width, height: bounds.size.height, alignment: .topLeading)
            .clipped()
            .background(Color(nsColor: .controlBackgroundColor))
            }
            .navigationTitle("Orion Diagnostics")
            .toolbar {
                ToolbarItemGroup {
                    Button { model.download() } label: { Label("Download Diagnostics", systemImage: "arrow.down.to.line") }
                        .disabled(model.busy || model.device == nil)
                    Button { model.refreshPorts() } label: { Label("Refresh Connections", systemImage: "arrow.clockwise") }
                        .disabled(model.busy).help("Rescan USB serial adapters without restarting")
                    Button { model.openReport() } label: { Label("Open Report", systemImage: "folder") }
                        .disabled(model.busy || model.device != nil).help("Disconnect before opening a saved report")
                    Menu {
                        Button("Export CSV + JSON…") { model.export() }
                        Button("Save JSON…") { model.saveJSON() }
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(model.report == nil || model.busy)
                }
            }
        }
        .onChange(of: model.selectedFaultID) { _, code in
            model.selectedFaultDetail = model.report?.faultDetails?.first { $0.rawCode == code }
        }
        .tint(teal)
        .frame(minWidth: 960, minHeight: 670)
        .alert("Diagnostics", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "battery.100percent").font(.system(size: 27, weight: .medium)).foregroundStyle(teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ORION").font(.system(size: 22, weight: .bold, design: .rounded)).tracking(3)
                    Text("JUNIOR BMS DIAGNOSTICS").font(.system(size: 8, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                }
            }.padding(20)
            List(selection: Binding<WorkspacePage?>(
                get: { model.page },
                set: { if let page = $0 { model.page = page } }
            )) {
                ForEach(WorkspacePage.allCases) { page in
                    Label(page.rawValue, systemImage: page.icon)
                        .padding(.vertical, 5)
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(height: 245)
            .accessibilityLabel("Workspace")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("CONNECTION")
                HStack {
                    Text("Serial adapter").font(.subheadline.weight(.medium))
                    Spacer()
                    Button { model.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(model.busy).help("Refresh connections")
                }
                Picker("Serial adapter", selection: $model.selectedPort) {
                    Text(model.ports.isEmpty ? "No serial ports found" : "Select an adapter…").tag("")
                    ForEach(model.ports) { Text($0.name).tag($0.path) }
                }.labelsHidden().disabled(model.busy || model.device != nil)
                Button { model.refreshPorts() } label: { Label("Refresh Connections", systemImage: "arrow.clockwise") }
                    .disabled(model.busy)
                Text(model.portRefreshDescription).font(.system(size: 10)).foregroundStyle(.secondary)
                if !model.selectedPort.isEmpty {
                    Text(model.selectedPort).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let device = model.device {
                    Label(device.isDemo ? "Offline demo" : "Connected", systemImage: "circle.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(teal)
                    deviceDetails(device)
                    HStack {
                        Button("Disconnect") { model.disconnect() }.disabled(model.busy)
                        Button("Reconnect") { model.reconnect() }.disabled(model.busy)
                    }
                } else {
                    Button { model.connect() } label: {
                        Label(model.connecting ? "Connecting…" : "Connect to BMS", systemImage: "cable.connector")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.selectedPort.isEmpty)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("DOWNLOAD")
                Text("Faults & recent events").font(.subheadline.weight(.semibold))
                Text("Read the diagnostics currently retained by your BMS.").font(.caption).foregroundStyle(.secondary)
                Button { model.download() } label: {
                    Label("Download Diagnostics", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.device == nil)
                if model.busy {
                    if model.connecting { ProgressView().controlSize(.small) }
                    else { ProgressView(value: model.progress) }
                    Button("Cancel") { model.cancel() }.buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 5)
            VStack(alignment: .leading, spacing: 12) {
                Label("Read-only access", systemImage: "lock.shield").font(.caption.weight(.semibold)).foregroundStyle(teal)
                Text("USB → RS-232 → BMS\n9600 baud · 8E1 · RTS enabled")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                if model.device == nil {
                    Button { model.connect(demo: true) } label: { Label("Explore Offline Demo", systemImage: "play.circle") }
                        .buttonStyle(.borderless).disabled(model.busy)
                }
                Text("v0.2.5 · Hardware validation pending").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
                }.padding(20)
            }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("BATTERY MANAGEMENT / SERVICE TOOL")
            Text(model.report == nil ? "Your battery’s diagnostic record." : "Diagnostic record")
                .font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(ink)
            Text(model.sourceLabel.isEmpty ? "Connect, download and keep a local copy of your BMS diagnostics." : model.sourceLabel)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var diagnosticActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button { model.download() } label: {
                    Label("Download Faults & Events", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy || model.device == nil)
                .accessibilityIdentifier("downloadFaultsAndEvents")
                if model.busy {
                    ProgressView(value: model.progress).frame(width: 150)
                    Button("Cancel") { model.cancel() }
                }
            }
            Text(model.busy ? model.status : model.device == nil
                 ? "Connect to your BMS to download retained fault codes and recent events."
                 : "Reads retained fault codes and recent events from your BMS.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    private var demoBanner: some View {
        Label("OFFLINE DEMO · Synthetic records, no BMS connected", systemImage: "testtube.2")
            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.vertical, 10)
            .background(Color.orange.opacity(0.09))
    }
    private var welcome: some View {
        // Keep the empty state inside a scroll viewport: its intrinsic height
        // must never enlarge the split view beyond the window's hit-test bounds.
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(teal)
                Text(model.device == nil ? "Start with a connection." : "Ready to download.")
                    .font(.system(size: 25, weight: .medium, design: .rounded))
                Text(model.device == nil
                     ? "Select your USB serial adapter, then connect to the powered Orion Junior BMS."
                     : "Use Download Faults & Events above to read retained fault codes and recent events.")
                    .foregroundStyle(.secondary).frame(maxWidth: 520, alignment: .leading)
                HStack(alignment: .top, spacing: 30) {
                    welcomeItem("01", "Connect", "USB-to-RS-232 adapter\nwith RTS wiring")
                    welcomeItem("02", "Download", "Fault codes and\nrecent BMS events")
                    welcomeItem("03", "Keep a copy", "CSV for review\nJSON with raw replies")
                }
                if model.device?.isDemo == true {
                    Label("Offline demo — downloaded records will be synthetic", systemImage: "testtube.2")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("The BMS retains a limited rolling history. Event timestamps show operating time; calendar dates are not reconstructed.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 610, alignment: .leading)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .accessibilityIdentifier("diagnosticsEmptyState")
    }
    private func welcomeItem(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(number).font(.caption.monospaced()).foregroundStyle(teal)
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }
    }
    private func reportView(_ report: DiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                metric("FAULT CODES", "\(report.faults.count)", "\(report.sections.prefix(3).filter { $0.state == .complete }.count)/3 fault services read", "exclamationmark.triangle")
                metric("EVENT SLOTS", "\(report.events.count)", report.sections.last?.state.label ?? "Not read", "list.bullet.rectangle")
                metric("DEVICE", report.device.serialNumber ?? "Unknown", report.device.signature, "cpu")
            }
            HStack {
                Picker("View", selection: $model.selectedTab) {
                    Text("Faults").tag(0); Text("Recent Events").tag(1); Text("Download Details").tag(2)
                }.pickerStyle(.segmented).frame(maxWidth: 400)
                Spacer()
                if model.selectedTab != 2 {
                    TextField("Filter records", text: $model.query).textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
            Group {
                if model.selectedTab == 0 {
                    if model.filteredFaults.isEmpty {
                        emptyState(report.faults.isEmpty ? "No fault codes returned" : "No matching faults", report.isComplete ? "Review Recent Events for retained history." : "Check Download Details before drawing conclusions from an empty list.")
                    } else {
                        Table(model.filteredFaults, selection: $model.selectedFaultID) {
                            TableColumn("Code") { Text($0.code).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(ink) }.width(85)
                            TableColumn("Description", value: \.summary)
                            TableColumn("Vendor Status", value: \.statusText).width(min: 130, ideal: 165)
                        }
                    }
                } else if model.selectedTab == 1 {
                    if model.filteredEvents.isEmpty {
                        emptyState("No event records to show", "Review the download status, or clear your filter.")
                    } else {
                        Table(model.filteredEvents) {
                            TableColumn("BMS Runtime", value: \.runtime).width(135)
                            TableColumn("Event", value: \.summary)
                            TableColumn("Slot") { Text(String($0.slot)).monospacedDigit() }.width(35)
                            TableColumn("Type / Parameter", value: \.rawText).width(125)
                        }
                    }
                } else { details(report) }
            }.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
            if model.selectedTab == 0, let code = model.selectedFaultID {
                FaultDetailPanel(model:model,code:code)
            }
            Text("Event times are BMS operating seconds, not calendar time. Select a fault to download subcodes and available frozen readings.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).padding(.top, 0).frame(minHeight: 0, maxHeight: .infinity)
    }
    private func details(_ report: DiagnosticReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
                    HStack(alignment: .top) {
                        Image(systemName: section.state == .complete ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(section.state == .complete ? teal : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.name).fontWeight(.semibold)
                            Text(section.state.label + (section.detail.isEmpty ? "" : " · " + section.detail)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                ForEach(Array((report.device.metadataNotes + report.notes).enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.secondary) }
                Text("Acquired \(report.acquiredAt.formatted()) · \(report.timeZone)").font(.caption)
                Text("Session \(report.sessionID.uuidString)").font(.caption.monospaced()).foregroundStyle(.secondary)
                DisclosureGroup("Raw communication (\(report.trace.count) entries)") {
                    Text(report.trace.map { "[\($0.direction)] \($0.text)" }.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.caption)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func metric(_ title: String, _ value: String, _ caption: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { eyebrow(title); Spacer(); Image(systemName: icon).foregroundStyle(teal) }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
    }
    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        ContentUnavailableView { Label(title, systemImage: "tray") } description: { Text(subtitle) }
    }
    private func deviceDetails(_ device: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(device.signature).font(.caption.monospaced())
            Text("Serial: \(device.serialNumber ?? "Unavailable")")
            Text("Firmware: \(device.firmware.flatMap { FirmwareVersion(code: $0)?.description } ?? device.firmware ?? "Unavailable")")
        }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.device == nil ? Color.secondary : teal).frame(width: 6, height: 6)
            Text(model.status).font(.caption).lineLimit(2)
            Spacer()
            if model.report != nil { Text("LOCAL DATA ONLY").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary) }
        }.padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
    }
    private func eyebrow(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
    }
}
