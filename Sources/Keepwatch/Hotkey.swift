import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut (⌃⌥⌘K) through Carbon's hot-key API, which needs no
/// Accessibility permission: macOS delivers only this key combination to us.
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ on: Bool) {
        on ? register() : unregister()
    }

    private func register() {
        guard ref == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in AppModel.shared.toggleFromHotkey() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4B575443), id: 1) // "KWTC"
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
