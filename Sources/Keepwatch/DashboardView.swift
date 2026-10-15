import KeepwatchCore
import SwiftUI

/// The full window: a status summary, then every control grouped in cards.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SummaryHeader()
                if let banner = model.banner { BannerView(banner: banner) }
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        Card("Stay awake", icon: "eye.fill") {
                            AwakeControls()
                            SwitchRow(icon: "display", title: "Keep the display on too",
                                      subtitle: "Otherwise the screen dims as usual", isOn: $model.keepDisplayAwake)
                            SwitchRow(icon: "bell.badge", title: "Notify me when an agent finishes",
                                      isOn: $model.notifyWhenAgentsFinish)
                            if let others = model.pmset?.sleepPreventedBy.filter({ $0 != "powerd" }), !others.isEmpty {
                                Label("Also keeping your Mac awake: \(others.joined(separator: ", "))", systemImage: "info.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Card("Lid-closed sessions", icon: "laptopcomputer") {
                            LidSessionCard(compact: false)
                        }
                        Card("Listening ports", icon: "network") { PortsList() }
                    }
                    VStack(spacing: 16) {
                        Card("Privacy", icon: "hand.raised.fill") {
                            PrivacySwitches(compact: false)
                            Divider()
                            Eyebrow(text: "Who can use what · opens System Settings")
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                                ForEach(PrivacyPane.allCases, id: \.self) { pane in
                                    Button { model.open(pane) } label: {
                                        VStack(spacing: 5) {
                                            Image(systemName: pane.icon).font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(Brand.teal)
                                            Text(pane.shortTitle).font(.system(size: 10.5, weight: .medium))
                                                .lineLimit(1).minimumScaleFactor(0.8)
                                        }
                                    }
                                    .buttonStyle(TileButtonStyle(selected: false))
                                    .help("Open \(pane.title) in System Settings")
                                }
                            }
                        }
                        Card("Security", icon: "checkmark.shield.fill") { SecurityList() }
                        Card("Battery & power", icon: "bolt.fill") { PowerFacts() }
                        Card("Quick settings", icon: "slider.horizontal.3") {
                            ForEach(QuickToggle.allCases) { t in
                                SwitchRow(icon: t.icon, title: t.title,
                                          isOn: Binding(get: { model.toggles[t] ?? false }, set: { model.setToggle(t, $0) }))
                            }
                            SwitchRow(icon: "power.circle", title: "Open Keepwatch at login",
                                      isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                            HStack {
                                Button("Manage login items…") { model.open(.loginItems) }
                                Button("Install the keepwatch command") { model.installCLI() }
                                    .help("For Terminal and AI agents")
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 820, height: 760)
        .onAppear { model.refreshSecurity() }
    }
}

/// The big status and the numbers worth a glance.
struct SummaryHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusHeader(large: true)
            HStack(spacing: 12) {
            StatTile(value: model.power?.batteryPercent.map { "\($0)%" } ?? "–",
                     caption: model.power.map { $0.onBattery ? "On battery" : "Plugged in" } ?? "Battery",
                     icon: model.power?.onBattery == false ? "powerplug.fill" : "battery.75percent")
            StatTile(value: model.power?.healthPercent.map { "\($0)%" } ?? "–", caption: "Battery health", icon: "heart.fill")
            StatTile(value: "\(model.agents.count)", caption: model.agents.count == 1 ? "Agent running" : "Agents running",
                     icon: "terminal.fill")
            StatTile(value: model.privacy.micInUse || model.privacy.cameraInUse ? "Live" : "Off",
                     caption: "Mic & camera", icon: "video.fill",
                     tint: model.privacy.micInUse || model.privacy.cameraInUse ? Brand.live : Brand.teal)
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Brand.teal.opacity(0.18), Brand.teal.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.teal.opacity(0.25)))
    }
}

/// Firewall, FileVault, Gatekeeper, SIP and AirDrop, each with a status pill.
struct SecurityList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(SecurityCheck.allCases) { check in
                let state = model.security[check] ?? .unknown
                HStack(spacing: 10) {
                    IconBadge(icon: check.icon, tint: tint(state))
                    Text(check.title).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(state.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(tint(state))
                        .background(tint(state).opacity(0.14), in: Capsule())
                    if check.settingsURL != nil {
                        Button { model.open(check) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.borderless)
                            .help("Open in System Settings")
                    } else {
                        Image(systemName: "chevron.right").opacity(0)
                    }
                }
            }
            Text("Read-only: Keepwatch shows these and opens the right settings; it never changes them.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tint(_ state: SecurityState) -> Color {
        switch state {
        case .good: Brand.teal
        case .weak: .orange
        case .unknown: .secondary
        }
    }
}

extension PrivacyPane {
    var icon: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .fullDiskAccess: "externaldrive.fill"
        case .automation: "gearshape.2.fill"
        case .location: "location.fill"
        case .loginItems: "power.circle"
        }
    }

    var shortTitle: String {
        switch self {
        case .screenRecording: "Screen"
        case .fullDiskAccess: "Disk"
        case .location: "Location"
        case .loginItems: "Login items"
        default: title
        }
    }
}

extension QuickToggle {
    var icon: String {
        switch self {
        case .dockAutohide: "dock.rectangle"
        case .showHiddenFiles: "eye.square"
        case .showFileExtensions: "doc.text"
        }
    }
}

struct PowerFacts: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let p = model.power {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Charge", p.batteryPercent.map { "\($0)%" + (p.charging ? " (charging)" : "") })
                row("Source", p.onBattery ? "Battery" : "Power adapter")
                row("Time left", p.minutesRemaining.map { Format.duration(TimeInterval($0 * 60)) })
                row("Health", p.healthPercent.map { "\($0)% of original capacity" })
                row("Cycles", p.cycleCount.map(String.init))
                row("Low Power Mode", p.lowPowerMode ? "On" : "Off")
                row("Thermal", thermal(p.thermal))
                row("Lid", p.lidClosed.map { $0 ? "Closed" : "Open" })
            }
            .font(.callout)
        } else {
            Text("Reading power state…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(title).foregroundStyle(.secondary)
                Text(value)
            }
        }
    }

    private func thermal(_ t: LidModePolicy.Thermal) -> String {
        switch t {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot: lid sessions stop"
        case .critical: "Very hot"
        }
    }
}

struct Card<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        Panel(padding: 16) {
            SectionHeader(icon: icon, title: title)
            content
        }
    }
}

/// Your processes listening on TCP ports, with a confirmed Stop.
struct PortsList: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming: ListeningPort?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.ports.isEmpty {
                Text("Nothing of yours is listening.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.ports.prefix(12), id: \.self) { p in
                HStack {
                    Text(":\(p.port)").font(.callout.monospacedDigit()).frame(width: 64, alignment: .leading)
                    Text(p.process).font(.callout).lineLimit(1)
                    Text(p.address == "*" ? "all interfaces" : p.address).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if p.isSystem {
                        Text("macOS").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Button("Stop") { confirming = p }.controlSize(.small)
                    }
                }
            }
            Button("Refresh") { model.refreshPorts() }.buttonStyle(.link)
        }
        .onAppear { model.refreshPorts() }
        .confirmationDialog(confirming.map { "Stop \($0.process) on port \($0.port)?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Stop process", role: .destructive) { if let p = confirming { model.stopProcess(p) } }
        } message: {
            Text("Sends it a normal quit signal. Unsaved work in that process may be lost.")
        }
    }
}
