import KeepwatchCore
import SwiftUI

/// The full window: every control in one place, grouped in cards.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let banner = model.banner { BannerView(banner: banner) }
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        Card("Stay awake", icon: "eye") {
                            AwakeControls()
                            Toggle("Keep the display on too", isOn: $model.keepDisplayAwake)
                            Toggle("Notify me when an agent finishes", isOn: $model.notifyWhenAgentsFinish)
                            if let others = model.pmset?.sleepPreventedBy.filter({ $0 != "powerd" }), !others.isEmpty {
                                Text("Also keeping your Mac awake: \(others.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Card("Lid-closed sessions", icon: "laptopcomputer") {
                            LidSessionCard(compact: false)
                        }
                        Card("Listening ports", icon: "network") { PortsList() }
                    }
                    VStack(spacing: 16) {
                        Card("Privacy", icon: "hand.raised") {
                            PrivacyStrip()
                            Toggle("Mute the mic when the lid closes", isOn: $model.muteMicWhenLidCloses)
                            Text("Open the permission lists in System Settings:")
                                .font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                                ForEach(PrivacyPane.allCases.filter { $0 != .loginItems }, id: \.self) { pane in
                                    Button(pane.title) { model.open(pane) }
                                        .buttonStyle(.link)
                                        .font(.callout)
                                }
                            }
                        }
                        Card("Battery & power", icon: "bolt") { PowerFacts() }
                        Card("Quick settings", icon: "slider.horizontal.3") {
                            ForEach(QuickToggle.allCases) { t in
                                Toggle(t.title, isOn: Binding(get: { model.toggles[t] ?? false },
                                                              set: { model.setToggle(t, $0) }))
                            }
                            Divider()
                            Toggle("Open Keepwatch at login", isOn: Binding(get: { model.launchAtLogin },
                                                                             set: { model.setLaunchAtLogin($0) }))
                            Button("Manage all login items…") { model.open(.loginItems) }
                                .buttonStyle(.link)
                            Button("Install the `keepwatch` command for Terminal and AI agents") { model.installCLI() }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 760, height: 720)
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
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
