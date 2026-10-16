import KeepwatchCore
import SwiftUI

/// The popover under the menu-bar icon: status first, then one-click actions.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Opens with the custom-length panel showing (snapshots only).
    var customOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusHeader()
            if let banner = model.banner { BannerView(banner: banner) }
            if let away = model.awaySummary { AwaySummaryCard(summary: away) }
            ForEach(model.menuSections) { section in
                switch section {
                case .privacy: PrivacySwitches(compact: true)
                case .keepAwake: AwakeControls(showCustom: customOpen, compact: true)
                case .laptopClosed: LidSessionCard(compact: true)
                case .agents: MenuAgents()
                case .memory: MenuMemory()
                }
                Divider()
            }
            if model.menuSections.isEmpty { Divider() }
            HStack {
                Button {
                    MenuPanel.close()
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                }
                .keyboardShortcut(",")
                Spacer()
                Button {
                    MenuPanel.close()
                    // Let the menu fade first so it isn't in the picture.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Screenshot.openToolbar() }
                } label: { Label("Screenshot", systemImage: "camera.viewfinder") }
                    .help("Area, window, screen or video, with Markup to edit (⌃⌥⌘S)")
                Spacer()
                Button {
                    MenuPanel.close()
                    if let url = AppModel.websiteURL { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "globe") }
                    .help("Keepwatch website")
                Button { model.quit() } label: { Label("Quit", systemImage: "power") }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Up to four agent sessions, by name, for the menu.
struct MenuAgents: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuHeading("Agent sessions", info: "Claude Code, Codex, Gemini and other agents. Click ⊗ twice to stop one.")
            if model.agentSessions.isEmpty {
                Text("No agents running.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.agentSessions.prefix(4)) { s in
                HStack(spacing: 8) {
                    AgentBadge(name: s.agent, size: 18)
                    Text(model.sessionTitles[s.pid] ?? s.folder.map { ($0 as NSString).lastPathComponent } ?? s.agent)
                        .font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let started = s.started {
                        Text(Format.duration(Date().timeIntervalSince(started))).font(.caption).foregroundStyle(.secondary)
                    }
                    ConfirmButton(label: "Stop", help: "Stop this session (click twice)") { model.stopAgent(s) }
                }
            }
            if model.agentSessions.count > 4 {
                Text("and \(model.agentSessions.count - 4) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A small ⊗ that turns into a red "Stop?" on the first click and acts on
/// the second; it resets after a few seconds. Dialogs don't suit the menu panel.
struct ConfirmButton: View {
    var label: String
    var help: String
    var action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed { armed = false; action() } else {
                withAnimation(.snappy(duration: 0.15)) { armed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { armed = false } }
            }
        } label: {
            if armed {
                Text("\(label)?").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).frame(height: 18)
                    .foregroundStyle(.white).background(Capsule().fill(Brand.live))
            } else {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(armed ? "Confirm \(label.lowercased())" : label)
    }
}

/// The three apps using the most memory, for the menu.
struct MenuMemory: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuHeading("Using the most memory", info: "Top 3 by memory. Click ⊗ twice to quit one.")
            if model.topApps.isEmpty { Text("Reading memory use…").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.topApps.prefix(3)) { app in
                HStack(spacing: 8) {
                    AppIcon(path: app.path).frame(width: 18, height: 18)
                    Text(app.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: app.bytes), countStyle: .memory))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if app.isSystem {
                        Image(systemName: "applelogo").font(.caption2).foregroundStyle(.tertiary).frame(width: 22)
                            .help("Part of macOS; Keepwatch won't quit it")
                    } else {
                        ConfirmButton(label: "Quit", help: "Quit \(app.name) (click twice). It may ask you to save.") { model.quitApp(app) }
                    }
                }
            }
        }
        .onAppear { model.refreshTopApps() }
    }
}

/// The orb, a one-line status and the time left.
struct StatusHeader: View {
    @EnvironmentObject var model: AppModel
    var large = false

    var body: some View {
        HStack(spacing: 12) {
            StatusOrb(icon: orbIcon, active: model.holding || model.lidIntent.enabled, progress: progress,
                      size: large ? 64 : 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(large ? .title2 : .title3, design: .rounded).weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !large {
            Button { model.refreshNow() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh now")
            .keyboardShortcut("r")
            }
            if !large, let p = model.power, let pct = p.batteryPercent {
                HStack(spacing: 4) {
                    Image(systemName: p.onBattery ? batteryIcon(pct) : "powerplug.fill")
                    Text("\(pct)%").monospacedDigit()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
    }

    private var orbIcon: String {
        if model.lidIntent.enabled { return "laptopcomputer" }
        return model.holding ? "eye.fill" : "eye.slash"
    }

    private var progress: Double? {
        guard case .until = model.mode, let total = model.timedLength, total > 0, let left = model.remaining else { return nil }
        return min(1, max(0.02, left / total))
    }

    private var title: String {
        if model.lidIntent.enabled { return "Lid session on" }
        guard model.holding else {
            if case .whileAgentsRun = model.mode { return "Waiting for agents" }
            return "Sleeping normally"
        }
        switch model.mode {
        case .until: return "Awake · \(Format.duration(model.remaining ?? 0)) left"
        case .indefinite: return "Awake"
        case .whileAgentsRun: return "Awake for agents"
        case .off: return "Sleeping normally"
        }
    }

    private var subtitle: String {
        if model.lidIntent.enabled { return "Keeps working with the lid shut" }
        guard model.holding else {
            if case .whileAgentsRun = model.mode { return "Stays awake when an agent starts" }
            return "Your Mac sleeps as usual"
        }
        switch model.mode {
        case .until(let end):
            let time = end.formatted(date: .omitted, time: .shortened)
            if Calendar.current.isDateInToday(end) { return "Until \(time)" }
            if Calendar.current.isDateInTomorrow(end) { return "Until \(time) tomorrow" }
            return "Until " + end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        case .indefinite: return "Until you turn it off"
        case .whileAgentsRun: return "While " + model.agents.sessionSummary + " runs"
        case .off: return ""
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

struct BannerView: View {
    @EnvironmentObject var model: AppModel
    var banner: AppModel.Banner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(banner.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if banner.action == .restoreSleep { Button("Turn sleep back on") { model.restoreSleepNow() } }
                if banner.action == .openAccessibility { Button("Open Accessibility") { model.open(.accessibility) } }
                Button("Dismiss") { model.banner = nil }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// An icon, a title with a live status line, and an on/off switch.
struct SwitchRow: View {
    var icon: String
    var title: String
    var subtitle: String?
    var tint: Color = Brand.teal
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(BrandSwitchStyle())
                .disabled(disabled)
        }
        .contentShape(Rectangle())
    }
}

/// Mic and camera, each with its live state and a switch.
struct PrivacySwitches: View {
    @EnvironmentObject var model: AppModel
    var compact: Bool

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    /// The menu: mic and camera side by side, alerts as a small switch.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            MenuHeading("Privacy", info: "Red means live. Click a tile to mute or stop it.") {
                Button { model.alertOnMicCamera.toggle() } label: {
                    Label(model.alertOnMicCamera ? "Alerts on" : "Alerts off",
                          systemImage: model.alertOnMicCamera ? "bell.fill" : "bell.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.alertOnMicCamera ? Brand.teal : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Tell me when the mic or camera turns on")
            }
            HStack(spacing: 6) {
                PrivacyTile(icon: micIcon, title: "Mic", state: micShort, live: model.privacy.micInUse && model.privacy.micMuted != true,
                            action: model.privacy.micMuted == nil ? nil : { model.setMicMuted(!(model.privacy.micMuted ?? false)) })
                    .help(model.privacy.micMuted == true ? "All mics muted. Click to unmute." : "\(micStatus). Click to mute all mics.")
                PrivacyTile(icon: model.privacy.cameraInUse ? "video.fill" : "video.slash", title: "Camera",
                            state: model.privacy.cameraInUse ? "Live" : "Off", live: model.privacy.cameraInUse,
                            action: model.privacy.cameraInUse ? { model.open(.camera) } : nil)
                    .help(model.privacy.cameraInUse
                          ? "\(model.privacy.liveCameras.joined(separator: ", ")) live. Open the Camera list to switch the app off"
                          : "No app is using the camera")
                let shared = model.screenWatchers.contains(.remoteViewer)
                PrivacyTile(icon: shared ? "rectangle.on.rectangle" : "lock.display", title: "Screen",
                            state: shared ? "Shared" : "Private", live: shared,
                            action: shared ? { AppModel.openSharingSettings() } : nil)
                    .help(shared ? "Someone is connected with Screen Sharing. Click to open Sharing settings."
                                 : "No one is connected with Screen Sharing")
            }
        }
    }

    private var micShort: String {
        if model.privacy.micMuted == nil { return "No mic" }
        if model.privacy.micMuted == true { return "Muted" }
        return model.privacy.micInUse ? "Live" : "On, not in use"
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            SwitchRow(icon: micIcon, title: "Microphone", subtitle: micStatus,
                      tint: model.privacy.micInUse ? Brand.live : Brand.teal,
                      isOn: Binding(get: { model.privacy.micMuted == false },
                                    set: { model.setMicMuted(!$0) }),
                      disabled: model.privacy.micMuted == nil)
            HStack(spacing: 10) {
                IconBadge(icon: model.privacy.cameraInUse ? "video.fill" : "video.slash",
                          tint: model.privacy.cameraInUse ? Brand.live : Brand.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Camera").font(.system(size: 13, weight: .medium))
                    Text(model.privacy.cameraInUse
                         ? (model.privacy.liveCameras.isEmpty ? "In use" : "In use · " + model.privacy.liveCameras.joined(separator: ", "))
                         : "Not in use")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.privacy.cameraInUse {
                    // macOS has no camera off switch; cutting an app's camera
                    // permission is the real "stop", and it lives in Settings.
                    Button("Turn off…") { model.open(.camera) }
                        .controlSize(.small)
                        .help("Open the Camera list to switch the app off")
                }
                Text(model.privacy.cameraInUse ? "LIVE" : "OFF")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(model.privacy.cameraInUse ? Brand.live : Color.secondary)
                    .background((model.privacy.cameraInUse ? Brand.live : Color.primary).opacity(0.12), in: Capsule())
            }
            .help("macOS has no camera off switch for all apps")
            SwitchRow(icon: "bell.badge", title: "Alert me",
                      subtitle: "When the mic or camera turns on", isOn: $model.alertOnMicCamera)
            if !model.privacy.unmutableMics.isEmpty {
                Label("Can't be muted here: \(model.privacy.unmutableMics.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScreenWatchRows()
            SwitchRow(icon: "laptopcomputer.and.arrow.down", title: "Mute mic when lid closes",
                      subtitle: "Unmutes when you open it", isOn: $model.muteMicWhenLidCloses)
            SwitchRow(icon: "lock.fill", title: "Mute mic when the screen locks",
                      subtitle: "Unmutes when you unlock", isOn: $model.muteMicOnLock)
        }
    }

    private var micIcon: String {
        if model.privacy.micMuted == true { return "mic.slash.fill" }
        return model.privacy.micInUse ? "mic.fill" : "mic"
    }

    private var micStatus: String {
        if model.privacy.micMuted == nil { return "No mic found" }
        if model.privacy.micMuted == true { return "Muted" }
        if model.privacy.micInUse {
            let who = model.privacy.micUsers.map { model.appName(for: $0) }
            let on = model.privacy.liveMics.isEmpty ? "" : " · " + model.privacy.liveMics.joined(separator: ", ")
            return (who.isEmpty ? "In use" : "In use by " + who.joined(separator: ", ")) + on
        }
        return "Not in use"
    }
}

/// What happened while you were away, shown once when you come back.
struct AwaySummaryCard: View {
    @EnvironmentObject var model: AppModel
    let summary: AwayLog.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("While you were away · \(Format.duration(summary.duration))", systemImage: "figure.walk.arrival")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.awaySummary = nil } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
            }
            if summary.events.isEmpty {
                Text("Nothing happened.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(summary.events.suffix(5)) { e in
                HStack(spacing: 6) {
                    Image(systemName: e.icon).font(.caption).foregroundStyle(Brand.teal).frame(width: 14)
                    Text(e.text).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if summary.events.count > 5 {
                Text("and \(summary.events.count - 5) more").font(.caption2).foregroundStyle(.secondary)
            }
            if let used = summary.batteryUsed, let end = summary.batteryEnd {
                Label("Battery used \(used)% (now \(end)%)", systemImage: "battery.50percent")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.teal.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.teal.opacity(0.35)))
    }
}

/// Red rows when someone may be seeing the screen.
struct ScreenWatchRows: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ForEach(model.screenWatchers, id: \.self) { w in
            Button {
                AppModel.openSharingSettings()
            } label: {
                Label(w.text, systemImage: "rectangle.on.rectangle")
                    .font(.caption.weight(.semibold)).foregroundStyle(Brand.live)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .help("Open Sharing settings to turn Screen Sharing off")
        }
    }
}

/// A mic or camera tile for the menu: red when live, click to act.
struct PrivacyTile: View {
    var icon: String
    var title: String
    var state: String
    var live: Bool
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(live ? Brand.live : Brand.teal)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill((live ? Brand.live : Brand.teal).opacity(0.15)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(state).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(live ? Brand.live : Color.secondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(live ? Brand.live.opacity(0.10) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(live ? Brand.live.opacity(0.5) : Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // Not .disabled: that greys the tile out, and "off" isn't "unavailable".
        .allowsHitTesting(action != nil)
    }
}

/// The menu-bar panel. Closing it is how buttons that open something else
/// get it out of the way (SwiftUI has no API for this).
enum MenuPanel {
    static func close() {
        if let window = NSApp.keyWindow, window is NSPanel { window.close() }
    }
}

struct AwakeControls: View {
    @EnvironmentObject var model: AppModel
    @State var showCustom = false
    /// The menu shows a single row of the user's chosen lengths.
    var compact = false
    @State private var until = Date().addingTimeInterval(3_600)

    private static let presets: [(String, TimeInterval)] = [("1 h", 3_600), ("3 h", 10_800), ("8 h", 28_800), ("1 day", 86_400)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact {
            MenuHeading("Keep awake", info: "No sleep while the lid is open.") {
                if isTimedOrForever {
                    Button("Turn off") { model.setMode(.off) }
                        .buttonStyle(.borderless).font(.caption.weight(.semibold))
                }
            }
            }
            if compact { compactRow } else {
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.1) { label, seconds in
                    Button(label) { model.keepAwake(for: seconds) }
                        .buttonStyle(ChipButtonStyle(selected: isPreset(seconds)))
                }
                Button { model.setMode(.indefinite) } label: { Image(systemName: "infinity").font(.system(size: 13, weight: .bold)) }
                    .buttonStyle(ChipButtonStyle(selected: model.mode == .indefinite))
                    .help("Until you turn it off")
                Button { withAnimation(.snappy) { showCustom.toggle() } } label: { Label("Custom", systemImage: "slider.horizontal.3") }
                    .buttonStyle(ChipButtonStyle(selected: showCustom || isCustom))
                Spacer(minLength: 0)
                Button { model.setMode(.off) } label: { Label("Off", systemImage: "moon.zzz.fill") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .disabled(model.mode == .off)
                    .help("Stop keeping awake; the Mac sleeps normally")
            }
            }
            if showCustom { customPanel.transition(.opacity.combined(with: .move(edge: .top))) }
            HStack(spacing: 10) {
                if compact {
                    Image(systemName: "terminal").font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.teal)
                        .frame(width: 20)
                } else {
                    IconBadge(icon: "terminal", tint: Brand.teal)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("While AI agents run").font(.system(size: compact ? 12 : 13, weight: .medium))
                    Text(agentLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if !model.agents.isEmpty { AgentBadges(agents: model.agents, size: 18) }
                Toggle("While AI agents run",
                       isOn: Binding(get: { if case .whileAgentsRun = model.mode { true } else { false } },
                                     set: { model.setMode($0 ? .whileAgentsRun(grace: 120) : .off) }))
                    .labelsHidden()
                    .toggleStyle(BrandSwitchStyle())
            }
        }
    }

    /// The user's chosen lengths, then everything else in one menu.
    private var compactRow: some View {
        HStack(spacing: 6) {
            ForEach(model.menuPresets) { preset in
                Button { model.keepAwake(preset) } label: {
                    if preset == .forever {
                        Image(systemName: "infinity").font(.system(size: 14, weight: .bold))
                    } else {
                        Text(preset.label).font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                }
                .buttonStyle(TileButtonStyle(selected: isSelected(preset), height: 30))
                .help(preset == .forever ? "Until you turn it off" : "Stay awake for \(preset.label)")
            }
            Menu {
                ForEach(AwakePreset.allCases.filter { !model.menuPresets.contains($0) }) { preset in
                    Button(preset == .forever ? "Until I turn it off" : preset.label) { model.keepAwake(preset) }
                }
                Divider()
                Button("Custom time…") { withAnimation(.snappy) { showCustom = true } }
                Button("Turn off") { model.setMode(.off) }.disabled(model.mode == .off)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 40, height: 30)
            .background(Color.primary.opacity(showCustom || isCustom ? 0.14 : 0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help("More lengths, a custom time, or turn off")
        }
    }

    private func isSelected(_ preset: AwakePreset) -> Bool {
        guard let seconds = preset.seconds else { return model.mode == .indefinite }
        return isPreset(seconds)
    }

    private var isTimedOrForever: Bool {
        switch model.mode {
        case .until, .indefinite: true
        default: false
        }
    }

    private var customPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Amount", value: $model.customAmount, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .multilineTextAlignment(.center)
                Picker("Unit", selection: $model.customUnit) {
                    ForEach(AwakeDuration.Unit.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
            }
            HStack {
                Text(customSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Start") { model.keepAwakeCustom() }
                    .buttonStyle(.borderedProminent).tint(Brand.teal).controlSize(.small)
                    .disabled(AwakeDuration.seconds(model.customAmount, model.customUnit) == nil)
            }
            Divider()
            HStack {
                Text("Or until").font(.callout)
                DatePicker("Until", selection: $until, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .controlSize(.small)
                Spacer(minLength: 4)
                Button("Start") { model.keepAwake(until: until) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var customSummary: String {
        guard let s = AwakeDuration.seconds(model.customAmount, model.customUnit) else { return "Enter a number above 0" }
        let capped = s >= AwakeDuration.maxSeconds ? " (30-day limit; use ∞ for longer)" : ""
        return "Awake for \(AwakeDuration.describe(s))\(capped)"
    }

    private func isPreset(_ seconds: TimeInterval) -> Bool {
        guard let t = model.timedPreset else { return false }
        return abs(t - seconds) < 5
    }

    private var isCustom: Bool {
        guard model.timedPreset != nil else { return false }
        if compact { return !model.menuPresets.contains { isSelected($0) } }
        return !Self.presets.contains { isPreset($0.1) }
    }

    private var agentLine: String {
        if model.agents.isEmpty { return "None running now" }
        let n = model.agents.sessionCount
        return "\(n) session\(n == 1 ? "" : "s") running"
    }
}

/// Lid-closed session controls, shared by the menu and the dashboard.
struct LidSessionCard: View {
    @EnvironmentObject var model: AppModel
    var compact: Bool
    @State private var showLidCustom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact {
                MenuHeading("Laptop closed", info: "Runs with the lid shut, then sleeps by itself. Password to start.") {
                    if model.lidIntent.enabled, let end = model.lidIntent.expires {
                        Text("until \(end.formatted(date: .omitted, time: .shortened)) at most")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.lidIntent.enabled {
                HStack(spacing: 10) {
                    IconBadge(icon: "laptopcomputer", tint: Brand.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        if let end = model.lidIntent.expires {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text("\(Format.duration(max(0, end.timeIntervalSince(context.date)))) left at most")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                        }
                        Text(endsText).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Label("Temperature: \(model.thermalText). Hot ends the session.", systemImage: "thermometer.medium")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(model.thermalText == "Cool" || model.thermalText == "Warm" ? Color.secondary : Brand.live)
                        if let running = model.lidWatchdogRunning {
                            Label(running ? "Watchdog running" : "Watchdog stopped: sleep won't come back by itself",
                                  systemImage: running ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(running ? Brand.teal : Brand.live)
                        }
                    }
                }
                if model.lidEnding {
                    // The watchdog had its chance; this asks for the password instead.
                    Button { model.restoreSleepNow() } label: {
                        Label("Ending… turn sleep on now", systemImage: "moon.zzz.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Turns sleep on now (asks for your password)")
                } else {
                    Button { model.endLidSession(reason: "you ended it") } label: {
                        Label("End lid session", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Brand.live)
                }
            } else if compact {
                HStack(spacing: 6) {
                    ForEach([1.0, 3, 6, 12], id: \.self) { h in
                        Button { model.lidHours = h } label: {
                            Text(Format.hours(h)).font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(TileButtonStyle(selected: model.lidHours == h, height: 30))
                        .help("Sleep after \(Format.hours(h)) with the lid closed")
                    }
                    Button { model.startLidSession() } label: {
                        Label(model.lidBusy ? "…" : "Start", systemImage: "lock.open.laptopcomputer")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).frame(height: 30)
                            .foregroundStyle(Color.black.opacity(0.85))
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Brand.teal.opacity(model.lidBusy || !canStart ? 0.4 : 1)))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(model.lidBusy || !canStart)
                    .help(model.lidBusy ? "Waiting for your password" : "Start a lid session; asks for your password once")
                }
                if let why = blockedReason {
                    Label(why, systemImage: "powerplug").font(.caption).foregroundStyle(.orange)
                }
            } else {
                HStack(spacing: 6) {
                    Text("Sleep after").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach([1.0, 3, 6, 12], id: \.self) { h in
                        if compact {
                            Button { model.lidHours = h } label: {
                                Text(Format.hours(h)).font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .buttonStyle(TileButtonStyle(selected: model.lidHours == h, height: 28))
                        } else {
                            Button(Format.hours(h)) { model.lidHours = h }
                                .buttonStyle(ChipButtonStyle(selected: model.lidHours == h))
                        }
                    }
                    if !compact {
                        Button { withAnimation(.snappy) { showLidCustom.toggle() } } label: { Label("Custom", systemImage: "slider.horizontal.3") }
                            .buttonStyle(ChipButtonStyle(selected: showLidCustom || ![1.0, 3, 6, 12].contains(model.lidHours)))
                        Spacer(minLength: 0)
                    }
                }
                if !compact && (showLidCustom || ![1.0, 3, 6, 12].contains(model.lidHours)) {
                    Stepper(value: $model.lidHours, in: 0.25...12, step: 0.25) {
                        Text("Sleep after \(Format.duration(model.lidHours * 3600)) with the lid closed")
                            .font(.callout).monospacedDigit()
                    }
                    .padding(.leading, 2)
                }
                if !compact {
                    SwitchRow(icon: "alarm", title: "Also sleep at a set time",
                              subtitle: model.lidSleepAtEnabled ? nil : "Like 1:00 at night", isOn: $model.lidSleepAtEnabled)
                    if model.lidSleepAtEnabled {
                        DatePicker("Sleep at", selection: $model.lidSleepAt, displayedComponents: [.date, .hourAndMinute])
                            .padding(.leading, 38)
                    }
                    SwitchRow(icon: "battery.50percent", title: "Allow on battery", subtitle: "Needs more than 20%. Stops at 20%.",
                              isOn: $model.lidAllowBattery)
                    SwitchRow(icon: "flag.checkered", title: "Stop when agents are done",
                              subtitle: "Then the Mac sleeps", isOn: $model.endLidSessionWhenAgentsFinish)
                }
                if !compact && !model.launchAtLogin {
                    Text("Tip: turn on “Open Keepwatch at login” in case the Mac restarts.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { model.startLidSession() } label: {
                    Label(model.lidBusy ? "Waiting for password…" : "Start lid session", systemImage: "lock.open.laptopcomputer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Brand.teal)
                .disabled(model.lidBusy || !canStart)
                if let why = blockedReason {
                    Label(why, systemImage: "powerplug").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var canStart: Bool { blockedReason == nil }

    /// Why a lid session can't start right now, in plain words.
    private var blockedReason: String? {
        guard let p = model.power, p.onBattery else { return nil }
        if !model.lidAllowBattery {
            return compact ? "Plug in, or allow battery in the dashboard." : "Plug in, or turn on “Allow on battery”."
        }
        if let pct = p.batteryPercent, pct <= 20 { return "Battery is at \(pct)%. Plug in to start." }
        return nil
    }

    private var endsText: String {
        var parts: [String] = []
        if model.lidHours > 0 { parts.append("sleeps \(Format.hours(model.lidHours)) after the lid closes") }
        if model.endLidSessionWhenAgentsFinish { parts.append("or when agents finish") }
        parts.append(model.lidAllowBattery ? "or at 20% battery" : "or if unplugged")
        return "Running: " + parts.joined(separator: ", ") + "."
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String { AwakeDuration.describe(seconds) }

    static func hours(_ h: Double) -> String {
        h == h.rounded() ? "\(Int(h)) h" : String(format: "%.1f h", h)
    }
}
