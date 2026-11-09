import SwiftUI
import BMSCore

struct ProfileWorkspace: View {
    @Bindable var model: AppModel
    @State private var password = ""
    @State private var query = ""
    @State private var showRaw = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { model.downloadProfile() } label: { Label("Read Current Profile",systemImage:"arrow.down.doc") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.device == nil || model.busy)
                Button("Save Profile Backup…") { model.exportProfile() }.disabled(model.profileSnapshot == nil || model.busy)
                if model.profileDownloading { ProgressView(value:model.progress).frame(width:130); Button("Cancel") { model.cancel() } }
            }
            Text("Reads the BMS settings without changing them. A password is requested only if the BMS requires authentication. Passwords are not saved or included in diagnostic traces.")
                .font(.callout).foregroundStyle(.secondary)
            if model.device?.isDemo == true {
                Text("Synthetic data. The password-protected demo uses password: demo").font(.caption).foregroundStyle(.orange)
            }
            if model.profileDownloading { Text(model.status).font(.caption) }
            if let snapshot = model.profileSnapshot {
                Text((snapshot.device.serialNumber ?? snapshot.device.signature) + " · acquired " + snapshot.acquiredAt.formatted() + " · \(snapshot.data.count) bytes · checksum verified")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Show complete raw profile",isOn:$showRaw).toggleStyle(.checkbox)
                    Spacer()
                    if !showRaw { TextField("Filter settings",text:$query).textFieldStyle(.roundedBorder).frame(width:220) }
                }
                if showRaw {
                    ScrollView([.horizontal,.vertical]) {
                        Text(rawText(snapshot.data)).font(.system(.caption,design:.monospaced)).textSelection(.enabled).padding(12)
                    }.frame(maxWidth:.infinity,minHeight:0,maxHeight:.infinity,alignment:.topLeading)
                } else {
                    Table(snapshot.settings.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) {
                        TableColumn("Setting",value:\.title)
                        TableColumn("Configured value",value:\.value)
                        TableColumn("Raw value") { Text(String($0.rawValue)).monospacedDigit() }.width(110)
                        TableColumn("Byte offset") { Text(String($0.offset)).monospacedDigit() }.width(85)
                    }.frame(minHeight:0,maxHeight:.infinity)
                }
                ForEach(Array(snapshot.notes.enumerated()),id:\.offset) { _, note in Text(note).font(.caption).foregroundStyle(.secondary) }
                if snapshot.authenticated { Label("Profile read session re-locked after authentication",systemImage:"lock.fill").font(.caption) }
            } else {
                ContentUnavailableView("No profile downloaded",systemImage:"doc.text.magnifyingglass",description:Text(model.device == nil ? "Connect to your BMS, then choose Read Current Profile." : "Choose Read Current Profile. Locked profiles require the correct BMS password."))
                    .frame(minHeight:0,maxHeight:.infinity)
            }
        }
        .frame(maxWidth:.infinity,minHeight:0,maxHeight:.infinity,alignment:.topLeading)
        .sheet(isPresented:$model.profileNeedsPassword,onDismiss:{ password = "" }) {
            VStack(alignment:.leading,spacing:16) {
                Text("Profile authentication").font(.title2.weight(.semibold))
                Text(model.profileAuthMessage).foregroundStyle(.secondary)
                SecureField("BMS profile password",text:$password).textFieldStyle(.roundedBorder)
                    .onSubmit { authenticate() }
                Text("Use the existing 1–8 character profile password. The app does not change or reset it.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { password = ""; model.profileNeedsPassword = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Authenticate & Read") { authenticate() }.keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty || model.device == nil)
                }
            }.padding(24).frame(width:430)
        }
        .onChange(of:model.device?.port) { _, port in if port == nil { password = ""; model.profileNeedsPassword = false } }
    }
    private func authenticate() {
        guard !password.isEmpty, model.device != nil else { return }
        let supplied = password; password = ""
        model.downloadProfile(password:supplied)
    }
    private func rawText(_ data: Data) -> String {
        let bytes = Array(data)
        return stride(from:0,to:bytes.count,by:16).map { offset in
            String(format:"%04X  ",offset) + bytes[offset..<min(offset+16,bytes.count)].map { String(format:"%02X",$0) }.joined(separator:" ")
        }.joined(separator:"\n")
    }
}
