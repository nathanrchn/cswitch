import AppKit
import CswitchCore
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--check-device"), CommandLine.arguments.indices.contains(index + 1) {
            let host = CommandLine.arguments[index + 1]
            do {
                let status = try DeviceBackend().status(Device(name: host, sshHost: host))
                print("SSH helper connected. Claude Code: \(status.claudePath == nil ? "not found" : "installed"). Account identity: \(status.identity == nil ? "not signed in" : "present"). No credentials read or changed.")
            } catch { print(error.localizedDescription); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var model: AppModel!
    private var preview: NSWindow?
    private var poller: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !CommandLine.arguments.contains("--demo"), let identifier = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [])
            NSApplication.shared.terminate(nil)
            return
        }
        model = AppModel(demo: CommandLine.arguments.contains("--demo"))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = CswitchIcon.menuBarImage()
        item.button?.target = self; item.button?.action = #selector(toggle)
        item.button?.toolTip = "Cswitch · Claude Code accounts"
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
        if !model.demo {
            poller = Task { [weak self] in
                guard let model = self?.model else { return }
                await model.load()
                await model.refresh(interactive: false)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    await model.refresh(interactive: false)
                }
            }
        }
        if CommandLine.arguments.contains("--preview") {
            let controller = NSHostingController(rootView: PanelView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "Cswitch · Demo"
            window.styleMask = [.titled, .closable]
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            preview = window
        } else if CommandLine.arguments.contains("--show") { toggle() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        poller?.cancel(); model?.shutdown()
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
