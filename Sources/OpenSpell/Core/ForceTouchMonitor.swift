import AppKit
import Combine

/// Watches trackpad pressure system-wide and fires `onTrigger` when a press gets firm enough.
///
/// Two sources feed the same logic:
///  1. A CGEvent tap. At the CoreGraphics level, Force Touch pressure arrives inside *gesture*
///     events (type 29); AppKit only turns them into `.pressure` NSEvents later, inside each app.
///     The tap can also swallow the rest of the press so the app underneath doesn't react.
///  2. An `NSEvent` global monitor for `.pressure` as a fallback (detects, but can't swallow).
///
/// The threshold lives on the *stage‑1* pressure curve (0…1), so a correction usually fires
/// before macOS registers a real force click (Look Up / Quick Look).
@MainActor
final class ForceTouchMonitor: ObservableObject {
    static let shared = ForceTouchMonitor()

    var onTrigger: (() -> Void)?
    /// Set while the Settings "Test" pad or calibration is active.
    var isSuspended = false

    @Published private(set) var isRunning = false
    @Published private(set) var hasGlobalMonitor = false
    /// Live stage-1 pressure (0…1, 1 once a force click happened) for UI meters.
    @Published private(set) var livePressure: Double = 0

    // Diagnostics (shown in the Test tab).
    @Published private(set) var tapPressureEvents = 0
    @Published private(set) var monitorPressureEvents = 0
    @Published private(set) var peakPressure: Double = 0

    fileprivate var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var globalMonitors: [Any] = []

    fileprivate var triggeredThisPress = false

    private static let gestureType: UInt64 = 29    // NSEvent.EventType.gesture — carries Force Touch data
    private static let quickLookType: UInt64 = 33  // NSEvent.EventType.quickLook
    private static let pressureType: UInt64 = 34   // NSEvent.EventType.pressure (rare at CG level)

    func start() {
        installGlobalMonitor()
        guard tap == nil else { return }
        if !installTap() {
            // Usually means Accessibility isn't granted yet – keep retrying quietly.
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.installTap() {
                        self.retryTimer?.invalidate()
                        self.retryTimer = nil
                    }
                }
            }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isRunning = false
        globalMonitors.forEach(NSEvent.removeMonitor)
        globalMonitors.removeAll()
        hasGlobalMonitor = false
    }

    /// System Settings › Trackpad › "Force Click and haptic feedback". When off, macOS doesn't
    /// report deep presses at all, so force-click triggering can't work.
    /// Not `com.apple.trackpad.forceClick`: that's "Look up & data detectors › Force Click with one finger".
    nonisolated static var systemForceClickEnabled: Bool {
        let trackpad = UserDefaults.standard.persistentDomain(forName: "com.apple.AppleMultitouchTrackpad")
        return !((trackpad?["ForceSuppressed"] as? Bool) ?? false)
    }

    static func openTrackpadSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
    }

    func resetDiagnostics() {
        tapPressureEvents = 0
        monitorPressureEvents = 0
        peakPressure = 0
    }

    // MARK: Sources

    private func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << ForceTouchMonitor.gestureType) |
            (1 << ForceTouchMonitor.quickLookType) |
            (1 << ForceTouchMonitor.pressureType) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: forceTouchTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        isRunning = true
        return true
    }

    private func installGlobalMonitor() {
        guard globalMonitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .pressure, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.monitorPressureEvents += 1
                _ = self.process(stage: event.stage, pressure: Double(event.pressure))
            }
        }) {
            globalMonitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pressEnded() }
        }) {
            globalMonitors.append(m)
        }
        hasGlobalMonitor = !globalMonitors.isEmpty
    }

    // MARK: Logic

    /// Returns `true` when the event should be swallowed (tap only).
    fileprivate func handleTap(type rawType: UInt32, event: CGEvent) -> Bool {
        switch UInt64(rawType) {
        case UInt64(CGEventType.leftMouseDown.rawValue):
            triggeredThisPress = false
            return false

        case UInt64(CGEventType.leftMouseUp.rawValue):
            pressEnded()
            return false

        case ForceTouchMonitor.quickLookType:
            return triggeredThisPress

        case ForceTouchMonitor.gestureType, ForceTouchMonitor.pressureType:
            // Only look at the pressure flavour; other gesture events (scroll touches, etc.)
            // pass through untouched — unless we're mid-way through a press we already used.
            guard let ns = NSEvent(cgEvent: event), ns.type == .pressure else { return false }
            tapPressureEvents += 1
            return process(stage: ns.stage, pressure: Double(ns.pressure))

        default:
            return false
        }
    }

    private func pressEnded() {
        triggeredThisPress = false
        livePressure = 0
    }

    /// Shared by both sources. Returns `true` when the event should be swallowed.
    private func process(stage: Int, pressure: Double) -> Bool {
        let effective: Double = stage >= 2 ? 1.0 : (stage == 1 ? pressure : 0)
        livePressure = effective
        peakPressure = max(peakPressure, effective)
        if stage == 0 { triggeredThisPress = false }

        if triggeredThisPress { return true }

        let settings = AppSettings.shared
        guard settings.forceClickEnabled, !isSuspended, stage >= 1 else { return false }

        let threshold = ForceSensitivity.pressureThreshold(for: settings.forceSensitivity)
        guard effective >= threshold else { return false }

        triggeredThisPress = true
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        let handler = onTrigger
        DispatchQueue.main.async { handler?() }
        return true
    }
}

private let forceTouchTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ForceTouchMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return Unmanaged.passUnretained(event)
    }

    let swallow = MainActor.assumeIsolated { monitor.handleTap(type: type.rawValue, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
