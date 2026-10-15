import KeepwatchCore
import SwiftUI

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
                         mic: model.privacy.micInUse, camera: model.privacy.cameraInUse)
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
/// awake, plus a mic and/or camera glyph while either is live.
struct MenuBarLabel: View {
    var holding: Bool
    var lidSession: Bool
    var mic: Bool
    var camera: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: lidSession ? "laptopcomputer" : (holding ? "eye.fill" : "eye"))
            if mic { Image(systemName: "mic.fill") }
            if camera { Image(systemName: "video.fill") }
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

/// Handles `keepwatch://` URLs and the `--render-snapshots DIR` launch flag.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-snapshots"), args.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            Task { @MainActor in
                Snapshots.render(model: AppModel.shared, to: dir)
                NSApp.terminate(nil)
            }
        }
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
    static func render(model: AppModel, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.refreshSecurityNow()
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            write(MenuView().environmentObject(model), dir.appendingPathComponent("menu-\(suffix).png"), scheme)
            write(DashboardView().environmentObject(model), dir.appendingPathComponent("dashboard-\(suffix).png"), scheme)
        }
        // The menu while a timed session runs, then put the user's own mode back.
        let saved = model.mode
        model.keepAwake(for: 3 * 3_600)
        model.tick()
        write(MenuView(customOpen: true).environmentObject(model), dir.appendingPathComponent("menu-awake-dark.png"), .dark)
        model.setMode(saved)
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
