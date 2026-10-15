import Foundation
import IOKit.pwr_mgt

/// The kinds of sleep Keepwatch can hold off with a power assertion.
/// None of these keep the Mac awake with the lid closed; that needs `LidMode`.
public enum AssertionKind: String, CaseIterable, Sendable {
    /// Stop the system idle-sleeping; the display may still sleep.
    case system = "PreventUserIdleSystemSleep"
    /// Stop the display idle-sleeping (implies the system stays awake).
    case display = "PreventUserIdleDisplaySleep"
}

/// One held IOPMAssertion. Released on `release()` or deinit, so a dropped
/// value can never leak an assertion for the lifetime of the process.
public final class PowerAssertion {
    public let kind: AssertionKind
    public let name: String
    private var id: IOPMAssertionID = 0
    public private(set) var isHeld = false

    public init(kind: AssertionKind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// Takes the assertion. Returns false if IOKit refused it.
    @discardableResult
    public func hold() -> Bool {
        if isHeld { return true }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kind.rawValue as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else { return false }
        id = newID
        isHeld = true
        return true
    }

    public func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        isHeld = false
        id = 0
    }

    deinit { release() }
}
