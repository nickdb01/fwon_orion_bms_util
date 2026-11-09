import SwiftUI
import Charts
import BMSCore

struct MonitoringWorkspace: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.page.rawValue).font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if model.device != nil {
                    Button { model.isMonitoring ? model.stopMonitoring() : model.startMonitoring() } label: {
                        Label(model.isMonitoring ? "Pause Monitoring" : "Start Monitoring", systemImage: model.isMonitoring ? "pause.circle" : "play.circle")
                    }.disabled(model.busy || (model.recordingURL != nil && model.isMonitoring))
                }
            }
            if model.latest?.device.isDemo == true {
                Label("SYNTHETIC DEMO · no battery measurements", systemImage: "testtube.2").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
            if model.openedRecording != nil {
                Label("Saved recording · offline analysis", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
            }
            if model.page == .profile { ProfileWorkspace(model:model) }
            else if model.page == .recordings { recordings }
            else if model.page == .history { history }
            else if model.latest == nil {
                ContentUnavailableView {
                    Label("No " + (model.page == .cells ? "cell readings" : model.page == .charts ? "chart samples" : "live measurements") + " yet", systemImage: model.page.icon)
                } description: {
                    Text(model.device == nil
                         ? "Connect to the BMS and start monitoring, explore the offline demo, or open a saved recording."
                         : model.isMonitoring
                         ? "Reading the BMS. Measurements appear after the first polling cycle completes."
                         : "Monitoring is paused. Start monitoring to acquire measurements.")
                } actions: {
                    Button("Refresh Connections") { model.refreshPorts() }
                    Button("Open Recording…") { model.openRecording() }.disabled(model.busy)
                }.frame(maxHeight: .infinity)
            } else {
                switch model.page {
                case .overview: overview
                case .cells: cells
                case .charts: charts
                default: EmptyView()
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var subtitle: String {
        if let recording = model.openedRecording { return recording.url.lastPathComponent + " · " + String(recording.totalSamples) + " samples recorded" }
        if let latest = model.latest { return "Last acquisition " + latest.finishedAt.formatted(date: .omitted, time: .standard) + " · each signal retains its acquisition time" }
        return "Monitor, chart and record your battery locally."
    }
    private var overview: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210))], spacing: 14) {
                ForEach([ParameterPID.packVoltage,.packCurrent,.packPower,.soc,.highTemperature,.stateOfHealth,.chargeLimit,.dischargeLimit], id: \.self) { pid in
                    let reading = model.latest?.reading(pid)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(pid.title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                        Text(reading?.formatted ?? "Unavailable").font(.system(size: 26, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                        if let time = reading?.acquiredAt {
                            Text(time, style: .time).font(.caption).foregroundStyle(.secondary)
                            if reading?.value == nil { Text("Not measured").font(.caption).foregroundStyle(.orange) }
                            else { TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(context.date.timeIntervalSince(time) > 15 ? "Stale reading" : "Acquired").font(.caption).foregroundStyle(context.date.timeIntervalSince(time) > 15 ? Color.orange : Color.secondary)
                            } }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let bits = model.latest?.reading(.relayState)?.value {
                GroupBox("BMS outputs") {
                    HStack(spacing: 22) {
                        output("Charge enable", UInt16(bits) & 2 != 0)
                        output("Discharge enable", UInt16(bits) & 1 != 0)
                        output("Charger safety", UInt16(bits) & 4 != 0)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 16)
            }
            if let bits = model.latest?.reading(.limitReasons)?.value {
                let reasons = LiveDecoding.limitReasons(UInt16(bits))
                GroupBox("Current-limit reduction reasons") {
                    Text(reasons.isEmpty ? "No mapped limit-reduction flags are set." : reasons.joined(separator: " · "))
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.padding(.top, 10)
            }
            GroupBox("All acquired parameters") {
                ForEach(model.latest?.readings ?? []) { reading in
                    HStack {
                        Text(reading.title).frame(maxWidth: .infinity, alignment: .leading)
                        Text(reading.formatted).monospacedDigit()
                        Text(reading.acquiredAt, style: .time).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).help(reading.note ?? "Raw reply: " + reading.rawHex)
                }
            }.padding(.top, 10)
            Text("Charge current is negative. Polling is sequential; the refresh interval depends on serial throughput and supported parameters.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
        }
    }
    private func output(_ title: String, _ active: Bool) -> some View {
        Label(title + (active ? " ON" : " OFF"), systemImage: active ? "circle.fill" : "circle").font(.caption).foregroundStyle(active ? Color.teal : Color.secondary)
    }
    private var cells: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Picker("Measurement", selection: $model.cellQuantity) {
                    ForEach(CellQuantity.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 480)
                if model.device != nil, !model.isMonitoring { Button("Start Monitoring") { model.startMonitoring() } }
            }
            Text("Changes apply on the next polling cycle. Unpopulated channels are retained in the table; they are excluded from summary values.").font(.caption).foregroundStyle(.secondary)
            let rows = model.latest?.cells ?? []
            let configured = rows.filter { $0.populated != false }
            let values = configured.compactMap { $0.value(for: model.cellQuantity) }
            if let low = values.min(), let high = values.max() {
                HStack(spacing: 30) {
                    statistic("Lowest", low)
                    statistic("Highest", high)
                    statistic("Delta", high - low)
                    statistic("Average", values.reduce(0,+) / Double(values.count))
                }
            }
            Chart(configured) { cell in
                if let value = cell.value(for: model.cellQuantity) {
                    BarMark(x: .value("Cell", String(cell.number)), y: .value(model.cellQuantity.unit, value))
                        .foregroundStyle(cell.balancing == true ? Color.orange : Color.teal)
                }
            }.chartYAxisLabel(model.cellQuantity.unit).frame(height: 190)
            Table(rows) {
                TableColumn("Cell") { Text(String($0.number)) }.width(45)
                TableColumn(model.cellQuantity.title) { cell in
                    Text(cell.value(for: model.cellQuantity).map { $0.formatted(.number.precision(.fractionLength(3))) + " " + model.cellQuantity.unit } ?? "Unavailable").monospacedDigit()
                }
                TableColumn("Configured") { Text($0.populated.map { $0 ? "Yes" : "No" } ?? "Unknown") }.width(90)
                TableColumn("Balancing") { Text($0.balancing.map { $0 ? "Active" : "Off" } ?? "Unknown") }.width(90)
                TableColumn("Acquired") { cell in Text(cell.acquiredAt?.formatted(date: .omitted, time: .standard) ?? "—").font(.caption) }
            }
            ForEach(Array((model.latest?.notes ?? []).enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func statistic(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted(.number.precision(.fractionLength(3))) + " " + model.cellQuantity.unit).font(.headline).monospacedDigit()
        }
    }
    private var charts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu("Select Signals") {
                    ForEach(ParameterPID.allCases.filter { $0 != .maximumCells && $0 != .relayState && $0 != .limitReasons }, id: \.self) { pid in
                        Toggle(pid.title, isOn: Binding(get: { model.chartKeys.contains(pid.key) }, set: { if $0 { model.chartKeys.insert(pid.key) } else { model.chartKeys.remove(pid.key) } }))
                    }
                }
                Menu(model.chartPreset?.rawValue ?? "Custom") {
                    ForEach(ChartPreset.allCases) { preset in
                        Button(preset.rawValue) { model.chartKeys = preset.keys }
                    }
                }
                .accessibilityLabel("Chart preset: " + (model.chartPreset?.rawValue ?? "Custom"))
                Picker("Window", selection: $model.chartWindow) {
                    Text("1 min").tag(60.0); Text("10 min").tag(600.0); Text("1 hour").tag(3600.0); Text("All retained").tag(0.0)
                }.frame(width: 190)
                Toggle("Follow live", isOn: $model.followLiveCharts).toggleStyle(.checkbox)
                Button(model.chartsPaused ? "Resume Chart" : "Pause Chart") { model.toggleChartPause() }
                Button("Export CSV…") { model.exportLiveCSV() }.disabled(model.busy || model.snapshots.isEmpty)
            }
            Text("Pausing the chart keeps acquisition and disk recording running. Hover or drag to inspect a value. Missing reads and long gaps break the plotted line.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(ParameterPID.allCases.filter { model.chartKeys.contains($0.key) }, id: \.self) { pid in
                        SignalChart(pid: pid, snapshots: model.chartsPaused ? model.frozenChartSnapshots : model.snapshots, window: model.chartWindow, followLive: model.followLiveCharts && !model.chartsPaused)
                    }
                }
            }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Download Historical Statistics") { model.downloadHistory() }.disabled(model.busy || model.device == nil)
                Button("Export History JSON…") { model.exportHistory() }.disabled(model.history == nil || model.busy)
            }
            Text("Lifetime statistics are counters and accumulated exposure times. They do not contain a historical voltage/current time series.").font(.callout).foregroundStyle(.secondary)
            if let history = model.history {
                Text("Acquired " + history.acquiredAt.formatted() + " · " + (history.device.serialNumber ?? history.device.signature)).font(.caption)
                Table(history.statistics) {
                    TableColumn("Statistic",value: \.name)
                    TableColumn("Value",value: \.formatted)
                    TableColumn("Unit",value: \.unit).width(90)
                }
            } else { ContentUnavailableView("No historical statistics downloaded",systemImage:"clock.arrow.circlepath") }
        }
    }
    private var recordings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if model.recordingURL == nil {
                    Button { model.startRecording() } label: { Label("Start Recording…", systemImage: "record.circle") }.disabled(model.device == nil || model.busy)
                } else {
                    Button { model.stopRecording() } label: { Label("Stop & Save Recording", systemImage: "stop.circle") }.disabled(model.busy)
                }
                Button("Open Recording…") { model.openRecording() }.disabled(model.busy || model.recordingURL != nil)
                Button("Export Retained Samples (CSV)…") { model.exportLiveCSV() }.disabled(model.snapshots.isEmpty || model.busy)
            }
            if let url = model.recordingURL {
                Label("Recording to " + url.path, systemImage: "record.circle.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            Text("Recordings preserve each acquired value, its Mac timestamp, raw replies, and device identity. Files are written incrementally and stop at 100 MB. The chart retains up to 2,000 polling cycles; the recording keeps earlier samples.")
                .foregroundStyle(.secondary)
            if model.knownRecordings.isEmpty { ContentUnavailableView("No recordings opened yet", systemImage: "waveform.path", description: Text("Connect a BMS or use the demo, then start recording.")) }
            else {
                List(model.knownRecordings, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading) { Text(url.lastPathComponent).fontWeight(.medium); Text(url.path).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Open") { model.openRecording(url: url) }.buttonStyle(.bordered).accessibilityLabel("Open " + url.lastPathComponent).disabled(model.busy || model.recordingURL != nil)
                    }.padding(.vertical, 6).onTapGesture(count: 2) { model.openRecording(url: url) }
                }.clipShape(RoundedRectangle(cornerRadius: 10))
            }
            ForEach(Array(model.recordingMessages.enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.orange) }
            Spacer()
        }
    }
}

private struct SignalChart: View {
    let pid: ParameterPID
    let snapshots: [LiveSnapshot]
    let window: Double
    let followLive: Bool
    @State private var scrollTime = Date()
    @State private var selectedTime: Date?
    private var points: [TrendPoint] {
        var output: [TrendPoint] = [], segment = 0, previous: Date?
        for snapshot in snapshots {
            guard let reading = snapshot.reading(pid), let value = reading.value else { segment += 1; previous = nil; continue }
            if let previous, reading.acquiredAt.timeIntervalSince(previous) > 15 { segment += 1 }
            previous = reading.acquiredAt
            output.append(.init(time: reading.acquiredAt, key: pid.key, value: value, segment: segment))
        }
        return output
    }
    var body: some View {
        let data = points
        let span = window > 0 ? window : max(30, data.last?.time.timeIntervalSince(data.first?.time ?? .now) ?? 30)
        let end = data.last?.time ?? Date()
        let beginning = min(data.first?.time ?? end, end.addingTimeInterval(-span))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pid.title).font(.headline)
                Spacer()
                if let time = selectedTime, let nearest = data.min(by: { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }) {
                    Text(nearest.time.formatted(date: .omitted, time: .standard) + " · " + nearest.value.formatted(.number.precision(.fractionLength(3))) + " " + pid.unit).font(.caption.monospaced())
                } else if let last = data.last { Text(last.value.formatted(.number.precision(.fractionLength(2))) + " " + pid.unit).font(.callout.monospaced()) }
            }
            Chart {
                ForEach(data) { point in
                LineMark(x: .value("Acquired", point.time), y: .value(pid.unit, point.value), series: .value("Continuity", point.segment)).foregroundStyle(.teal)
                if data.count == 1 { PointMark(x: .value("Acquired", point.time), y: .value(pid.unit, point.value)).foregroundStyle(.teal) }
                }
                if let selectedTime { RuleMark(x: .value("Selected", selectedTime)).foregroundStyle(.secondary.opacity(0.3)) }
            }.chartXScale(domain: beginning...end.addingTimeInterval(1))
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.hour().minute().second())
                } }
                .chartXSelection(value: $selectedTime).chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: span)
                .chartScrollPosition(x: $scrollTime)
                .chartYAxisLabel(pid.unit).frame(height: 140)
                .onAppear { scrollTime = (data.last?.time ?? .now).addingTimeInterval(-span) }
                .onChange(of: data.last?.time) { _, last in
                    if followLive, let last { scrollTime = last.addingTimeInterval(-span) }
                }
                .onChange(of: window) { _, _ in scrollTime = (data.last?.time ?? .now).addingTimeInterval(-span) }
            if data.isEmpty { Text("No measured samples for this signal").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}


struct FaultDetailPanel: View {
    @Bindable var model: AppModel
    let code: UInt16
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(DiagnosticDecoder.dtc(code) + " · " + DiagnosticDecoder.faultDescription(DiagnosticDecoder.dtc(code))).font(.headline)
                Spacer()
                Button("Download Fault Detail") { model.downloadFaultDetail() }.disabled(model.busy || model.device == nil)
            }
            if let detail = model.selectedFaultDetail, detail.rawCode == code {
                Text(detail.state.label + " · " + detail.subcodeDescription).font(.caption)
                Text("Subcodes: " + detail.subcodes.map { String(format:"0x%04X",$0) }.joined(separator:", ")).font(.caption.monospaced())
                if let frame = detail.frameIndex { Text("Stored snapshot selector \(frame) · downloaded \(detail.acquiredAt.formatted()). These are frozen fault readings, not live measurements.").font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading,spacing:6) {
                        ForEach(detail.readings) { value in
                            HStack { Text(value.title); Spacer(); Text(value.formatted).monospacedDigit() }.font(.caption).help(value.note ?? "")
                        }
                        ForEach(Array(detail.notes.enumerated()),id: \.offset) { _,note in Text(note).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:130)
            } else { Text("Downloads diagnostic subcodes and searches the original utility’s 30 freeze-frame selectors. Unavailable fields remain explicit.").font(.caption).foregroundStyle(.secondary) }
        }.padding(12).background(.background,in:RoundedRectangle(cornerRadius:10))
    }
}
