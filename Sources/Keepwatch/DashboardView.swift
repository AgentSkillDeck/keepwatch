import KeepwatchCore
import SwiftUI

/// The dashboard's sections, one per tab.
enum DashboardTab: String, CaseIterable, Identifiable {
    case awake, agents, lid, privacy, security, power, ports, settings
    var id: String { rawValue }

    /// The tab bar. Lid closed lives inside Awake as a sub-tab; `.lid` stays so
    /// links and saved selections that name it still land there.
    static let shown: [DashboardTab] = [.awake, .agents, .privacy, .security, .power, .ports, .settings]

    var title: String {
        switch self {
        case .awake: "Stay awake"
        case .agents: "Agents"
        case .lid: "Lid closed"
        case .privacy: "Privacy"
        case .security: "Security"
        case .power: "Battery"
        case .ports: "Apps"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .awake: "eye.fill"
        case .agents: "terminal.fill"
        case .lid: "laptopcomputer"
        case .privacy: "hand.raised.fill"
        case .security: "checkmark.shield.fill"
        case .power: "bolt.fill"
        case .ports: "square.stack.3d.up.fill"
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
            TabBar(selection: Binding(get: { (initialTab ?? tab) == .lid ? .awake : (initialTab ?? tab) },
                                      set: { tab = $0 }))
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

    @AppStorage("awakeSub") private var awakeSub = "Lid open"
    @AppStorage("privacySub") private var privacySub = "Now"

    private var lidOpenCard: some View {
        Card("Keep awake", icon: "eye.fill") {
            AwakeControls()
            StayActiveRow()
            SwitchRow(icon: "display", title: "Keep screen on",
                      subtitle: "Stops the screen going dark", isOn: $model.keepDisplayAwake)
            SwitchRow(icon: "bell.badge", title: "Tell me when an agent is done",
                      isOn: $model.notifyWhenAgentsFinish)
            SwitchRow(icon: "powerplug.fill", title: "Stay awake while plugged in",
                      subtitle: model.autoReason.map { "On now: \($0)" }, isOn: $model.autoWhilePlugged)
            SwitchRow(icon: "display.2", title: "Stay awake with an external display", isOn: $model.autoWhileDisplay)
            SwitchRow(icon: "powerplug", title: "Stop when unplugged", isOn: $model.stopAwakeOnBattery)
            SwitchRow(icon: "battery.25percent", title: "Stop at 15% battery", isOn: $model.stopAwakeOnLowBattery)
            SwitchRow(icon: "command", title: "Shortcuts ⌃⌥⌘K and ⌃⌥⌘S",
                      subtitle: "K: keep-awake on or off. S: screenshot or screen video.", isOn: $model.hotkeyEnabled)
            if let others = model.pmset?.sleepPreventedBy.filter({ $0 != "powerd" }), !others.isEmpty {
                Label("Also keeping your Mac awake: \(others.joined(separator: ", "))", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @AppStorage("appsSub") private var appsSub = "Memory"

    private var permissionsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "App permissions")
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
    }

    @ViewBuilder private func section(_ tab: DashboardTab) -> some View {
        switch tab {
        case .awake, .lid:
            VStack(alignment: .leading, spacing: 12) {
                AwakeModePicker(selection: Binding(get: { tab == .lid ? "Lid closed" : awakeSub },
                                                   set: { awakeSub = $0; if self.tab == .lid { self.tab = .awake } }))
                if tab == .lid || awakeSub == "Lid closed" {
                    Card("Lid-closed session", icon: "laptopcomputer") { LidSessionCard(compact: false) }
                } else {
                    lidOpenCard
                }
            }
        case .agents:
            Card("Agent sessions", icon: "terminal.fill") {
                AgentSessionsList()
                SwitchRow(icon: "bell.badge", title: "Tell me when an agent goes quiet",
                          subtitle: "It may be done, or waiting for your answer", isOn: $model.notifyAgentWaiting)
            }
        case .privacy:
            VStack(alignment: .leading, spacing: 12) {
                SubTabs(selection: $privacySub, options: ["Now", "History", "Permissions"])
                Card("Privacy", icon: "hand.raised.fill") {
                    switch privacySub {
                    case "History": PrivacyHistory()
                    case "Permissions": permissionsGrid
                    default:
                        PrivacySwitches(compact: false)
                        CameraResetRow()
                    }
                }
            }
        case .security:
            Card("Security", icon: "checkmark.shield.fill") { SecurityList() }
        case .power:
            VStack(spacing: 16) {
                Card("Battery & power", icon: "bolt.fill") { PowerFacts() }
                Card("Battery health over time", icon: "chart.line.downtrend.xyaxis") { BatteryHistoryView() }
            }
        case .ports:
            VStack(alignment: .leading, spacing: 12) {
                SubTabs(selection: $appsSub, options: ["Memory", "Ports"])
                if appsSub == "Ports" {
                    Card("Listening ports", icon: "network") { PortsList() }
                } else {
                    Card("Using the most memory", icon: "memorychip") { TopAppsList() }
                }
            }
        case .settings:
            AboutCard()
            MenuButtonsCard()
            Card("Settings", icon: "slider.horizontal.3") {
                ForEach(QuickToggle.allCases) { t in
                    SwitchRow(icon: t.icon, title: t.title,
                              isOn: Binding(get: { model.toggles[t] ?? false }, set: { model.setToggle(t, $0) }))
                }
                SwitchRow(icon: "speaker.wave.2", title: "Sound with notifications", isOn: $model.notificationSound)
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
        HStack(spacing: 2) {
            ForEach(DashboardTab.shown) { tab in
                let selected = tab == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = tab } } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.primary)
                        .background(selected ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(Color.clear),
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String((DashboardTab.shown.firstIndex(of: tab) ?? 0) + 1))),
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
                Text("Reset camera access").font(.system(size: 13, weight: .medium))
                Text("Every app must ask again to use it").font(.caption).foregroundStyle(.secondary)
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

/// Things the summary can show: any number, six to a row.
enum SummaryTile: String, CaseIterable, Identifiable {
    case battery, health, agents, mic, camera, cpu, memory, thermal, cycles, timeLeft, ports, security
    static let defaults: [SummaryTile] = [.battery, .health, .agents, .mic, .camera]
    static let maxShown = SummaryTile.allCases.count
    static let perRow = 6
    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: "Battery charge"
        case .health: "Battery health"
        case .agents: "Agents running"
        case .mic: "Microphone"
        case .camera: "Camera"
        case .cpu: "CPU"
        case .memory: "Memory"
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
    @AppStorage("dashboardTab") private var tab: DashboardTab = .awake

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
                    Button("Show all") { model.summaryTiles = SummaryTile.allCases }
                    Button("Reset to default") { model.summaryTiles = SummaryTile.defaults }
                } label: {
                    Label("Customize", systemImage: "square.grid.2x2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose what the summary shows; more than six makes a second row")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                     count: min(SummaryTile.perRow, max(1, model.summaryTiles.count))),
                      spacing: 10) {
                ForEach(model.summaryTiles) { tileView($0).frame(height: 96) }
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
            Button { tab = .agents } label: {
                StatTile(value: String(n), caption: n == 1 ? "Agent session" : "Agent sessions") {
                    if model.agents.isEmpty { TileSymbol(name: "terminal.fill", tint: Brand.teal) }
                    else { AgentBadges(agents: model.agents, size: 18) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("See and stop agent sessions")
        case .mic:
            let live = model.privacy.micInUse
            StatTile(value: model.privacy.micMuted == true ? "Muted" : (live ? "Live" : "Idle"),
                     caption: "Microphone", icon: live ? "mic.fill" : (model.privacy.micMuted == true ? "mic.slash.fill" : "mic"),
                     tint: live ? Brand.live : Brand.teal)
        case .camera:
            let live = model.privacy.cameraInUse
            StatTile(value: live ? "Live" : "Off", caption: "Camera", icon: live ? "video.fill" : "video.slash",
                     tint: live ? Brand.live : Brand.teal)
        case .cpu:
            let busy = (model.load.cpuPercent ?? 0) >= 85
            StatTile(value: model.load.cpuPercent.map { "\($0)%" } ?? "–", caption: "CPU", icon: "cpu",
                     tint: busy ? .orange : Brand.teal)
        case .memory:
            let full = (model.load.memoryPercent ?? 0) >= 90
            StatTile(value: model.load.memoryPercent.map { "\($0)%" } ?? "–", caption: "Memory", icon: "memorychip",
                     tint: full ? .orange : Brand.teal)
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
            Text("Keepwatch only shows these. Tap › to change one in System Settings.")
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
                Text("No open ports.").font(.callout).foregroundStyle(.secondary)
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
                        Text(p.address == "*" ? "Open to network" : "This Mac only")
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

/// Agent sessions grouped by agent, each with its folder, age and a Stop button.
struct AgentSessionsList: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming: [AgentSession] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.agentSessions.isEmpty {
                Text("No agents running.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.0) { agent, sessions in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        AgentBadge(name: agent, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent).font(.system(size: 14, weight: .semibold))
                            Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if sessions.count > 1 {
                            Button { confirming = sessions } label: { Label("Stop all", systemImage: "stop.fill") }
                                .controlSize(.small)
                        }
                    }
                    ForEach(sessions) { session in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").foregroundStyle(Brand.teal).frame(width: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(model.sessionTitles[session.pid] ?? session.folderName ?? "Unknown folder")
                                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    if model.sessionTitles[session.pid] != nil, let folder = session.folderName {
                                        Text(folder).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.primary.opacity(0.07), in: Capsule())
                                    }
                                }
                                Text(detail(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            ActivityPill(activity: model.agentActivity[session.pid])
                            Button { confirming = [session] } label: { Label("Stop", systemImage: "stop.fill") }
                                .controlSize(.small)
                        }
                        .padding(.leading, 10)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .confirmationDialog(title, isPresented: Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } })) {
            Button(confirming.count > 1 ? "Stop \(confirming.count) sessions" : "Stop session", role: .destructive) {
                for s in confirming { model.stopAgent(s) }
                confirming = []
            }
        } message: {
            Text("Unsaved work in the session may be lost.")
        }
    }

    private var groups: [(String, [AgentSession])] {
        Dictionary(grouping: model.agentSessions, by: \.agent).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var title: String {
        guard let first = confirming.first else { return "" }
        return confirming.count > 1 ? "Stop all \(first.agent) sessions?" : "Stop \(first.agent) in \(first.folderName ?? "this folder")?"
    }

    private func detail(_ s: AgentSession) -> String {
        var parts: [String] = []
        if let started = s.started { parts.append("started " + started.formatted(.relative(presentation: .named))) }
        if let folder = s.folder { parts.append((folder as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: " · ")
    }
}

/// "Working" in teal or "Idle" in grey.
struct ActivityPill: View {
    var activity: AgentActivity?

    var body: some View {
        let working = activity == .working
        HStack(spacing: 4) {
            Circle().fill(working ? Brand.teal : Color.secondary).frame(width: 6, height: 6)
            Text(working ? "Working" : "Idle").font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(working ? Brand.teal : Color.secondary)
        .background((working ? Brand.teal : Color.primary).opacity(0.1), in: Capsule())
    }
}

/// When the mic and camera turned on and off. Kept on this Mac only.
struct PrivacyHistory: View {
    @EnvironmentObject var model: AppModel
    @State private var page = 0
    static let pageSize = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "History · kept on this Mac")
                Spacer()
                if !model.privacyLog.events.isEmpty {
                    Button("Clear") { model.clearPrivacyLog() }.buttonStyle(.borderless).font(.caption)
                }
            }
            if model.privacyLog.events.isEmpty {
                Text("Nothing yet. Mic and camera use will show here.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.privacyLog.page(page, size: Self.pageSize)) { e in
                HStack(spacing: 8) {
                    Image(systemName: e.device == .mic ? (e.on ? "mic.fill" : "mic.slash") : (e.on ? "video.fill" : "video.slash"))
                        .foregroundStyle(e.on ? Brand.live : Color.secondary)
                        .frame(width: 20)
                    Text(line(e)).font(.callout).lineLimit(1)
                    Spacer()
                    Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            let pages = model.privacyLog.pageCount(size: Self.pageSize)
            if pages > 1 {
                let shown = min(page, pages - 1)
                HStack {
                    Button { page = max(0, shown - 1) } label: { Label("Newer", systemImage: "chevron.left") }
                        .disabled(shown == 0)
                    Spacer()
                    Text("Page \(shown + 1) of \(pages) · \(model.privacyLog.events.count) events (keeps the last \(PrivacyLog.maxEvents))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { page = min(pages - 1, shown + 1) } label: { Label("Older", systemImage: "chevron.right") }
                        .disabled(shown >= pages - 1)
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private func line(_ e: PrivacyEvent) -> String {
        let device = e.device == .mic ? "Mic" : "Camera"
        let state = e.on ? "on" : "off"
        return e.apps.isEmpty ? "\(device) \(state)" : "\(device) \(state) · \(e.apps.joined(separator: ", "))"
    }
}

/// Your apps by memory, with a confirmed Quit. macOS's own processes are shown but can't be quit.
struct TopAppsList: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming: AppUsage?
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.topApps.isEmpty { Text("Reading memory use…").font(.callout).foregroundStyle(.secondary) }
            let top = model.topApps.first?.bytes ?? 1
            ForEach(model.topApps) { app in
                HStack(spacing: 10) {
                    AppIcon(path: app.path)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if app.pids.count > 1 {
                                Text("\(app.pids.count) processes").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        GeometryReader { g in
                            Capsule().fill(Color.primary.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(app.isSystem ? Color.secondary : Brand.teal)
                                        .frame(width: max(4, g.size.width * CGFloat(Double(app.bytes) / Double(max(top, 1)))))
                                }
                        }
                        .frame(height: 5)
                    }
                    Text(TopApps.describe(bytes: app.bytes)).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
                    if app.isSystem {
                        Text("macOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 64)
                    } else {
                        Button { confirming = app } label: { Label("Quit", systemImage: "xmark.circle.fill") }
                            .controlSize(.small).frame(width: 64)
                    }
                }
            }
        }
        .onAppear { model.refreshTopApps() }
        .onReceive(timer) { _ in model.refreshTopApps() }
        .confirmationDialog(confirming.map { "Quit \($0.name)?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Quit", role: .destructive) { if let a = confirming { model.quitApp(a) } }
        } message: {
            Text("Like pressing ⌘Q in the app. It may ask you to save your work.")
        }
    }
}

/// The app's own icon, from its bundle; a generic one for plain tools.
struct AppIcon: View {
    var path: String
    var body: some View {
        Image(nsImage: path.hasSuffix(".app") ? NSWorkspace.shared.icon(forFile: path)
                                              : NSWorkspace.shared.icon(for: .unixExecutable))
            .resizable().frame(width: 28, height: 28)
    }
}

/// One reading a day of battery health, as a small line and the change.
struct BatteryHistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let r = model.batteryHistory.readings
        VStack(alignment: .leading, spacing: 8) {
            if r.count < 2 {
                Text("Keepwatch saves one reading a day. Check back in a few days.").font(.callout).foregroundStyle(.secondary)
            } else {
                GeometryReader { g in
                    let values = r.map { Double($0.healthPercent) }
                    let lo = (values.min() ?? 0) - 1, hi = (values.max() ?? 100) + 1
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let x = g.size.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
                            let y = g.size.height * CGFloat(1 - (v - lo) / max(0.001, hi - lo))
                            i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(Brand.teal, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 70)
            }
            if let first = r.first, let last = r.last {
                Text("\(last.healthPercent)% now" + (model.batteryHistory.change.map { ", \($0 >= 0 ? "+" : "")\($0) points since \(first.day)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Which keep-awake lengths get a button in the menu.
struct MenuButtonsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card("Buttons in the menu", icon: "rectangle.grid.1x2") {
            Text("Pick up to \(AwakePreset.menuMax). The rest are under ⋯ in the menu.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(AwakePreset.allCases) { preset in
                    let on = model.menuPresets.contains(preset)
                    Button { model.menuPresets = AwakePreset.toggle(preset, in: model.menuPresets) } label: {
                        Text(preset.label).font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(TileButtonStyle(selected: on, height: 30))
                    .disabled(!on && model.menuPresets.count >= AwakePreset.menuMax)
                }
            }
        }
    }
}

/// A row of sub-sections inside a tab, so nothing hides below the fold.
struct SubTabs: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button(option) { withAnimation(.snappy(duration: 0.2)) { selection = option } }
                    .buttonStyle(ChipButtonStyle(selected: option == selection))
            }
            Spacer(minLength: 0)
        }
    }
}

/// Version, links and the opt-in update check.
struct AboutCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card("Keepwatch \(AppModel.currentVersion)", icon: "info.circle") {
            HStack(spacing: 8) {
                if let update = model.availableUpdate {
                    if update.appZip != nil {
                        Button { model.installUpdate() } label: {
                            Label(model.updateInstalling ? "Installing…" : "Install \(update.version) and relaunch",
                                  systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(Brand.teal)
                        .disabled(model.updateInstalling)
                    }
                    Button { NSWorkspace.shared.open(update.page) } label: { Text("What's new") }
                }
                Button("Check for updates") { model.checkForUpdates(userAsked: true) }
                Spacer()
                Button { if let u = AppModel.websiteURL { NSWorkspace.shared.open(u) } } label: { Label("Website", systemImage: "globe") }
                Button { if let u = AppModel.sourceURL { NSWorkspace.shared.open(u) } } label: { Label("Source", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            .controlSize(.small)
            if let status = model.updateStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            SwitchRow(icon: "arrow.triangle.2.circlepath", title: "Check for updates once a day",
                      subtitle: "Off by default. Asks GitHub for the latest version number; nothing else is sent. Updates install only when you click Install.",
                      isOn: $model.autoCheckUpdates)
        }
    }
}

/// The difference between the two ways to stay awake, in two lines.
/// The two ways to stay awake, as two cards you pick between; each says what
/// it does, so the difference is clear before choosing.
struct AwakeModePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            mode("eye.fill", "Lid open",
                 "Stops the Mac sleeping while you're away, like caffeinate. Closing the lid still sleeps it. No password.")
            mode("laptopcomputer", "Lid closed",
                 "Keeps working with the lid shut, then sleeps by itself. Needs your password once.")
        }
    }

    private func mode(_ icon: String, _ title: String, _ text: String) -> some View {
        let selected = selection == title
        return Button { withAnimation(.snappy(duration: 0.2)) { selection = title } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Color.black.opacity(0.85) : Brand.teal)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(selected ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(Brand.teal.opacity(0.14))))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(text).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Brand.teal.opacity(0.10) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Brand.teal.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Keeps chat and meeting apps from marking you away.
struct StayActiveRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SwitchRow(icon: "cursorarrow.motionlines", title: "Stay active in chat apps",
                      subtitle: "Slack, Teams, Zoom and others won't show you as away. Moves the pointer 1 pixel when you're idle; never clicks or types.",
                      isOn: $model.stayActive)
            if model.stayActive {
                HStack(spacing: 6) {
                    Text("When idle for").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(StayActive.idleChoices, id: \.self) { m in
                        Button { model.stayActiveMinutes = m } label: {
                            Text("\(m) min").font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(TileButtonStyle(selected: model.stayActiveMinutes == m, height: 26))
                        .frame(width: 70)
                    }
                }
                .padding(.leading, 38)
                if !model.accessibilityTrusted {
                    HStack {
                        Label("Needs Accessibility: turn on Keepwatch in the list.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Accessibility") { model.open(.accessibility) }.controlSize(.small)
                    }
                    .padding(.leading, 38)
                }
            }
        }
    }
}
