import AppKit
import ApplicationServices

enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (only does something the first time).
    static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// Everything we know about the selection at the moment a correction starts.
struct SelectionSnapshot {
    let text: String
    let app: NSRunningApplication?
    let element: AXUIElement?
    /// Selected range inside the focused element, when the app exposes it.
    let range: CFRange?
    /// Screen rect (Cocoa coordinates, bottom-left origin) of the selection, if known.
    let screenRect: CGRect?
    /// `true` when the text was obtained through the Accessibility API (vs. ⌘C).
    let viaAccessibility: Bool
    /// Set when the selection lives in one of OpenSpell's own windows (Setup Assistant "Try it").
    var ownTextView: NSTextView? = nil
    var ownRange: NSRange? = nil
}

enum WriteBackResult {
    case replaced
    case copiedToClipboard(reason: String)
}

/// Reads the current selection in the frontmost app and writes text back in place.
@MainActor
enum TextAccess {

    // MARK: Read

    static func captureSelection() async -> SelectionSnapshot? {
        let app = NSWorkspace.shared.frontmostApplication

        // Our own windows: talk to the text view directly (AX into our own process would block).
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
            let range = tv.selectedRange()
            guard range.length > 0, let text = (tv.string as NSString?)?.substring(with: range) else { return nil }
            var rect = tv.firstRect(forCharacterRange: range, actualRange: nil)
            if rect.isEmpty { rect = tv.window?.frame ?? .zero }
            return SelectionSnapshot(text: text, app: app, element: nil, range: nil, screenRect: rect,
                                     viaAccessibility: false, ownTextView: tv, ownRange: range)
        }

        if let app { enableEnhancedAccessibility(for: app) }

        let element = focusedElement()
        if let element, let text = stringAttribute(element, kAXSelectedTextAttribute), !text.isEmpty {
            let range = selectedRange(of: element)
            let rect = range.flatMap { boundsForRange($0, in: element) } ?? frameOf(element)
            return SelectionSnapshot(text: text, app: app, element: element, range: range,
                                     screenRect: rect, viaAccessibility: true)
        }

        // Fallback for apps without AX text support: synthesize ⌘C.
        await waitForModifierRelease()
        guard let copied = await copySelectionViaPasteboard(), !copied.isEmpty else { return nil }
        return SelectionSnapshot(text: copied, app: app, element: element, range: nil,
                                 screenRect: element.flatMap(frameOf), viaAccessibility: false)
    }

    // MARK: Write

    static func writeBack(_ corrected: String, over snapshot: SelectionSnapshot) async -> WriteBackResult {
        if let tv = snapshot.ownTextView, let range = snapshot.ownRange {
            let ns = tv.string as NSString
            guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == snapshot.text else {
                copyToClipboard(corrected)
                return .copiedToClipboard(reason: "The text changed")
            }
            if tv.shouldChangeText(in: range, replacementString: corrected) {
                tv.replaceCharacters(in: range, with: corrected)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location, length: (corrected as NSString).length))
            }
            return .replaced
        }

        // Don't type into a different app than the one we read from.
        if let app = snapshot.app, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            copyToClipboard(corrected)
            return .copiedToClipboard(reason: "You switched apps")
        }

        await waitForModifierRelease()
        await waitForMouseRelease()
        await restoreSelection(snapshot)

        // Paste is the most reliable universal path (and gives the app a proper undo step).
        await paste(corrected)
        return .replaced
    }

    /// Re-selects the original range if it was lost (e.g. a force click put the caret down).
    private static func restoreSelection(_ snapshot: SelectionSnapshot) async {
        guard let element = snapshot.element, snapshot.viaAccessibility, var range = snapshot.range,
              stringAttribute(element, kAXSelectedTextAttribute) != snapshot.text,
              let value = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: AX helpers

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
        return range
    }

    private static func boundsForRange(_ range: CFRange, in element: AXUIElement) -> CGRect? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return flipToCocoa(rect)
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return flipToCocoa(CGRect(origin: point, size: size))
    }

    /// AX uses a top-left origin on the primary screen; AppKit uses bottom-left.
    private static func flipToCocoa(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Chromium / Electron only build their AX tree when asked to.
    private static func enableEnhancedAccessibility(for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: Keyboard / pasteboard helpers

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    /// Sends ⌘C and returns the copied string, restoring the previous clipboard afterwards.
    private static func copySelectionViaPasteboard() async -> String? {
        let pb = NSPasteboard.general
        let saved = savePasteboard()
        let before = pb.changeCount

        postKey(code: 8 /* kVK_ANSI_C */, flags: .maskCommand)

        var result: String?
        for _ in 0..<25 {  // up to ~500 ms
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != before {
                result = pb.string(forType: .string)
                break
            }
        }
        restorePasteboard(saved)
        return result
    }

    private static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = savePasteboard()

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Ask clipboard managers to ignore this temporary entry.
        item.setString("", forType: transientType)
        item.setString("", forType: autoGeneratedType)
        pb.writeObjects([item])

        postKey(code: 9 /* kVK_ANSI_V */, flags: .maskCommand)

        // Give the target app time to read the pasteboard before restoring it.
        try? await Task.sleep(for: .milliseconds(450))
        restorePasteboard(saved)
    }

    private static func postKey(code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func savePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private static func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    /// Wait (max ~1.5 s) until the user lets go of ⌘⇧⌥⌃ so synthetic keystrokes aren't altered.
    private static func waitForModifierRelease() async {
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        for _ in 0..<75 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(relevant).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Wait (max ~3 s) until the trackpad is released after a force click.
    private static func waitForMouseRelease() async {
        for _ in 0..<150 {
            if !CGEventSource.buttonState(.combinedSessionState, button: .left) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
