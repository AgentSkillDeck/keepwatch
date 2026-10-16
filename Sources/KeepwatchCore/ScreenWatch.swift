import Foundation

/// Whether someone else may be seeing this screen. macOS's Screen Sharing
/// and Remote Management start `screensharingd` only while someone is
/// connected (or connecting), so its presence is the signal. Apps recording
/// with ScreenCaptureKit leave no public trace; macOS shows its own purple
/// indicator for those. Your own screenshots (`screencapture`) aren't
/// reported: you started them.
public enum ScreenWatch {
    public enum Watcher: String, Equatable, Sendable {
        case remoteViewer

        public var text: String {
            switch self {
            case .remoteViewer: "Someone is connected with Screen Sharing and may see or control this Mac"
            }
        }
    }

    public static func watchers(processNames: Set<String>) -> [Watcher] {
        var result: [Watcher] = []
        if processNames.contains("screensharingd") { result.append(.remoteViewer) }
        return result
    }
}
