import XCTest
@testable import KeepwatchCore

/// Read-only smoke tests against the real machine: they must not crash and
/// must return plausible values. They change nothing.
final class LiveReadTests: XCTestCase {
    func testPrivacySnapshotReads() {
        let s = PrivacyMonitor.snapshot()
        print("LIVE privacy:", s, "inputs:", PrivacyMonitor.audioInputDevices().count,
              "cameras:", PrivacyMonitor.cameraDevices().count, "canMute:", PrivacyMonitor.canMuteMic)
        if !s.micInUse { XCTAssertTrue(s.micUsers.isEmpty) }
    }

    func testPowerStateReads() {
        let p = SystemState.power()
        print("LIVE power:", p)
        if let pct = p.batteryPercent { XCTAssertTrue((0...100).contains(pct)) }
        if let h = p.healthPercent { XCTAssertTrue((1...100).contains(h)) }
    }

    func testPMSetReadMatchesParser() {
        let s = SystemState.pmsetSettings()
        print("LIVE pmset:", s as Any)
        XCTAssertNotNil(s)
    }

    func testQuickToggleReadsDoNotWrite() {
        for t in QuickToggle.allCases { print("LIVE toggle:", t.rawValue, t.read()) }
    }
}
