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
            AwakeControls(showCustom: customOpen)
            Divider()
            LidSessionCard(compact: true)
            Divider()
            HStack {
                Button {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                }
                .keyboardShortcut(",")
                Spacer()
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
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
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
        if model.lidIntent.enabled { return "Runs with the lid closed, then sleeps by itself" }
        guard model.holding else {
            if case .whileAgentsRun = model.mode { return "Stays awake as soon as an agent starts" }
            return "Your Mac sleeps on its usual schedule"
        }
        switch model.mode {
        case .until(let end):
            let time = end.formatted(date: .omitted, time: .shortened)
            if Calendar.current.isDateInToday(end) { return "Until \(time)" }
            if Calendar.current.isDateInTomorrow(end) { return "Until \(time) tomorrow" }
            return "Until " + end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        case .indefinite: return "Until you turn it off"
        case .whileAgentsRun: return "While " + model.agents.keys.sorted().joined(separator: ", ") + " runs"
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
                    Text(model.privacy.cameraInUse ? "An app is using it now" : "Off: no app is using it")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(model.privacy.cameraInUse ? "LIVE" : "OFF")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(model.privacy.cameraInUse ? Brand.live : Color.secondary)
                    .background((model.privacy.cameraInUse ? Brand.live : Color.primary).opacity(0.12), in: Capsule())
            }
            .help("macOS has no switch that turns the camera off for every app. Keepwatch shows when it's on and can alert you.")
            SwitchRow(icon: "bell.badge", title: "Alert when mic or camera turns on",
                      subtitle: "A notification names the app using the mic", isOn: $model.alertOnMicCamera)
            if !compact {
                SwitchRow(icon: "laptopcomputer.and.arrow.down", title: "Mute the mic when the lid closes",
                          subtitle: "Unmutes again when you open it", isOn: $model.muteMicWhenLidCloses)
            }
        }
    }

    private var micIcon: String {
        if model.privacy.micMuted == true { return "mic.slash.fill" }
        return model.privacy.micInUse ? "mic.fill" : "mic"
    }

    private var micStatus: String {
        if model.privacy.micMuted == nil { return "No input device" }
        if model.privacy.micMuted == true { return "Muted for every app" }
        if model.privacy.micInUse {
            let who = model.privacy.micUsers.map { model.appName(for: $0) }
            return who.isEmpty ? "Live now" : "Live: " + who.joined(separator: ", ")
        }
        return "On, not in use"
    }
}

struct AwakeControls: View {
    @EnvironmentObject var model: AppModel
    @State var showCustom = false
    @State private var until = Date().addingTimeInterval(3_600)

    private static let presets: [(String, TimeInterval)] = [("1 h", 3_600), ("3 h", 10_800), ("8 h", 28_800), ("1 day", 86_400)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Keep awake")
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    ForEach(Self.presets, id: \.1) { label, seconds in
                        Button { model.keepAwake(for: seconds) } label: {
                            Text(label).font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(TileButtonStyle(selected: isPreset(seconds)))
                    }
                }
                GridRow {
                    Button { model.setMode(.indefinite) } label: {
                        Image(systemName: "infinity").font(.system(size: 15, weight: .bold))
                    }
                    .buttonStyle(TileButtonStyle(selected: model.mode == .indefinite))
                    .help("Until you turn it off")
                    Button { withAnimation(.snappy) { showCustom.toggle() } } label: {
                        Label("Custom", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(TileButtonStyle(selected: showCustom || isCustom))
                    .gridCellColumns(2)
                    Button { model.setMode(.off) } label: {
                        Label("Off", systemImage: "moon.zzz.fill").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(TileButtonStyle(selected: false))
                    .disabled(model.mode == .off)
                    .help("Stop keeping awake; the Mac sleeps normally")
                }
            }
            if showCustom { customPanel.transition(.opacity.combined(with: .move(edge: .top))) }
            SwitchRow(icon: "terminal", title: "While AI agents run", subtitle: agentLine,
                      isOn: Binding(get: { if case .whileAgentsRun = model.mode { true } else { false } },
                                    set: { model.setMode($0 ? .whileAgentsRun(grace: 120) : .off) }))
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
        return !Self.presets.contains { isPreset($0.1) }
    }

    private var agentLine: String {
        if model.agents.isEmpty { return "Claude Code, Codex, Gemini CLI… none running" }
        return "Running: " + model.agents.keys.sorted().joined(separator: ", ")
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
                    Text(endsText).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { model.endLidSession(reason: "you ended it") } label: {
                    Label("End lid session", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            } else {
                HStack(spacing: 10) {
                    IconBadge(icon: "laptopcomputer", tint: Brand.teal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.lidHours > 0 ? "Sleep \(Format.hours(model.lidHours)) after the lid closes" : "No lid-closed limit")
                            .font(.system(size: 13, weight: .medium))
                        Text("Agents keep running with the lid shut. Asks for your password once.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Stepper("Hours", value: $model.lidHours, in: 0...12, step: 0.5).labelsHidden()
                }
                if !compact {
                    SwitchRow(icon: "alarm", title: "Also sleep at a set time",
                              subtitle: model.lidSleepAtEnabled ? nil : "For example 1:00 at night", isOn: $model.lidSleepAtEnabled)
                    if model.lidSleepAtEnabled {
                        DatePicker("Sleep at", selection: $model.lidSleepAt, displayedComponents: [.date, .hourAndMinute])
                            .padding(.leading, 38)
                    }
                    SwitchRow(icon: "battery.50percent", title: "Allow on battery", subtitle: "Stops at 20%",
                              isOn: $model.lidAllowBattery)
                    SwitchRow(icon: "flag.checkered", title: "End when all agents finish",
                              subtitle: "Then the Mac sleeps right away", isOn: $model.endLidSessionWhenAgentsFinish)
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
                if !canStart {
                    Label(compact ? "Plug in power first, or allow battery in the dashboard."
                                  : "Plug in power first, or turn on “Allow on battery” above.",
                          systemImage: "powerplug")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var canStart: Bool { model.lidAllowBattery || !(model.power?.onBattery ?? false) }

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
