import CoreGraphics
import Foundation
import IOKit

/// "Stay active" (issue #5): chat and meeting apps mark you away after a few
/// minutes without input, whatever keeps the Mac awake. When you have been
/// idle for `idleMinutes`, Keepwatch moves the pointer one pixel and back. It
/// never clicks or types, needs Accessibility, and is off unless you turn it on.
public enum StayActive {
    public static let idleChoices: [Int] = [2, 4, 9]
    public static let defaultIdleMinutes = 4

    /// Whether to nudge now. Never during a lid session (a closed laptop
    /// shouldn't look active), never twice within one idle period.
    public static func shouldNudge(enabled: Bool, trusted: Bool, lidSession: Bool,
                                   idleSeconds: TimeInterval?, idleMinutes: Int) -> Bool {
        guard enabled, trusted, !lidSession, let idle = idleSeconds, idle.isFinite else { return false }
        let limit = TimeInterval(min(max(1, idleMinutes), 60) * 60)
        return idle >= limit
    }

    /// Seconds since the last keyboard, mouse or trackpad input; nil if unknown.
    public static func idleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return TimeInterval(value.uint64Value) / 1_000_000_000
    }

    /// Moves the pointer one pixel and back. Returns false if it couldn't.
    @discardableResult
    public static func nudge() -> Bool {
        guard let here = CGEvent(source: nil)?.location else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        let away = CGPoint(x: here.x + 1, y: here.y)
        guard let out = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: away, mouseButton: .left),
              let back = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: here, mouseButton: .left)
        else { return false }
        out.post(tap: .cghidEventTap)
        back.post(tap: .cghidEventTap)
        return true
    }
}
