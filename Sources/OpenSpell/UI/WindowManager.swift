import AppKit
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, shortcut, models, test, about

    var title: String {
        switch self {
        case .general: "General"
        case .shortcut: "Shortcut"
        case .models: "Models"
        case .test: "Test"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcut: "command"
        case .models: "brain"
        case .test: "stethoscope"
        case .about: "hand.point.up.left"
        }
    }
}

/// Owns the app's few windows. Being a menu bar app, every `show…` also activates the app.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var settingsTabs: SettingsTabViewController?
    private var historyWindow: NSWindow?
    private var setupWindow: NSWindow?

    func showSettings(tab: SettingsTab) {
        if settingsWindow == nil { buildSettings() }
        settingsTabs?.selectedTabViewItemIndex = tab.rawValue
        settingsTabs?.fitWindowToSelectedTab() // before present() centers a newly opened window
        present(settingsWindow!)
    }

    func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(
                title: "History",
                content: HistoryView(),
                size: NSSize(width: 820, height: 520),
                style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            historyWindow?.setFrameAutosaveName("OpenSpellHistory")
        }
        present(historyWindow!)
    }

    func showSetupAssistant() {
        if setupWindow == nil {
            setupWindow = makeWindow(
                title: "Welcome to OpenSpell",
                content: SetupAssistantView(onFinish: { [weak self] in self?.setupWindow?.close() }),
                size: NSSize(width: 620, height: 560),
                style: [.titled, .closable, .fullSizeContentView])
            setupWindow?.titlebarAppearsTransparent = true
            setupWindow?.titleVisibility = .hidden
        }
        present(setupWindow!)
    }

    private func present(_ window: NSWindow) {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildSettings() {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []

        for tab in SettingsTab.allCases {
            let view: AnyView = switch tab {
            case .general: AnyView(GeneralSettingsView())
            case .shortcut: AnyView(ShortcutSettingsView())
            case .models: AnyView(ModelsSettingsView())
            case .test: AnyView(TestSettingsView())
            case .about: AnyView(AboutSettingsView())
            }
            let pane = SettingsPane(title: tab.title, rootView: view) { [weak tabs] in tabs?.setNeedsFit() }
            let item = NSTabViewItem(viewController: pane)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsTabs = tabs
        settingsWindow = window
    }

    private func makeWindow<V: View>(title: String, content: V, size: NSSize, style: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down; windows are reused.
    }

    /// Developer aid: renders every window to PNGs in `directory` (`OpenSpell --snapshot <dir>`).
    func snapshotAll(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save(_ window: NSWindow?, _ name: String) async {
            try? await Task.sleep(for: .milliseconds(900))
            guard let window, let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
        }
        for tab in SettingsTab.allCases {
            showSettings(tab: tab)
            await save(settingsWindow, "settings-\(tab.title.lowercased())")
        }
        settingsWindow?.close()
        showHistory()
        await save(historyWindow, "history")
        historyWindow?.close()
        showSetupAssistant()
        await save(setupWindow, "setup")
    }
}

/// Toolbar-style tabs whose window follows the selected page's size with a short animation that
/// keeps the top edge in place. (NSTabViewController alone only snaps the size after its transition.)
final class SettingsTabViewController: NSTabViewController {
    private var fitScheduled = false
    private var animationTarget: NSRect?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindowToSelectedTab()
    }

    /// Coalesces a page's size changes into one window resize.
    func setNeedsFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.fitScheduled = false
            self?.fitWindowToSelectedTab()
        }
    }

    func fitWindowToSelectedTab() {
        guard let window = view.window, let content = window.contentView,
              tabViewItems.indices.contains(selectedTabViewItemIndex),
              let pane = tabViewItems[selectedTabViewItemIndex].viewController as? SettingsPane else { return }
        let size = pane.contentSize
        var frame = window.frame
        frame.size.width += size.width - content.frame.width
        frame.size.height += size.height - content.frame.height
        frame.origin.y = window.frame.maxY - frame.height
        if let visible = window.screen?.visibleFrame { frame.origin.y = max(frame.origin.y, visible.minY) }

        guard window.isVisible else {
            animationTarget = nil
            if frame != window.frame { window.setFrame(frame, display: false) }
            return
        }
        guard frame != (animationTarget ?? window.frame) else { return }
        animationTarget = frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.animationTarget == frame { self?.animationTarget = nil }
            }
        })
    }
}

/// A settings page shown at its SwiftUI ideal size, pinned to the top, so it neither moves nor
/// re-lays out while the window animates around it.
final class SettingsPane: NSViewController {
    private let hostingView: SizeReportingHostingView

    init(title: String, rootView: AnyView, onSizeChange: @escaping () -> Void) {
        hostingView = SizeReportingHostingView(rootView: rootView)
        hostingView.onSizeChange = onSizeChange
        super.init(nibName: nil, bundle: nil)
        self.title = title  // propagated to the window title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var contentSize: NSSize {
        let size = hostingView.fittingSize
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    override func loadView() {
        let container = NSView()
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        view = container
    }
}

private final class SizeReportingHostingView: NSHostingView<AnyView> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}
