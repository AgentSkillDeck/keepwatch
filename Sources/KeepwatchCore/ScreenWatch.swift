import Foundation

/// Whether someone else may be seeing this screen. macOS's Screen Sharing
/// and Remote Management start `screensharingd` only while someone is
/// connected (or connecting), so its presence is the signal. Apps recording
/// with ScreenCaptureKit leave no public trace; macOS shows its own purple
/// indicator for those.
public enum ScreenWatch {
    public enum Watcher: String, Equatable, Sendable {
        case remoteViewer
        case capture

        public var text: String {
            switch self {
            case .remoteViewer: "Someone is connected with Screen Sharing and may see or control this Mac"
            case .capture: "A screenshot or screen recording is in progress"
            }
        }
    }

    public static func watchers(processNames: Set<String>) -> [Watcher] {
        var result: [Watcher] = []
        if processNames.contains("screensharingd") { result.append(.remoteViewer) }
        if processNames.contains("screencapture") { result.append(.capture) }
        return result
    }
}
