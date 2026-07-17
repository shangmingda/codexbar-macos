import AppKit
import Combine
import SwiftUI

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let state = AppState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: 150)
    private let popover = NSPopover()
    private var popoverController: NSHostingController<DashboardView>?
    private let contentView = StatusItemContentView()
    private var observations: [NSKeyValueObservation] = []
    private var stateCancellables = Set<AnyCancellable>()
    private var previewWindow: NSWindow?
    private var previewStatusView: StatusItemContentView?
    private var previewController: NSViewController?
    private var statusUpdateScheduled = false
    private var previewMode: Bool { ProcessInfo.processInfo.arguments.contains("--preview") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if previewMode {
            NSApp.setActivationPolicy(.regular)
            showPreviewWindow()
            bindState()
            state.start()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configureStatusItem()
                self.configurePopover()
                self.bindState()
                self.state.start()
            }
        }
    }

    private func showPreviewWindow() {
        let controller = NSHostingController(rootView: DashboardView(state: state))
        controller.sizingOptions = []
        let root = NSView()
        let statusBackdrop = NSVisualEffectView()
        statusBackdrop.material = .headerView
        statusBackdrop.blendingMode = .withinWindow
        statusBackdrop.state = .active
        statusBackdrop.wantsLayer = true
        statusBackdrop.layer?.cornerRadius = 8
        let statusPreview = StatusItemContentView()
        statusPreview.lines = state.statusLines
        statusPreview.icon = CodexBarBrand.image(size: 17)
        statusBackdrop.addSubview(statusPreview)
        root.addSubview(statusBackdrop)
        root.addSubview(controller.view)
        statusBackdrop.translatesAutoresizingMaskIntoConstraints = false
        statusPreview.translatesAutoresizingMaskIntoConstraints = false
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusBackdrop.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            statusBackdrop.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            statusBackdrop.widthAnchor.constraint(equalToConstant: 190),
            statusBackdrop.heightAnchor.constraint(equalToConstant: 24),
            statusPreview.leadingAnchor.constraint(equalTo: statusBackdrop.leadingAnchor),
            statusPreview.trailingAnchor.constraint(equalTo: statusBackdrop.trailingAnchor),
            statusPreview.topAnchor.constraint(equalTo: statusBackdrop.topAnchor),
            statusPreview.bottomAnchor.constraint(equalTo: statusBackdrop.bottomAnchor),
            controller.view.topAnchor.constraint(equalTo: statusBackdrop.bottomAnchor, constant: 8),
            controller.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 370, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodexBar UI Test"
        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
        previewStatusView = statusPreview
        previewController = controller
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Codex 状态"
        contentView.frame = button.bounds
        contentView.autoresizingMask = [.width, .height]
        contentView.icon = CodexBarBrand.image(size: 17)
        button.addSubview(contentView)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 370, height: 560)
    }

    private func preparePopoverContent() {
        guard popoverController == nil else { return }
        let controller = NSHostingController(rootView: DashboardView(state: state))
        controller.sizingOptions = []
        popoverController = controller
        popover.contentViewController = controller
    }

    private func bindState() {
        state.objectWillChange.sink { [weak self] _ in
            self?.scheduleStatusItemUpdate()
        }
        .store(in: &stateCancellables)
        scheduleStatusItemUpdate()
    }

    private func scheduleStatusItemUpdate() {
        guard !statusUpdateScheduled else { return }
        statusUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusUpdateScheduled = false
            self.updateStatusItem()
        }
    }

    private func updateStatusItem() {
        let lines = state.statusLines
        if contentView.lines != lines { contentView.lines = lines }
        if previewStatusView?.lines != lines { previewStatusView?.lines = lines }
        let maxCharacters = lines.map(\.count).max() ?? 8
        let desiredLength = max(92, min(205, 31 + CGFloat(maxCharacters) * (lines.count > 1 ? 7 : 7.4)))
        if abs(statusItem.length - desiredLength) > 0.5 { statusItem.length = desiredLength }
        statusItem.button?.setAccessibilityLabel("Codex，\(lines.joined(separator: "，"))，进行中任务 \(state.tasks.count) 项")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.refreshTasks()
            preparePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        popoverController = nil
    }
}
