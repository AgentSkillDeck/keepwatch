import KeepwatchCore
import SwiftUI

/// The popover under the menu-bar icon: status first, then one-click actions.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let banner = model.banner { BannerView(banner: banner) }
            PrivacyStrip()
            Divider()
            AwakeControls()
            Divider()
            LidSessionCard(compact: true)
            Divider()
            HStack {
                Button("Dashboard…") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit") { model.quit() }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keepwatch").font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = model.power, let pct = p.batteryPercent {
                Label("\(pct)%", systemImage: p.onBattery ? "battery.75percent" : "powerplug")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: String {
        if model.lidIntent.enabled { return "Lid session on: runs with the lid closed" }
        guard model.holding else {
            if case .whileAgentsRun = model.mode { return "Waiting for an agent to start" }
            return "Your Mac sleeps normally"
        }
        switch model.mode {
        case .until: return "Awake for \(Format.duration(model.remaining ?? 0))"
        case .indefinite: return "Awake until you turn it off"
        case .whileAgentsRun: return "Awake while \(model.agents.keys.sorted().joined(separator: ", ")) runs"
        case .off: return "Your Mac sleeps normally"
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
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Mic and camera at a glance, with who is using the mic.
struct PrivacyStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Indicator(on: model.privacy.micInUse, onIcon: "mic.fill", offIcon: "mic", label: "Mic")
                Indicator(on: model.privacy.cameraInUse, onIcon: "video.fill", offIcon: "video", label: "Camera")
                Spacer()
                if let muted = model.privacy.micMuted {
                    Button(muted ? "Unmute mic" : "Mute mic") { model.toggleMicMute() }
                        .controlSize(.small)
                }
            }
            if !model.privacy.micUsers.isEmpty {
                Text("Mic in use by " + model.privacy.micUsers.map(model.appName).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Indicator: View {
    var on: Bool
    var onIcon: String
    var offIcon: String
    var label: String

    var body: some View {
        Label(on ? "\(label) live" : "\(label) off", systemImage: on ? onIcon : offIcon)
            .font(.callout)
            .foregroundStyle(on ? Color.red : Color.secondary)
    }
}

struct AwakeControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep awake").font(.subheadline.weight(.semibold))
            HStack {
                Button("1 h") { model.keepAwake(for: 3600) }
                Button("3 h") { model.keepAwake(for: 3 * 3600) }
                Button("∞") { model.setMode(.indefinite) }.help("Until you turn it off")
                Button("Off") { model.setMode(.off) }.disabled(model.mode == .off)
            }
            .controlSize(.small)
            Toggle(isOn: Binding(get: { if case .whileAgentsRun = model.mode { true } else { false } },
                                 set: { model.setMode($0 ? .whileAgentsRun(grace: 120) : .off) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("While AI agents run")
                    Text(agentLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if compact { Text("Lid closed").font(.subheadline.weight(.semibold)) }
                Spacer()
                if model.lidIntent.enabled, let end = model.lidIntent.expires {
                    Text("until \(end.formatted(date: .omitted, time: .shortened)) at most")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.lidIntent.enabled {
                Text(endsText).font(.caption).foregroundStyle(.secondary)
                Button("End lid session") { model.endLidSession(reason: "you ended it") }
                    .controlSize(.small)
            } else {
                Text("Keeps agents running with the lid shut, then sleeps by itself. Asks for your password once.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper(value: $model.lidHours, in: 0...12, step: 0.5) {
                    Text(model.lidHours > 0 ? "Sleep \(Format.hours(model.lidHours)) after the lid closes" : "No lid-closed limit")
                        .font(.callout)
                }
                .controlSize(.small)
                if !compact {
                    Toggle("Also sleep at a set time", isOn: $model.lidSleepAtEnabled)
                    if model.lidSleepAtEnabled {
                        DatePicker("Sleep at", selection: $model.lidSleepAt, displayedComponents: [.date, .hourAndMinute])
                    }
                    Toggle("Allow on battery (stops at 20%)", isOn: $model.lidAllowBattery)
                    Toggle("End when all agents finish", isOn: $model.endLidSessionWhenAgentsFinish)
                }
                if !compact && !model.launchAtLogin {
                    Text("Tip: turn on “Open Keepwatch at login”. If the Mac restarts mid-session, that lets Keepwatch turn sleep back on.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.lidBusy ? "Waiting for password…" : "Start lid session") { model.startLidSession() }
                    .disabled(model.lidBusy || !canStart)
                    .controlSize(.small)
                if !canStart {
                    Text(compact ? "Plug in power first, or allow battery in the dashboard."
                                 : "Plug in power first, or turn on “Allow on battery” above.")
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
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : (m > 0 ? "\(m) min" : "\(s) s")
    }

    static func hours(_ h: Double) -> String {
        h == h.rounded() ? "\(Int(h)) h" : String(format: "%.1f h", h)
    }
}
