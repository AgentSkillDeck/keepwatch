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
            PrivacySwitches(compact: true)
            Divider()
            AwakeControls(showCustom: customOpen, compact: true)
            Divider()
            LidSessionCard(compact: true)
            Divider()
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
            Button { model.refreshNow() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh now")
            .keyboardShortcut("r")
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
        VStack(alignment: .leading, spacing: 10) {
            if compact { Eyebrow(text: "Privacy") }
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
                    Text(model.privacy.cameraInUse ? "In use" : "Not in use")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.privacy.cameraInUse {
                    // macOS has no camera off switch; cutting an app's camera
                    // permission is the real "stop", and it lives in Settings.
                    Button("Turn off…") { model.open(.camera) }
                        .controlSize(.small)
                        .help("Opens the Camera list in System Settings. Switch the app off there to stop it using the camera.")
                }
                Text(model.privacy.cameraInUse ? "LIVE" : "OFF")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(model.privacy.cameraInUse ? Brand.live : Color.secondary)
                    .background((model.privacy.cameraInUse ? Brand.live : Color.primary).opacity(0.12), in: Capsule())
            }
            .help("macOS has no switch that turns the camera off for every app. Keepwatch shows when it's on and can alert you.")
            SwitchRow(icon: "bell.badge", title: "Alert me",
                      subtitle: "When the mic or camera turns on", isOn: $model.alertOnMicCamera)
            if !compact {
                SwitchRow(icon: "laptopcomputer.and.arrow.down", title: "Mute mic when lid closes",
                          subtitle: "Unmutes when you open it", isOn: $model.muteMicWhenLidCloses)
            }
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
            return who.isEmpty ? "In use" : "In use by " + who.joined(separator: ", ")
        }
        return "Not in use"
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
            HStack {
                Eyebrow(text: "Keep awake")
                Spacer()
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
                IconBadge(icon: "terminal", tint: Brand.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text("While AI agents run").font(.system(size: 13, weight: .medium))
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
                .buttonStyle(TileButtonStyle(selected: isSelected(preset), height: 34))
                .help(preset == .forever ? "Until you turn it off" : "Stay awake for \(preset.label)")
            }
            Menu {
                ForEach(AwakePreset.allCases.filter { !model.menuPresets.contains($0) }) { preset in
                    Button(preset == .forever ? "Until I turn it off" : preset.label) { model.keepAwake(preset) }
                }
                Divider()
                Button("Custom time…") { withAnimation(.snappy) { showCustom = true } }
                Button("Turn off") { model.setMode(.off) }.disabled(model.mode == .off)
                Divider()
                Button("Choose these buttons…") {
                    MenuPanel.close()
                    model.showDashboard(tab: .settings)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 44, height: 34)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact {
                HStack {
                    Eyebrow(text: "Lid closed")
                    Spacer()
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
                    .help("Sleep should come back within 30 seconds. If it doesn't, this turns it on with your password.")
                } else {
                    Button { model.endLidSession(reason: "you ended it") } label: {
                        Label("End lid session", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Brand.live)
                }
            } else {
                HStack(spacing: 10) {
                    IconBadge(icon: "laptopcomputer", tint: Brand.teal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep working with the lid shut").font(.system(size: 13, weight: .medium))
                        Text("Then the Mac sleeps by itself. Needs your password once.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
                    if !compact { Spacer(minLength: 0) }
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
                    Text("Tip: turn on “Open Keepwatch at login”. If the Mac restarts mid-session, that lets Keepwatch turn sleep back on.")
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
