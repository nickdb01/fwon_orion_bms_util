import SwiftUI
import BMSCore

struct ProfileWorkspace: View {
    @Bindable var model: AppModel
    @State private var password = ""
    @State private var query = ""
    @State private var showRaw = false
    @State private var editingSetting: ProfileSetting?
    @State private var confirmRead = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { if model.profileDraft != nil { confirmRead = true } else { model.downloadProfile() } } label: { Label("Read Current Profile",systemImage:"arrow.down.doc") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.device == nil || model.busy)
                Button("Save Profile Backup…") { model.exportProfile() }.disabled(model.profileSnapshot == nil || model.busy)
                if model.profileDownloading || model.profileUploading { ProgressView(value:model.progress).frame(width:130); Button("Cancel") { model.cancel() } }
            }
            HStack {
                Button("Edit Current Profile") { model.beginProfileEditing() }.disabled(model.profileSnapshot == nil || model.profileDraft != nil || model.busy)
                Button("Import Profile…") { model.importProfile() }.disabled(model.profileSnapshot == nil || model.busy)
                Button("Save Draft…") { model.saveProfileDraft() }.disabled(model.profileDraft == nil || model.busy)
                Button("Review Upload…") { model.reviewProfileUpload() }.disabled(model.profileDraft?.changedByteCount == 0 || model.profileDraft == nil || model.device == nil || model.busy)
            }
            Text("Edits and imports remain local drafts until you review and upload them. Uploads save an original backup and verify the complete profile by reading it back. Passwords are not saved.")
                .font(.callout).foregroundStyle(.secondary)
            if model.device?.isDemo == true {
                Text("Synthetic data. The password-protected demo uses password: demo").font(.caption).foregroundStyle(.orange)
            }
            if model.profileDownloading || model.profileUploading { Text(model.status).font(.caption) }
            if model.profileBackupURL != nil { Button("Show Original Profile Backup") { model.revealProfileBackup() }.font(.caption) }
            if let draft = model.profileDraft {
                HStack {
                    Text("LOCAL DRAFT · \(draft.changedByteCount) changed bytes · \(draft.source)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Spacer()
                    Button("Discard Draft") { model.profileDraft = nil }.disabled(model.busy)
                }
            }
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
                        Text(rawText(model.profileDraft?.data ?? snapshot.data)).font(.system(.caption,design:.monospaced)).textSelection(.enabled).padding(12)
                    }.frame(maxWidth:.infinity,minHeight:0,maxHeight:.infinity,alignment:.topLeading)
                } else {
                    Table((model.profileDraft?.settings ?? snapshot.settings).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) {
                        TableColumn("Setting",value:\.title)
                        TableColumn("Configured value",value:\.value)
                        TableColumn("Raw value") { Text(String($0.rawValue)).monospacedDigit() }.width(110)
                        TableColumn("Byte offset") { Text(String($0.offset)).monospacedDigit() }.width(85)
                        TableColumn("Edit") { setting in
                            Button("Edit") { editingSetting = setting }.disabled(model.profileDraft == nil || model.busy)
                        }.width(55)
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
        .confirmationDialog("Read the active profile and discard the local draft?",isPresented:$confirmRead) {
            Button("Discard Draft and Read",role:.destructive) { model.downloadProfile() }
        }
        .sheet(item:$editingSetting) { setting in ProfileSettingEditor(model:model,setting:setting) }
        .sheet(isPresented:$model.profileUploadReview) { ProfileUploadReview(model:model) }
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

private struct ProfileSettingEditor: View {
    @Bindable var model: AppModel
    let setting: ProfileSetting
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(setting.title).font(.title2.weight(.semibold))
            Text("Current draft: \(setting.value) · stored raw integer: \(setting.rawValue)").font(.callout)
            HStack {
                TextField("Configured value",text:$value).textFieldStyle(.roundedBorder).onSubmit { apply() }
                Text(model.profileDraft?.editorUnit(for:setting.id) ?? "raw")
            }
            if model.profileDraft?.editorUnit(for:setting.id) == "raw" {
                Text("The original configured integer is shown. Presentation units for this setting have not been verified; enter its raw value.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Text("This changes the local draft only.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Apply to Draft") { apply() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:480)
        .onAppear { value = model.profileDraft?.editorValue(for:setting.id) ?? "" }
    }
    private func apply() {
        do { try model.changeProfileSetting(setting.id,value:value); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct ProfileUploadReview: View {
    @Bindable var model: AppModel
    @State private var password = ""
    @State private var reviewed = false
    @State private var showBytes = false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Review Profile Upload").font(.title2.weight(.semibold))
            if let draft = model.profileDraft {
                Text("Target: \(model.device?.signature ?? "Disconnected") · \(model.device?.serialNumber ?? "Unknown serial") · firmware \(model.device?.firmware ?? "Unknown")")
                    .font(.callout)
                Text("\(draft.changedByteCount) changed configuration bytes · source: \(draft.source)").font(.caption)
                Toggle("Compare all changed bytes",isOn:$showBytes).toggleStyle(.checkbox)
                if showBytes {
                    Table(draft.byteChanges) {
                        TableColumn("Byte offset") { Text(String($0.id)) }
                        TableColumn("Before (hex)",value:\.before)
                        TableColumn("After (hex)",value:\.after)
                    }.frame(height:190)
                } else {
                    Table(draft.changes) {
                        TableColumn("Setting",value:\.title)
                        TableColumn("Before",value:\.before)
                        TableColumn("After",value:\.after)
                    }.frame(height:190)
                }
                ScrollView {
                    VStack(alignment:.leading,spacing:6) {
                        ForEach(draft.warnings,id:\.self) { Text($0).font(.caption) }
                        Text("The active profile is checked again and backed up before writing. An active recording is ended before upload. Success requires a full read-back match. Interrupted commits can leave the result uncertain; reconnect and read the active profile before retrying.").font(.caption)
                    }
                }.frame(height:110)
                SecureField("Existing profile password, if required",text:$password).textFieldStyle(.roundedBorder)
                Toggle("I have reviewed this complete profile for the connected battery and equipment.",isOn:$reviewed).toggleStyle(.checkbox)
                HStack {
                    Button("Cancel") { password = ""; model.profileUploadReview = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Upload & Verify") {
                        let supplied = password.isEmpty ? nil : password; password = ""
                        model.uploadProfile(password:supplied)
                    }.buttonStyle(.borderedProminent).disabled(!reviewed || model.busy || model.device == nil)
                }
            }
        }.padding(24).frame(width:690)
        .onDisappear { password = "" }
    }
}
