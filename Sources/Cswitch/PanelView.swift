import AppKit
import CswitchCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var addingAccount = false
    @State private var addingDevice = false
    @State private var editing: SavedAccount?
    @State private var forgetting: SavedAccount?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Claude Code").font(.system(size: 13, weight: .semibold))
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if model.demo { Text("DEMO").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary) }
                Spacer()
                if model.busy { ProgressView().controlSize(.mini).accessibilityLabel("Working") }
                Menu {
                    Button("Add SSH device…") { addingDevice = true }
                    Divider()
                    Button("Quit Cswitch") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).buttonBorderShape(.circle)
                .controlSize(.small).fixedSize().help("Devices and app").accessibilityLabel("Devices and app")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                Text("All devices").font(.system(size: 12, weight: .medium))
                Spacer()
                Menu {
                    ForEach(model.data.devices) { device in
                        Text("\(device.name) · \(model.statuses[device.id] == nil ? "Unavailable" : "Connected")")
                        Text("Account: \(model.configuredAccountName(on: device))\(model.selectionIsCached(on: device) ? " (last known)" : "")")
                        if let error = model.deviceErrors[device.id] { Text(error) }
                    }
                    Divider()
                    Button("Add SSH device…") { addingDevice = true }
                } label: { Text("\(model.onlineCount)/\(model.data.devices.count) connected").font(.system(size: 10)) }
                .menuStyle(.button).controlSize(.mini).fixedSize()
            }
            .padding(.horizontal, 16).padding(.bottom, 10)

            Divider()
            if model.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No saved accounts").font(.system(size: 13, weight: .medium))
                    Text("Add a Claude Code account once, then switch it across all your devices together.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.accounts) { account in
                            accountRow(account)
                            if account.id != model.accounts.last?.id { Divider().padding(.horizontal, 16) }
                        }
                    }
                }
                .frame(height: min(CGFloat(model.accounts.count) * 142, 426))
            }

            if let text = model.failure {
                HStack(alignment: .top, spacing: 8) {
                    Text(text).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.failure = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).help("Dismiss")
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }

            Divider()
            HistoryView(report: model.history, loading: model.historyLoading)
            Divider()
            HStack {
                Button { addingAccount = true } label: { Label("Add account", systemImage: "plus") }
                    .controlSize(.small).disabled(model.busy)
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonBorderShape(.circle).controlSize(.small).disabled(model.busy).help("Refresh accounts and usage")
            }
            .font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 352)
        // Let NSPopover supply the current system material and corner treatment.
        .background(.clear)
        .nativeControls()
        .task {
            await model.appeared()
        }
        .sheet(isPresented: $addingAccount) { AddAccountView(model: model) }
        .sheet(isPresented: $addingDevice) { AddDeviceView(model: model) }
        .sheet(item: $editing) { account in RenameView(model: model, account: account) }
        .confirmationDialog("Delete saved account \(forgetting?.label ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("Delete saved account", role: .destructive) {
                if let account = forgetting { Task { await model.forget(account) } }
                forgetting = nil
            }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: { Text("Removes this saved login from Cswitch. Existing Claude Code logins and conversations on your devices stay in place.") }
    }

    private func accountRow(_ account: SavedAccount) -> some View {
        let active = model.isSelectedEverywhere(account)
        let selectedCount = model.selectedDeviceCount(account)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if account.label != account.identity.email {
                        Text(account.identity.email).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if active {
                    Label(model.selectionIsCurrentEverywhere ? "Selected" : "Last selected", systemImage: "checkmark")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .help(model.selectionDetails())
                } else {
                    if selectedCount > 0 {
                        Label("\(selectedCount)/\(model.data.devices.count)", systemImage: "checkmark")
                            .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                            .help(model.selectionDetails())
                    }
                    Button("Switch") { Task { await model.switchTo(account) } }
                        .font(.system(size: 11)).controlSize(.small).disabled(model.busy)
                        .help("Switch on all devices. Unavailable devices are reported so you can retry.")
                }
                Menu {
                    Button("Rename…") { editing = account }
                    if active {
                        Button("Apply saved login again…") { Task { await model.switchTo(account, force: true) } }
                    }
                    Divider()
                    Button("Delete saved account…", role: .destructive) { forgetting = account }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).buttonBorderShape(.circle)
                .controlSize(.mini).fixedSize().disabled(model.busy)
                .help("Manage \(account.label)")
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(spacing: 6) {
                    ForEach([("five_hour", "5 hours"), ("seven_day", "Weekly"), ("seven_day_fable", "Fable")], id: \.0) { key, label in
                        usageRow(account.usage?.windows.first { $0.id == key }, label: label, now: context.date)
                    }
                }
            }
            if let error = model.errors[account.id] {
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).help(error)
            } else if let date = account.usage?.fetchedAt, Date().timeIntervalSince(date) > 300 {
                Text("Saved usage · \(date.formatted(date: .omitted, time: .shortened))").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .contextMenu {
            Button("Rename…") { editing = account }
            if active {
                Button("Apply saved login again…") { Task { await model.switchTo(account, force: true) } }
                    .disabled(model.busy)
            }
            Button("Delete saved account…", role: .destructive) { forgetting = account }
        }
    }

    private func usageRow(_ window: UsageWindow?, label: String, now: Date) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 43, alignment: .leading).foregroundStyle(.secondary)
            ProgressView(value: min(100, window?.used ?? 0), total: 100)
                .tint((window?.used ?? 0) >= 95 ? .red : .accentColor)
                .opacity(window == nil ? 0.25 : 1)
                .accessibilityLabel("\(label), \(window.map { String(format: "%.0f percent used", $0.used) } ?? "unavailable")")
            Text(window.map { String(format: "%.0f%%", $0.used) } ?? "—")
                .monospacedDigit().frame(width: 33, alignment: .trailing)
            Text(resetText(window, now: now)).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing).lineLimit(1)
        }
        .font(.system(size: 10))
        .help(window?.resetsAt.map { "Resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Reset time not reported")
    }

    private func resetText(_ window: UsageWindow?, now: Date) -> String {
        guard let window else { return "Unknown" }
        guard let reset = window.resetsAt else { return window.used == 0 ? "Not started" : "—" }
        let minutes = Int(ceil(reset.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "Refresh" }
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

private struct AddAccountView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var label = ""
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add account").font(.headline)
            Text("Sign in once in a private Cswitch window. Your account will be available on this Mac and all your SSH devices.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Label, e.g. Personal", text: $label).textFieldStyle(.roundedBorder).disabled(model.busy)
            if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if model.isSigningIn {
                Button("Show sign-in window") { model.showSignIn() }
                Button("Copy sign-in link") { model.copySignInLink() }.disabled(model.loginURL == nil)
                DisclosureGroup("Browser callback didn’t finish?") {
                    TextField("Paste authorization code or callback URL", text: $code).textFieldStyle(.roundedBorder)
                    Button("Complete sign-in") { model.submitSignInCode(code) }.disabled(code.isEmpty)
                }.font(.caption)
            } else {
                if model.data.devices.count > 1 {
                    Picker("Import from", selection: Binding(get: { model.data.selectedDeviceID }, set: { id in Task { await model.select(id) } })) {
                        ForEach(model.data.devices) { Text($0.name).tag($0.id) }
                    }.disabled(model.busy)
                }
                Button("Import current file login from \(model.device.name)") {
                    Task { if await model.saveCurrent(label: label) { dismiss() } }
                }.font(.caption).disabled(model.busy)
            }
            HStack {
                Button("Cancel") { model.cancelSignIn(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.isSigningIn ? "Waiting for sign-in…" : "Sign in") {
                    Task { if await model.signIn(label: label) { dismiss() } }
                }
                    .nativePrimaryAction()
                    .keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }.padding(20).frame(width: 340).nativeControls()
        // The menu popover can disappear when the sign-in window takes focus.
        // Only explicit Cancel or closing that window cancels the model's flow.
    }
}

private struct AddDeviceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var host = ""
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add SSH device").font(.headline)
            Text("Uses your existing SSH configuration and keys. The Linux device needs Python 3 and Claude Code.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("SSH alias or user@hostname", text: $host).textFieldStyle(.roundedBorder)
            TextField("Device name (optional)", text: $name).textFieldStyle(.roundedBorder)
            if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Connect") { Task { if await model.addDevice(name: name, host: host) { dismiss() } } }
                    .nativePrimaryAction()
                    .keyboardShortcut(.defaultAction).disabled(model.busy || host.isEmpty)
            }
        }.padding(20).frame(width: 340).nativeControls()
    }
}

private struct RenameView: View {
    @ObservedObject var model: AppModel
    let account: SavedAccount
    @Environment(\.dismiss) var dismiss
    @State private var label = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename account").font(.headline)
            TextField("Label", text: $label).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { Task { await model.rename(account, label: label); dismiss() } }
                    .nativePrimaryAction().keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 300).nativeControls().onAppear { label = account.label }
    }
}
