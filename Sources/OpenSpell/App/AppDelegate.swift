import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var shortcutMenuItem: NSMenuItem!
    private var modelMenuItem: NSMenuItem!
    private var cancellables = Set<AnyCancellable>()

    let settings = AppSettings.shared
    let windows = WindowManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        buildStatusItem()

        // Global keyboard shortcut.
        HotKeyCenter.shared.onTrigger = {
            if Diagnostics.shared.interceptShortcut() { return }
            CorrectionEngine.shared.trigger(source: .shortcut)
        }
        HotKeyCenter.shared.register(settings.hotKey)
        settings.$hotKey
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] combo in
                HotKeyCenter.shared.register(combo)
                self?.updateShortcutMenuTitle(combo)
            }
            .store(in: &cancellables)

        // Force-click trigger (needs Accessibility to install the event tap).
        ForceTouchMonitor.shared.onTrigger = {
            if Diagnostics.shared.interceptForceClick() { return }
            CorrectionEngine.shared.trigger(source: .forceClick)
        }
        ForceTouchMonitor.shared.start()

        ModelStore.shared.bootstrap()

        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { await windows.snapshotAll(to: dir); NSApp.terminate(nil) }
            return
        }

        // Developer aid: `OpenSpell --e2e <hf-repo>` runs the TextEdit end-to-end test and prints the result.
        if let i = CommandLine.arguments.firstIndex(of: "--e2e") {
            if i + 1 < CommandLine.arguments.count {
                ModelStore.shared.useForThisSessionOnly(localRepo: CommandLine.arguments[i + 1])
            }
            Task {
                await Diagnostics.shared.runChecks()
                for c in Diagnostics.shared.checks { print("[\(c.status)] \(c.title): \(c.detail)") }
                await Diagnostics.shared.runEndToEnd()
                print("E2E: \(Diagnostics.shared.e2e)")
                print("before: \(Diagnostics.shared.e2eOriginal ?? "-")")
                print("after:  \(Diagnostics.shared.e2eResult ?? "-")")
                NSApp.terminate(nil)
            }
            return
        }

        if !settings.hasCompletedSetup || !AccessibilityPermission.isTrusted {
            windows.showSetupAssistant()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showSettings(tab: .general)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ForceTouchMonitor.shared.stop()
    }

    // MARK: Main menu

    /// Menu bar apps have no visible main menu, but text fields still rely on its key
    /// equivalents for ⌘V / ⌘C / ⌘X / ⌘A / ⌘Z. Without this, pasting into fields doesn't work.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit OpenSpell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "OpenSpell")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(item("History…", #selector(openHistory), key: "h"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        modelMenuItem = item("", #selector(openModels))
        updateModelMenuTitle()
        menu.addItem(modelMenuItem)
        shortcutMenuItem = item("", #selector(openShortcut))
        updateShortcutMenuTitle(settings.hotKey)
        menu.addItem(shortcutMenuItem)
        menu.addItem(item("Test OpenSpell…", #selector(openTest)))
        menu.addItem(item("Setup Assistant…", #selector(openSetup)))
        menu.addItem(item("About OpenSpell", #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateShortcutMenuTitle(_ combo: KeyCombo?) {
        shortcutMenuItem?.title = "Keyboard shortcut: \(combo?.displayString ?? "None")…"
    }

    private func updateModelMenuTitle() {
        let store = ModelStore.shared
        let name = store.selected.map { store.isReady($0) ? $0.displayName : "\($0.displayName) (not ready)" }
        modelMenuItem?.title = "Language model: \(name ?? "None")…"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateModelMenuTitle()
    }

    @objc private func openHistory() { windows.showHistory() }
    @objc private func openSettings() { windows.showSettings(tab: .general) }
    @objc private func openModels() { windows.showSettings(tab: .models) }
    @objc private func openShortcut() { windows.showSettings(tab: .shortcut) }
    @objc private func openTest() { windows.showSettings(tab: .test) }
    @objc private func openSetup() { windows.showSetupAssistant() }
    @objc private func openAbout() { windows.showSettings(tab: .about) }
    @objc private func quit() { NSApp.terminate(nil) }
}
