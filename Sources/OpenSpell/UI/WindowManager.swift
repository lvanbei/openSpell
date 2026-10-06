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
    private var settingsTabs: NSTabViewController?
    private var historyWindow: NSWindow?
    private var setupWindow: NSWindow?

    func showSettings(tab: SettingsTab) {
        if settingsWindow == nil { buildSettings() }
        settingsTabs?.selectedTabViewItemIndex = tab.rawValue
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
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]

        for tab in SettingsTab.allCases {
            let view: AnyView = switch tab {
            case .general: AnyView(GeneralSettingsView())
            case .shortcut: AnyView(ShortcutSettingsView())
            case .models: AnyView(ModelsSettingsView())
            case .test: AnyView(TestSettingsView())
            case .about: AnyView(AboutSettingsView())
            }
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = [.preferredContentSize]
            controller.title = tab.title  // propagated to the window title
            let item = NSTabViewItem(viewController: controller)
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
