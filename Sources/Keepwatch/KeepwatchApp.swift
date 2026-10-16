import KeepwatchCore
import SwiftUI
import UserNotifications

@main
struct KeepwatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(holding: model.holding, lidSession: model.lidIntent.enabled,
                         mic: model.privacy.micInUse, camera: model.privacy.cameraInUse, timer: model.quickTimerLabel)
                .background(WindowOpenerBridge(model: model))
        }
        .menuBarExtraStyle(.window)

        Window("Keepwatch", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar icon: an eye that opens when Keepwatch is holding the Mac
/// awake, plus a red mic and/or camera badge while either is live.
struct MenuBarLabel: View {
    var holding: Bool
    var lidSession: Bool
    var mic: Bool
    var camera: Bool
    var timer: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: lidSession ? "laptopcomputer" : (holding ? "eye.fill" : "eye"))
            if let timer { Text(timer).monospacedDigit() }
            if let badge = PrivacyBadge.image(mic: mic, camera: camera) { Image(nsImage: badge) }
        }
        .accessibilityLabel(accessibilityText)
    }

    var accessibilityText: String {
        var parts = [lidSession ? "Lid session on" : (holding ? "Keeping awake" : "Keepwatch")]
        if mic { parts.append("microphone in use") }
        if camera { parts.append("camera in use") }
        return parts.joined(separator: ", ")
    }
}

/// A red pill with white mic and camera glyphs. It is not a template image,
/// so the menu bar keeps its colour, like the system's own privacy dot.
enum PrivacyBadge {
    static let red = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)

    static func image(mic: Bool, camera: Bool) -> NSImage? {
        let names = (mic ? ["mic.fill"] : []) + (camera ? ["video.fill"] : [])
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let glyphs = names.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        guard !glyphs.isEmpty else { return nil }
        let pad: CGFloat = 5, gap: CGFloat = 3, height: CGFloat = 16
        let width = glyphs.reduce(pad * 2) { $0 + $1.size.width } + gap * CGFloat(glyphs.count - 1)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            red.setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            var x = pad
            for glyph in glyphs {
                let size = glyph.size
                glyph.draw(in: NSRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height))
                x += size.width + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Hands SwiftUI's openWindow action to the model so URL commands can open
/// the dashboard.
struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { model.openDashboardAction = { openWindow(id: "dashboard") } }
    }
}

/// Handles `keepwatch://` URLs and the `--render-snapshots DIR [--demo]` launch flags.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let open = UNNotificationAction(identifier: AppModel.openCameraAction, title: "Open Camera list", options: [.foreground])
            center.setNotificationCategories([UNNotificationCategory(identifier: AppModel.cameraCategory, actions: [open],
                                                                     intentIdentifiers: [])])
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-snapshots"), args.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            Task { @MainActor in
                Snapshots.render(model: AppModel.shared, to: dir, demo: args.contains("--demo"))
                NSApp.terminate(nil)
            }
        }
    }

    /// Show alerts even while Keepwatch's own window is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking an alert: camera opens the Camera list, an agent alert brings its
    /// terminal forward, a Screen Sharing alert opens Sharing settings.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        switch content.categoryIdentifier {
        case AppModel.cameraCategory:
            Task { @MainActor in AppModel.shared.open(.camera) }
        case AppModel.agentCategory:
            // Bring forward the terminal the waiting agent runs in.
            if let pid = content.userInfo["hostPID"] as? Int, let pid32 = Int32(exactly: pid), pid32 > 0 {
                Task { @MainActor in _ = NSRunningApplication(processIdentifier: pid32)?.activate() }
            }
        case AppModel.startupCategory:
            Task { @MainActor in AppModel.shared.showDashboard(tab: .security) }
        case AppModel.screenCategory:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
        default: break
        }
        completionHandler()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { if let command = URLCommand.parse(url) { AppModel.shared.perform(command) } }
        }
    }
}

/// Renders the menu and dashboard to PNGs for visual review, without needing
/// Screen Recording permission.
@MainActor
enum Snapshots {
    /// With `demo`, every view shows `DemoData` instead of this Mac's own
    /// apps, folders and ports, for pictures that are safe to publish.
    static func render(model: AppModel, to dir: URL, demo: Bool = false) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if demo { model.loadDemoData() } else { model.refreshSecurityNow() }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            write(MenuView().environmentObject(model), dir.appendingPathComponent("menu-\(suffix).png"), scheme)
            write(DashboardView(initialTab: .awake).environmentObject(model), dir.appendingPathComponent("dashboard-\(suffix).png"), scheme)
        }
        if demo {
            write(MenuView(customOpen: true).environmentObject(model), dir.appendingPathComponent("menu-awake-dark.png"), .dark)
        } else {
            // The menu while a timed session runs, then put the user's own mode back.
            let saved = model.mode
            model.keepAwake(for: 3 * 3_600)
            model.tick()
            write(MenuView(customOpen: true).environmentObject(model), dir.appendingPathComponent("menu-awake-dark.png"), .dark)
            model.setMode(saved)
            model.refreshPorts()
            model.refreshTopAppsNow()
        }
        let tiles = model.summaryTiles
        model.summaryTiles = SummaryTile.allCases
        write(DashboardView(initialTab: .awake).environmentObject(model), dir.appendingPathComponent("dashboard-all-tiles-dark.png"), .dark)
        model.summaryTiles = tiles
        write(MenuBarLabel(holding: true, lidSession: false, mic: true, camera: true).padding(6),
              dir.appendingPathComponent("menubar-live-dark.png"), .dark)
        for tab in [DashboardTab.agents, .lid, .privacy, .security, .ports, .power, .settings] {
            write(DashboardView(initialTab: tab).environmentObject(model), dir.appendingPathComponent("tab-\(tab.rawValue)-dark.png"), .dark)
        }
        // Sub-tabs added in 0.3, then the user's own choice put back.
        let d = UserDefaults.standard
        for (key, value, tab, name) in [("appsSub", "Storage", DashboardTab.ports, "storage"),
                                        ("securitySub", "Startup items", DashboardTab.security, "startup")] {
            let saved = d.string(forKey: key)
            d.set(value, forKey: key)
            write(DashboardView(initialTab: tab).environmentObject(model), dir.appendingPathComponent("tab-\(name)-dark.png"), .dark)
            d.set(saved, forKey: key)
        }
    }

    /// Hosts the view in an offscreen window and caches its display, so
    /// native controls and scroll views draw exactly as on screen. Capturing
    /// our own window needs no Screen Recording permission.
    private static func write<V: View>(_ view: V, _ url: URL, _ scheme: ColorScheme) {
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = scheme == .dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }
}
