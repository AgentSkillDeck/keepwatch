import KeepwatchCore
import SwiftUI

/// The dashboard's sections, one per tab.
enum DashboardTab: String, CaseIterable, Identifiable {
    case awake, lid, privacy, security, power, ports, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .awake: "Awake"
        case .lid: "Lid closed"
        case .privacy: "Privacy"
        case .security: "Security"
        case .power: "Battery"
        case .ports: "Ports"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .awake: "eye.fill"
        case .lid: "laptopcomputer"
        case .privacy: "hand.raised.fill"
        case .security: "checkmark.shield.fill"
        case .power: "bolt.fill"
        case .ports: "network"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// The full window: a customisable summary, then one section at a time in tabs.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("dashboardTab") private var tab: DashboardTab = .awake
    var initialTab: DashboardTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SummaryHeader()
            if let banner = model.banner { BannerView(banner: banner) }
            TabBar(selection: Binding(get: { initialTab ?? tab }, set: { tab = $0 }))
            ScrollView {
                section(initialTab ?? tab)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
        }
        .padding(20)
        .frame(width: 760, height: 720)
        .onAppear { model.refreshSecurity(); model.refreshPorts() }
    }

    @ViewBuilder private func section(_ tab: DashboardTab) -> some View {
        switch tab {
        case .awake:
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
        case .lid:
            Card("Lid-closed sessions", icon: "laptopcomputer") { LidSessionCard(compact: false) }
        case .privacy:
            Card("Privacy", icon: "hand.raised.fill") {
                PrivacySwitches(compact: false)
                CameraResetRow()
                Divider()
                Eyebrow(text: "Who can use what · opens System Settings")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(PrivacyPane.allCases, id: \.self) { pane in
                        Button { model.open(pane) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: pane.icon).font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Brand.teal)
                                Text(pane.shortTitle).font(.system(size: 11, weight: .medium))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(TileButtonStyle(selected: false))
                        .help("Open \(pane.title) in System Settings")
                    }
                }
            }
        case .security:
            Card("Security", icon: "checkmark.shield.fill") { SecurityList() }
        case .power:
            Card("Battery & power", icon: "bolt.fill") { PowerFacts() }
        case .ports:
            Card("Listening ports", icon: "network") { PortsList() }
        case .settings:
            Card("Settings", icon: "slider.horizontal.3") {
                ForEach(QuickToggle.allCases) { t in
                    SwitchRow(icon: t.icon, title: t.title,
                              isOn: Binding(get: { model.toggles[t] ?? false }, set: { model.setToggle(t, $0) }))
                }
                SwitchRow(icon: "power.circle", title: "Open Keepwatch at login",
                          subtitle: "Recommended if you use lid sessions",
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                HStack {
                    Button { model.open(.loginItems) } label: { Label("Manage login items", systemImage: "list.bullet") }
                    Button { model.installCLI() } label: { Label("Install the keepwatch command", systemImage: "terminal") }
                        .help("For Terminal and AI agents")
                }
                .controlSize(.regular)
            }
        }
    }
}

/// Pill tabs with an icon each; the selected one is filled teal.
struct TabBar: View {
    @Binding var selection: DashboardTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DashboardTab.allCases) { tab in
                let selected = tab == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = tab } } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.primary)
                        .background(selected ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(Color.clear),
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String((DashboardTab.allCases.firstIndex(of: tab) ?? 0) + 1))),
                                  modifiers: .command)
                .help("\(tab.title) (⌘\((DashboardTab.allCases.firstIndex(of: tab) ?? 0) + 1))")
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// Take camera access back from every app, after a confirmation.
struct CameraResetRow: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(icon: "arrow.counterclockwise", tint: .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Make every app ask again for the camera").font(.system(size: 13, weight: .medium))
                Text("macOS has no camera off switch; this is the closest thing").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Reset…") { confirming = true }.controlSize(.small)
        }
        .confirmationDialog("Take camera access away from every app?", isPresented: $confirming) {
            Button("Reset camera access", role: .destructive) { model.resetCameraPermissions() }
        } message: {
            Text("Each app will have to ask you again before it can use the camera. Apps that are open keep access until you quit them. This can't be undone with one click.")
        }
    }
}

/// Things the summary can show. People pick up to six.
enum SummaryTile: String, CaseIterable, Identifiable {
    case battery, health, agents, mic, camera, thermal, cycles, timeLeft, ports, security
    static let defaults: [SummaryTile] = [.battery, .health, .agents, .mic, .camera]
    static let maxShown = 6
    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: "Battery charge"
        case .health: "Battery health"
        case .agents: "Agents running"
        case .mic: "Microphone"
        case .camera: "Camera"
        case .thermal: "Temperature"
        case .cycles: "Charge cycles"
        case .timeLeft: "Battery time left"
        case .ports: "Listening ports"
        case .security: "Security checks"
        }
    }
}

/// The big status and the numbers worth a glance; the pencil picks which.
struct SummaryHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                StatusHeader(large: true)
                Menu {
                    ForEach(SummaryTile.allCases) { tile in
                        Toggle(tile.title, isOn: Binding(get: { model.summaryTiles.contains(tile) },
                                                         set: { _ in model.toggleTile(tile) }))
                    }
                    Divider()
                    Button("Reset to default") { model.summaryTiles = SummaryTile.defaults }
                } label: {
                    Label("Customize", systemImage: "square.grid.2x2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose what the summary shows (up to \(SummaryTile.maxShown))")
            }
            HStack(spacing: 10) {
                ForEach(model.summaryTiles) { tileView($0) }
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Brand.teal.opacity(0.18), Brand.teal.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.teal.opacity(0.25)))
    }

    @ViewBuilder private func tileView(_ tile: SummaryTile) -> some View {
        let p = model.power
        switch tile {
        case .battery:
            StatTile(value: p?.batteryPercent.map { "\($0)%" } ?? "–",
                     caption: p.map { $0.charging ? "Charging" : ($0.onBattery ? "On battery" : "Plugged in") } ?? "Battery",
                     icon: p?.onBattery == false ? "powerplug.fill" : "battery.75percent")
        case .health:
            StatTile(value: p?.healthPercent.map { "\($0)%" } ?? "–", caption: "Battery health", icon: "heart.fill")
        case .agents:
            let n = model.agents.sessionCount
            StatTile(value: String(n),
                     caption: n == 0 ? "Agents running" : (model.agents.count == 1 ? "\(model.agents.keys.first ?? "Agent") session\(n == 1 ? "" : "s")" : "Agent sessions"),
                     icon: "terminal.fill")
        case .mic:
            let live = model.privacy.micInUse
            StatTile(value: model.privacy.micMuted == true ? "Muted" : (live ? "Live" : "Idle"),
                     caption: "Microphone", icon: live ? "mic.fill" : (model.privacy.micMuted == true ? "mic.slash.fill" : "mic"),
                     tint: live ? Brand.live : Brand.teal)
        case .camera:
            let live = model.privacy.cameraInUse
            StatTile(value: live ? "Live" : "Off", caption: "Camera", icon: live ? "video.fill" : "video.slash",
                     tint: live ? Brand.live : Brand.teal)
        case .thermal:
            let hot = p.map { $0.thermal == .serious || $0.thermal == .critical } ?? false
            StatTile(value: p.map { PowerFacts.thermalName($0.thermal) } ?? "–", caption: "Temperature",
                     icon: "thermometer.medium", tint: hot ? .orange : Brand.teal)
        case .cycles:
            StatTile(value: p?.cycleCount.map(String.init) ?? "–", caption: "Charge cycles", icon: "arrow.triangle.2.circlepath")
        case .timeLeft:
            StatTile(value: p?.minutesRemaining.map { Format.duration(TimeInterval($0 * 60)) } ?? "–",
                     caption: "Battery time left", icon: "hourglass")
        case .ports:
            StatTile(value: String(model.ports.count), caption: "Listening ports", icon: "network")
        case .security:
            let weak = model.security.values.filter { if case .weak = $0 { true } else { false } }.count
            StatTile(value: weak == 0 ? "OK" : "\(weak) to check", caption: "Security", icon: "checkmark.shield.fill",
                     tint: weak == 0 ? Brand.teal : .orange)
        }
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

    private func thermal(_ t: LidModePolicy.Thermal) -> String { Self.thermalName(t) }

    static func thermalName(_ t: LidModePolicy.Thermal) -> String {
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
            ForEach(model.ports.prefix(40), id: \.self) { p in
                HStack(spacing: 10) {
                    IconBadge(icon: p.isSystem ? "apple.logo" : "chevron.left.forwardslash.chevron.right",
                              tint: p.isSystem ? .secondary : Brand.teal)
                    Text(String(p.port))
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .frame(width: 58, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.process).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(p.address == "*" ? "Open to your network" : "This Mac only (\(p.address))")
                            .font(.caption).foregroundStyle(p.address == "*" && !p.isSystem ? Color.orange : Color.secondary)
                    }
                    Spacer(minLength: 8)
                    if p.isSystem {
                        Text("macOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    } else {
                        Button { confirming = p } label: { Label("Stop", systemImage: "stop.fill") }
                            .controlSize(.small)
                    }
                }
            }
            Button { model.refreshPorts() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.controlSize(.small)
        }
        .onAppear { model.refreshPorts() }
        .confirmationDialog(confirming.map { "Stop \($0.process) on port \(String($0.port))?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Stop process", role: .destructive) { if let p = confirming { model.stopProcess(p) } }
        } message: {
            Text("Sends it a normal quit signal. Unsaved work in that process may be lost.")
        }
    }
}
