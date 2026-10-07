import AppKit
import CodexBarCore
import Combine
import SwiftUI

@main
enum CodexBarMain {
    static func main() {
        if CommandLine.arguments.contains("--credential-access-status") {
            do {
                print("deepseekReadable=\(try DeepSeekCredentialStore().loadNonInteractively() != nil)")
                _ = try DingTalkWebhookStore().load()
                print("dingtalkReadable=true")
                exit(0)
            } catch { print("credentialAccessFailed=true"); exit(1) }
        }
        if CommandLine.arguments.contains("--delete-deepseek-credential") {
            do { try DeepSeekCredentialStore().delete(); exit(0) }
            catch { exit(1) }
        }
        CodexBarApp.main()
    }
}

struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let state = AppState(
        previewMode: ProcessInfo.processInfo.arguments.contains("--preview") || ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--render-previews=") })
    )
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
    private var terminationInFlight = false
    private var previewMode: Bool { ProcessInfo.processInfo.arguments.contains("--preview") || ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--render-previews=") }) }
    private var deepSeekPreviewMode: Bool { ProcessInfo.processInfo.arguments.contains("--preview-deepseek") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if previewMode {
            if let renderArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--render-previews=") }) {
                renderPreviews(at: String(renderArgument.dropFirst("--render-previews=".count)))
                return
            }
            if deepSeekPreviewMode { state.applyDeepSeekPreviewState() }
            NSApp.setActivationPolicy(.regular)
            showPreviewWindow()
            bindState()
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

    /// Deterministic visual QA without Keychain, provider changes, automation
    /// permissions, or the user's running app. These are real SwiftUI views.
    private func renderPreviews(at path: String) {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dashboard = NSHostingView(rootView: DashboardView(state: state))
        let support = NSHostingView(rootView: AuthorSupportView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 750, height: 600))
        content.addSubview(dashboard); content.addSubview(support)
        dashboard.frame = NSRect(x: 0, y: 0, width: 370, height: 560)
        support.frame = NSRect(x: 390, y: 0, width: 330, height: 500)
        window.contentView = content
        window.orderFront(nil)
        previewWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for (name, view) in [("dashboard", dashboard as NSView), ("support", support as NSView)] {
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: root.appendingPathComponent(name + ".png"))
                }
            }
            window.close()
            NSApp.terminate(nil)
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
        statusPreview.speed = state.networkSpeed
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
            statusBackdrop.widthAnchor.constraint(equalToConstant: 285),
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
        if contentView.speed != state.networkSpeed { contentView.speed = state.networkSpeed }
        if previewStatusView?.speed != state.networkSpeed { previewStatusView?.speed = state.networkSpeed }
        let desiredLength = contentView.preferredWidth
        if abs(statusItem.length - desiredLength) > 0.5 { statusItem.length = desiredLength }
        if let button = statusItem.button,
           abs(contentView.frame.width - desiredLength) > 0.5 {
            contentView.frame = NSRect(x: 0, y: 0, width: desiredLength, height: button.bounds.height)
            contentView.needsDisplay = true
        }
        statusItem.button?.setAccessibilityLabel("Codex，\(lines.joined(separator: "，"))，上传 \(NetworkSpeed.compact(state.networkSpeed.uploadBytesPerSecond))，下载 \(NetworkSpeed.compact(state.networkSpeed.downloadBytesPerSecond))，进行中任务 \(state.tasks.count) 项")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.refreshTasks()
            state.refreshQuota(force: true)
            preparePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        popoverController = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !previewMode else { return .terminateNow }
        guard state.needsProviderRollbackOnExit else { return .terminateNow }
        guard !terminationInFlight else { return .terminateLater }
        terminationInFlight = true
        Task { @MainActor in
            let safeToQuit = await state.prepareForTermination()
            terminationInFlight = false
            sender.reply(toApplicationShouldTerminate: safeToQuit)
            if !safeToQuit {
                preparePopoverContent()
                if let button = statusItem.button {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
            }
        }
        return .terminateLater
    }
}
