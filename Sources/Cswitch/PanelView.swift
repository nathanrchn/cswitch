import AppKit
import CswitchCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var addingAccount = false
    @State private var addingDevice = false
    @State private var editing: SavedAccount?
    @State private var forgetting: SavedAccount?
    @State private var contentHeight: CGFloat = 0

    private var maxScrollHeight: CGFloat { max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 200) }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    devicesSection
                    if let login = model.unsavedLogins.first { unsavedLoginCard(login.device, email: login.email) }
                    if let failure = model.failure { failureCard(failure) }
                    accountsSection
                    HistoryView(report: model.history, loading: model.historyLoading)
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
                .background(GeometryReader { Color.clear.preference(key: ContentHeight.self, value: $0.size.height) })
            }
            .frame(height: min(max(contentHeight, 120), maxScrollHeight))
            .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            footer
        }
        .frame(width: 360)
        // Let NSPopover supply the current system material and corner treatment.
        .background(.clear)
        .task { await model.appeared() }
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

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                AppGlyph()
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Cswitch").font(.system(size: 14, weight: .semibold))
                        if model.demo {
                            Text("DEMO").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text("Claude Code accounts").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    if model.refreshing { ProgressView().controlSize(.small).scaleEffect(0.75) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(IconButtonStyle())
                .disabled(model.refreshing || model.switchProgress != nil)
                .help("Check devices and usage").accessibilityLabel("Refresh")
                IconMenu(systemImage: "ellipsis", help: "More") {
                    Button("Add SSH device…") { addingDevice = true }
                    Divider()
                    Text("Cswitch " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                    Button("Quit Cswitch") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                }
            }
            SyncBanner(summary: model.sync, checked: model.lastChecked)
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Devices") {
                Button("Add device") { addingDevice = true }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accentText)
                    .disabled(model.busy)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Rectangle().fill(Palette.divider).frame(height: 1) }
                    deviceRow(device)
                }
            }
            .card()
        }
    }

    private func deviceRow(_ device: Device) -> some View {
        let live = model.isLive(device)
        return HStack(spacing: 10) {
            DeviceIcon(device: device, dimmed: !live)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(live ? Color.primary : Palette.secondary)
                deviceStatusLine(device)
            }
            Spacer(minLength: 6)
            accountPill(model.deviceAccount(on: device), live: live).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .help(model.deviceDetails(device))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func deviceStatusLine(_ device: Device) -> some View {
        Group {
            if let progress = model.switchProgress, model.isLive(device) || progress.finished[device.id] != nil {
                if let succeeded = progress.finished[device.id] {
                    Label(succeeded ? "Switched" : "Failed", systemImage: succeeded ? "checkmark" : "xmark")
                        .foregroundStyle(succeeded ? Palette.success : Palette.danger)
                } else {
                    HStack(spacing: 5) { Spinner(); Text(device.sshHost == nil ? "Applying…" : "Applying over SSH…") }
                }
            } else if model.checking.contains(device.id), !model.isLive(device) {
                HStack(spacing: 5) { Spinner(); Text("Checking…") }
            } else if let status = model.statuses[device.id] {
                if model.keychainOverride(on: device) {
                    Label("Keychain login in use", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                } else if status.claudePath == nil {
                    Label("Claude Code not found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(Palette.live).frame(width: 6, height: 6)
                        Text(status.version.map { "Live · v" + $0 } ?? "Live")
                    }
                }
            } else {
                HStack(spacing: 5) {
                    Circle().strokeBorder(Palette.secondary, lineWidth: 1).frame(width: 6, height: 6)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(model.lastSeen(device).map { "Offline · seen " + Format.relative($0, now: context.date) } ?? "Unreachable")
                    }
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
        .labelStyle(CompactLabelStyle())
    }

    @ViewBuilder private func accountPill(_ value: DeviceAccount, live: Bool) -> some View {
        switch value {
        case .saved(let id):
            let account = model.account(id: id)
            HStack(spacing: 6) {
                Avatar(label: account?.label ?? "?", color: live ? color(for: id) : Palette.secondary.opacity(0.55), size: 18)
                Text(account?.label ?? "Saved").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .foregroundStyle(live ? Color.primary : Palette.secondary)
            }
            .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
            .background(live ? Palette.fill : .clear, in: Capsule())
            .overlay { if !live { Capsule().strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) } }
        case .unsaved(let email, _, _):
            HStack(spacing: 6) {
                Text("?").font(.system(size: 10, weight: .bold)).frame(width: 16, height: 16)
                    .overlay { Circle().strokeBorder(Palette.warning, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])) }
                Text(email).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            .foregroundStyle(Palette.warning)
            .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 3)
            .background(Palette.warningTint, in: Capsule())
            .opacity(live ? 1 : 0.6)
        case .signedOut, .other:
            Text(model.displayName(value)).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Palette.fill, in: Capsule())
        case .unknown:
            Text("—").font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }

    private func unsavedLoginCard(_ device: Device, email: String) -> some View {
        let keychain = model.keychainOverride(on: device)
        let here = device.sshHost == nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.warning).frame(width: 28, height: 28)
                    .background(Palette.warningTint, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("New login on \(device.name)").font(.system(size: 12, weight: .semibold))
                    Text(keychain
                         ? "Claude Code here uses a macOS Keychain login. Import verifies the account with Claude before saving it."
                         : "Claude Code \(here ? "here" : "there") is signed in as \(email), which Cswitch hasn't saved yet.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Not now") { model.dismissLogin(on: device, email: email) }.buttonStyle(.plainAction)
                Button("Save account") { Task { _ = await model.saveCurrent(on: device, label: "") } }
                    .buttonStyle(.primaryAction).disabled(model.busy)
            }
        }
        .padding(12).card()
    }

    private func failureCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 12))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { model.failure = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(IconButtonStyle(size: 20)).help("Dismiss").accessibilityLabel("Dismiss")
        }
        .foregroundStyle(Palette.danger)
        .padding(10)
        .background(Palette.dangerTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Accounts")
            if model.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No saved accounts").font(.system(size: 13, weight: .semibold))
                    Text("Sign in once, then switch every device to that account with one click.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Add account") { addingAccount = true }.buttonStyle(.primaryAction).padding(.top, 4).disabled(model.busy)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                ForEach(model.accounts) { account in accountCard(account) }
            }
        }
    }

    private func accountCard(_ account: SavedAccount) -> some View {
        let state = model.accountState(account)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Avatar(label: account.label, color: color(for: account.id))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(account.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let plan = Format.plan(account.plan) {
                            Text(plan).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                    if account.label != account.identity.email {
                        Text(account.identity.email).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                accountAction(account, state: state).fixedSize()
                IconMenu(systemImage: "ellipsis", help: "Manage \(account.label)", size: 24) { accountMenu(account, state: state) }
                    .disabled(model.busy)
            }
            if model.devices.count > 1, showsDeviceChips(state) { deviceChips(account) }
            usageGrid(account)
            if let error = model.errors[account.id] {
                Label(error, systemImage: "exclamationmark.circle").labelStyle(CompactLabelStyle())
                    .font(.system(size: 10.5)).foregroundStyle(Palette.secondary).lineLimit(2).help(error)
            } else if let date = account.usage?.fetchedAt, Date().timeIntervalSince(date) > 300 {
                Text("Saved usage · \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
        }
        .padding(12)
        .card(highlight: highlight(state))
        .contextMenu { accountMenu(account, state: state) }
    }

    private func highlight(_ state: AccountState) -> Color? {
        switch state {
        case .active: return Palette.accent
        case .switching: return Palette.accent.opacity(0.55)
        default: return nil
        }
    }

    private func showsDeviceChips(_ state: AccountState) -> Bool {
        switch state {
        case .partial, .active(cached: true): return true
        default: return false
        }
    }

    @ViewBuilder private func accountAction(_ account: SavedAccount, state: AccountState) -> some View {
        switch state {
        case .active:
            Label("Active", systemImage: "checkmark").labelStyle(CompactLabelStyle(spacing: 4))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accentText)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(model.selectionDetails())
        case .switching:
            HStack(spacing: 6) { Spinner(); Text("Switching") }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4.5)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .partial:
            Button("Switch all") { Task { await model.switchTo(account) } }
                .buttonStyle(.primaryAction).disabled(model.busy)
                .help("Switch every saved device to \(account.label).\n" + model.selectionDetails())
        case .inactive:
            let anyPartial = model.accounts.contains { if case .partial = model.accountState($0) { return true }; return false }
            Button("Switch") { Task { await model.switchTo(account) } }
                .buttonStyle(ActionButtonStyle(kind: anyPartial ? .secondary : .primary)).disabled(model.busy)
                .help("Switch every saved device to \(account.label). Unavailable devices are reported so you can retry.")
        }
    }

    @ViewBuilder private func accountMenu(_ account: SavedAccount, state: AccountState) -> some View {
        Button("Rename…") { editing = account }
        if state != .inactive {
            Button("Apply saved login again…") { Task { await model.switchTo(account, force: true) } }.disabled(model.busy)
        }
        Divider()
        Button("Delete saved account…", role: .destructive) { forgetting = account }
    }

    private func deviceChips(_ account: SavedAccount) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(model.devices) { device in
                let on = model.deviceAccount(on: device).savedID == account.id
                let live = model.isLive(device)
                HStack(spacing: 4) {
                    if on && live { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                    Text(device.name + (live ? "" : (on ? " · last known" : " · offline")))
                }
                .font(.system(size: 11, weight: on && live ? .semibold : .regular))
                .foregroundStyle(on && live ? Palette.accentText : Palette.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(on && live ? Palette.accentTint : .clear, in: Capsule())
                .overlay {
                    if !(on && live) {
                        Capsule().strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: live ? [] : [3, 2]))
                    }
                }
            }
        }
    }

    private func usageGrid(_ account: SavedAccount) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                ForEach([("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_fable", "Fable")], id: \.0) { key, label in
                    let window = account.usage?.windows.first { $0.id == key }
                    GridRow {
                        Text(label).foregroundStyle(Palette.secondary).frame(width: 46, alignment: .leading)
                        Meter(value: window?.used, color: meterColor(window?.used))
                        Text(window.map { String(format: "%.0f%%", $0.used) } ?? "—")
                            .fontWeight(.semibold).monospacedDigit()
                            .foregroundStyle((window?.used ?? 0) >= 90 ? Palette.danger : Color.primary)
                            .frame(width: 34, alignment: .trailing)
                        Text(resetText(window, now: context.date)).foregroundStyle(Palette.secondary).monospacedDigit()
                            .frame(width: 56, alignment: .trailing).lineLimit(1)
                    }
                    .help(window?.resetsAt.map { "Resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Reset time not reported")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(label), \(window.map { String(format: "%.0f percent used", $0.used) } ?? "unavailable")")
                }
            }
            .font(.system(size: 11))
        }
    }

    private func meterColor(_ used: Double?) -> Color {
        guard let used else { return Palette.accent }
        if used >= 90 { return Palette.dangerFill }
        if used >= 75 { return Palette.warningFill }
        return Palette.accent
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

    private func color(for accountID: String) -> Color {
        let index = model.accounts.firstIndex { $0.id == accountID } ?? 0
        return Palette.avatars[index % Palette.avatars.count]
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { addingAccount = true } label: { Label("Add account", systemImage: "plus") }
                .buttonStyle(.secondaryAction).disabled(model.busy)
            Spacer()
            Text(plural(model.accounts.count, "account") + " · " + plural(model.devices.count, "device"))
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Palette.divider).frame(height: 1) }
    }
}

func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SyncBanner: View {
    let summary: SyncSummary
    let checked: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                icon.font(.system(size: 13, weight: .semibold)).frame(width: 16)
                text.font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                if showsTime, checked != nil {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Format.relative(checked, now: context.date)).font(.system(size: 11))
                    }
                }
            }
            if case .switching(_, let done, let total) = summary {
                Meter(value: 100 * Double(done) / Double(max(total, 1)), color: Palette.accent, height: 3)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var showsTime: Bool {
        switch summary {
        case .inSync, .partial, .mixed: return true
        default: return false
        }
    }

    @ViewBuilder private var icon: some View {
        switch summary {
        case .checking, .switching: Spinner()
        case .inSync: Image(systemName: "checkmark.circle.fill")
        case .partial: Image(systemName: "exclamationmark.circle.fill")
        case .mixed: Image(systemName: "exclamationmark.triangle.fill")
        case .notDetected: Image(systemName: "questionmark.circle")
        }
    }

    private var text: Text {
        switch summary {
        case .checking:
            return Text("Checking your devices…")
        case .switching(let label, let done, let total):
            return Text("Switching to \(label)").fontWeight(.semibold) + Text(" · \(done) of \(plural(total, "device"))")
        case .inSync(let label, let devices, let cached):
            let detail = " · \(label) on " + (devices == 1 ? "this device" : devices == 2 ? "both devices" : "all \(devices) devices")
            return Text("In sync").fontWeight(.semibold) + Text(detail + (cached > 0 ? ", \(cached) last known" : ""))
        case .partial(let label, let count, let total):
            return Text("Partly checked").fontWeight(.semibold) + Text(" · \(label) on \(count) of \(plural(total, "device"))")
        case .mixed(let accounts, let devices):
            return Text("Out of sync").fontWeight(.semibold) + Text(" · \(accounts) logins on \(plural(devices, "device"))")
        case .notDetected:
            return Text("No Claude Code login detected")
        }
    }

    private var foreground: Color {
        switch summary {
        case .inSync: return Palette.success
        case .partial, .mixed: return Palette.warning
        case .switching: return Palette.accentText
        case .checking, .notDetected: return Palette.secondary
        }
    }

    private var tint: Color {
        switch summary {
        case .inSync: return Palette.successTint
        case .partial, .mixed: return Palette.warningTint
        case .switching: return Palette.accentTint
        case .checking, .notDetected: return Palette.fill
        }
    }
}

private struct DeviceIcon: View {
    let device: Device
    var dimmed = false
    var body: some View {
        Image(systemName: device.sshHost == nil ? "laptopcomputer" : "server.rack")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(dimmed ? Palette.secondary : Color.primary)
            .frame(width: 28, height: 28)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct Spinner: View {
    var body: some View { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
}

struct Meter: View {
    let value: Double?
    let color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                if let value, value > 0 {
                    Capsule().fill(color).frame(width: max(height, geometry.size.width * min(1, value / 100)))
                }
            }
        }
        .frame(height: height)
        .opacity(value == nil ? 0.4 : 1)
    }
}

struct CompactLabelStyle: LabelStyle {
    var spacing: CGFloat = 4
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) { configuration.icon; configuration.title }
    }
}

// MARK: Sheets

private struct SheetHeader: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Field<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            content()
        }
    }
}

private struct AddAccountView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var label = ""
    @State private var code = ""
    @State private var showCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Add account", detail: "Sign in once. Cswitch can then put this account on every device with one click.")
            Field(title: "Name") {
                TextField("e.g. Personal", text: $label).textFieldStyle(.roundedBorder).disabled(model.busy)
            }
            if model.isSigningIn { signingIn } else { signInNote }
            if let failure = model.failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
            } else if let message = model.message, !model.isSigningIn {
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            if !model.isSigningIn, !model.devices.isEmpty { importSection }
            HStack {
                Button("Cancel") { model.cancelSignIn(); dismiss() }
                    .buttonStyle(ActionButtonStyle(kind: .secondary, size: 13)).keyboardShortcut(.cancelAction)
                Spacer()
                if model.busy && !model.isSigningIn { ProgressView().controlSize(.small) }
                Button(model.isSigningIn ? "Waiting for sign-in…" : "Sign in") {
                    Task { if await model.signIn(label: label) { dismiss() } }
                }
                .buttonStyle(ActionButtonStyle(kind: .primary, size: 13))
                .keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }
        .padding(24).frame(width: 400)
        // The menu popover can disappear when the sign-in window takes focus.
        // Only explicit Cancel or closing that window cancels the model's flow.
    }

    private var signInNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary).padding(.top, 1)
            Text("Opens Claude's sign-in in a private Cswitch window. Use email sign-in there; for Google or SSO, copy the sign-in link into a private browser once it starts.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var signingIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.message ?? "Waiting for sign-in…").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 8) {
                Button("Show sign-in window") { model.showSignIn() }.buttonStyle(.secondaryAction)
                Button("Copy sign-in link") { model.copySignInLink() }.buttonStyle(.secondaryAction).disabled(model.loginURL == nil)
            }
            DisclosureGroup("Browser callback didn’t finish?", isExpanded: $showCode) {
                HStack(spacing: 8) {
                    TextField("Paste authorization code or callback URL", text: $code).textFieldStyle(.roundedBorder)
                    Button("Complete") { model.submitSignInCode(code) }.buttonStyle(.secondaryAction).disabled(code.isEmpty)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Rectangle().fill(Palette.border).frame(height: 1)
                Text("or import a login found on your devices").font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize()
                Rectangle().fill(Palette.border).frame(height: 1)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Rectangle().fill(Palette.divider).frame(height: 1) }
                    importRow(device)
                }
            }
            .card()
        }
    }

    private func importRow(_ device: Device) -> some View {
        let value = model.deviceAccount(on: device)
        let live = model.isLive(device)
        let saved = value.savedID.flatMap(model.account(id:))
        let plan = Format.plan(saved?.plan ?? model.statuses[device.id]?.login?.plan).map { " · " + $0.capitalized } ?? ""
        let title: String, subtitle: String
        switch value {
        case .saved: title = saved?.identity.email ?? device.name; subtitle = "on \(device.name)" + plan
        case .unsaved(let email, _, _): title = email; subtitle = "on \(device.name)" + plan
        case .signedOut: title = device.name; subtitle = "Signed out of Claude Code"
        case .other(let text): title = device.name; subtitle = text
        case .unknown: title = device.name; subtitle = live ? "No Claude Code login" : "Offline · can't check its login"
        }
        return HStack(spacing: 10) {
            DeviceIcon(device: device, dimmed: !live)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(live || saved != nil ? Color.primary : Palette.secondary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let saved {
                Label("Saved as \(saved.label)", systemImage: "checkmark").labelStyle(CompactLabelStyle())
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            } else if case .unsaved = value, live {
                Button("Import") { Task { if await model.saveCurrent(on: device, label: label) { dismiss() } } }
                    .buttonStyle(.secondaryAction).disabled(model.busy)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

private struct AddDeviceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var host = ""
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Add SSH device", detail: "Uses your existing SSH configuration and keys. The Linux device needs Python 3 and Claude Code.")
            Field(title: "SSH host") { TextField("SSH alias or user@hostname", text: $host).textFieldStyle(.roundedBorder) }
            Field(title: "Name") { TextField("Optional, e.g. gpu-box", text: $name).textFieldStyle(.roundedBorder) }
            if let failure = model.failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(ActionButtonStyle(kind: .secondary, size: 13)).keyboardShortcut(.cancelAction)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Connect") { Task { if await model.addDevice(name: name, host: host) { dismiss() } } }
                    .buttonStyle(ActionButtonStyle(kind: .primary, size: 13))
                    .keyboardShortcut(.defaultAction).disabled(model.busy || host.isEmpty)
            }
        }
        .padding(24).frame(width: 380)
    }
}

private struct RenameView: View {
    @ObservedObject var model: AppModel
    let account: SavedAccount
    @Environment(\.dismiss) var dismiss
    @State private var label = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Rename account", detail: account.identity.email)
            Field(title: "Name") { TextField("Label", text: $label).textFieldStyle(.roundedBorder) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(ActionButtonStyle(kind: .secondary, size: 13)).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { Task { await model.rename(account, label: label); dismiss() } }
                    .buttonStyle(ActionButtonStyle(kind: .primary, size: 13)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 320).onAppear { label = account.label }
    }
}
