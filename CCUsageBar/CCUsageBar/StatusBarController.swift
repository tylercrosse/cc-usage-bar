import AppKit
import SwiftUI

final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let viewModels = [
        UsageViewModel(provider: .claude),
        UsageViewModel(provider: .codex),
    ]
    private var clickMonitor: Any?
    private var rightClickMonitor: Any?
    private var rightClickMenu: NSMenu!
    private var refreshTimer: Timer?

    override init() {
        // Status item with SF Symbol icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.yaxis", accessibilityDescription: "AI Usage")
            button.image?.isTemplate = true  // Adapts to light/dark menu bar
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.target = self
        }

        // Right-click context menu
        rightClickMenu = NSMenu()
        rightClickMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        rightClickMenu.items.forEach { $0.target = self }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window == button.window else {
                return event
            }
            self.statusItem.menu = self.rightClickMenu
            button.performClick(nil)
            self.statusItem.menu = nil
            return nil
        }

        // Popover hosting the stacked per-provider SwiftUI views
        popover.contentSize = NSSize(width: 520, height: 410)
        popover.behavior = .transient     // Dismiss on outside click
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: UsageStackView(viewModels: viewModels))

        // Prefetch on launch so data is cached before the first click, then refresh
        // periodically in the background to keep it reasonably fresh.
        viewModels.forEach { $0.run(force: true) }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModels.forEach { $0.run(force: true) }
            }
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        stopClickMonitor()
        viewModels.forEach { $0.dismissPopover() }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            guard let button = statusItem.button else { return }
            viewModels.forEach { $0.run() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            startClickMonitor()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Click-to-dismiss

    private func startClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.popover.contentViewController?.view.window else {
                return event
            }
            if event.window == window {
                self.popover.performClose(nil)
                return nil  // consume the event
            }
            return event
        }
    }

    private func stopClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}
