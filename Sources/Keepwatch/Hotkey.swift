import AppKit
import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts through Carbon's hot-key API, which needs no
/// Accessibility permission: macOS delivers only these key combinations to us.
/// ⌃⌥⌘K turns keep-awake on or off; ⌃⌥⌘S opens Apple's screenshot toolbar.
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    static let awakeID: UInt32 = 1
    static let screenshotID: UInt32 = 2

    func setEnabled(_ on: Bool) {
        on ? register() : unregister()
    }

    private func register() {
        guard refs.isEmpty else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                Task { @MainActor in
                    if id == Hotkey.screenshotID { Screenshot.openToolbar() } else { AppModel.shared.toggleFromHotkey() }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        for (key, id) in [(kVK_ANSI_K, Self.awakeID), (kVK_ANSI_S, Self.screenshotID)] {
            var ref: EventHotKeyRef?
            let hid = EventHotKeyID(signature: OSType(0x4B575443), id: id) // "KWTC"
            if RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey | controlKey), hid,
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    private func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
    }
}

/// Apple's own Screenshot toolbar (the one behind ⇧⌘5): area, window or whole
/// screen, still or video, with Markup to edit afterwards. Opening it needs no
/// Screen Recording permission for Keepwatch, because Apple's app does the capture.
enum Screenshot {
    static func openToolbar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.screenshot.launcher") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
