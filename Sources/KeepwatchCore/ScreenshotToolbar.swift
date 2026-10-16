import CoreGraphics
import Foundation

/// Apple's Screenshot toolbar remembers where it was dragged
/// (`toolbarOrigin` in `com.apple.screencaptureui`). If that spot is partly off
/// every screen (dragged to the edge, or a display was unplugged), the toolbar
/// opens cut off. Keepwatch then forgets the spot, so macOS puts it back in
/// its default place; it never changes any other Screenshot setting.
public enum ScreenshotToolbar {
    public static let domain = "com.apple.screencaptureui"
    public static let key = "toolbarOrigin"
    /// Smaller than the real toolbar, so a well-placed one is never moved.
    static let minimumSize = CGSize(width: 400, height: 44)

    /// "{735, -12}" → (735, -12); nil if it isn't a point.
    public static func parse(_ text: String) -> CGPoint? {
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// True if a toolbar at `origin` (bottom-left, screen coordinates) would
    /// not fit inside any of `screens`.
    public static func isOffScreen(origin: CGPoint, screens: [CGRect]) -> Bool {
        let toolbar = CGRect(origin: origin, size: minimumSize)
        return !screens.contains { $0.contains(toolbar) }
    }

    /// Forgets the saved spot if it is off screen. Returns whether it did.
    @discardableResult
    public static func resetIfOffScreen(screens: [CGRect]) -> Bool {
        guard !screens.isEmpty,
              let saved = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String,
              let origin = parse(saved), isOffScreen(origin: origin, screens: screens) else { return false }
        CFPreferencesSetAppValue(key as CFString, nil, domain as CFString)
        return CFPreferencesAppSynchronize(domain as CFString)
    }
}
