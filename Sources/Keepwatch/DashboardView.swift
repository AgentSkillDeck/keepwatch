import Charts
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

    @AppStorage("privacySub") private var privacySub = "Now"
    @AppStorage("awakeSub2") private var awakeSub = "Laptop open"
    @AppStorage("moreAwakeOptions") private var moreAwakeOptions = false

    private var lidOpenCard: some View {
        Card("Laptop open", icon: "eye.fill",
             subtitle: "No sleep while the lid is open. No password.") {
            AwakeControls()
            StayActiveRow()
            SwitchRow(icon: "display", title: "Keep screen on",
                      subtitle: "Stops the screen going dark", isOn: $model.keepDisplayAwake)
            SwitchRow(icon: "bell.badge", title: "Tell me when an agent is done",
                      isOn: $model.notifyWhenAgentsFinish)
            Button { withAnimation(.snappy(duration: 0.2)) { moreAwakeOptions.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(moreAwakeOptions ? 90 : 0))
                    Text("More options: automatic, battery limits, shortcuts").font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if moreAwakeOptions {
                VStack(alignment: .leading, spacing: 10) {
                    SwitchRow(icon: "powerplug.fill", title: "Stay awake while plugged in",
                              subtitle: model.autoReason.map { "On now: \($0)" }, isOn: $model.autoWhilePlugged)
                    SwitchRow(icon: "display.2", title: "Stay awake with an external display", isOn: $model.autoWhileDisplay)
                    SwitchRow(icon: "powerplug", title: "Stop when unplugged", isOn: $model.stopAwakeOnBattery)
                    SwitchRow(icon: "battery.25percent", title: "Stop at 15% battery", isOn: $model.stopAwakeOnLowBattery)
                    SwitchRow(icon: "command", title: "Shortcuts ⌃⌥⌘K and ⌃⌥⌘S",
                              subtitle: "K: keep-awake on or off. S: screenshot or screen video.", isOn: $model.hotkeyEnabled)
                }
                .transition(.opacity)
            }
            if let others = model.pmset?.sleepPreventedBy.filter({ $0 != "powerd" && $0 != "Keepwatch" }), !others.isEmpty {
                Label("Also keeping your Mac awake: \(others.joined(separator: ", "))", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @AppStorage("appsSub") private var appsSub = "Memory"
    @State private var appsQuery = ""

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
                SubTabs(selection: Binding(get: { tab == .lid ? "Laptop closed" : awakeSub },
                                           set: { awakeSub = $0; if self.tab == .lid { self.tab = .awake } }),
                        options: ["Laptop open", "Laptop closed"])
                if tab == .lid || awakeSub == "Laptop closed" {
                    Card("Laptop closed", icon: "laptopcomputer.slash",
                         subtitle: "Runs with the lid shut, then sleeps by itself. Password to start.") {
                        LidSessionCard(compact: false)
                    }
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
                SubTabs(selection: $privacySub, options: ["Now", "By app", "History", "Permissions"])
                Card(privacySub == "By app" ? "Mic and camera use by app" : "Privacy", icon: "hand.raised.fill") {
                    switch privacySub {
                    case "By app": PrivacyByApp()
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
                HStack {
                    SubTabs(selection: $appsSub, options: ["Memory", "Ports"])
                    SearchField(text: $appsQuery, prompt: appsSub == "Ports" ? "Search ports or apps" : "Search apps")
                }
                if appsSub == "Ports" {
                    Card("Listening ports", icon: "network") { PortsList(query: appsQuery) }
                } else {
                    Card("Using the most memory", icon: "memorychip") { TopAppsList(query: appsQuery) }
                }
            }
        case .settings:
            VStack(alignment: .leading, spacing: 12) {
                SubTabs(selection: $settingsSub, options: ["General", "Menu", "Mac tweaks", "Activity log", "About"])
                switch settingsSub {
                case "Activity log": Card("Activity log", icon: "list.bullet.rectangle") { ActivityLogView() }
                case "Menu": MenuButtonsCard()
                case "Mac tweaks":
                    Card("Mac tweaks", icon: "wand.and.stars") {
                        Text("Quick macOS settings. Each can be turned back.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(QuickToggle.allCases) { t in
                            SwitchRow(icon: t.icon, title: t.title,
                                      isOn: Binding(get: { model.toggles[t] ?? false }, set: { model.setToggle(t, $0) }))
                        }
                    }
                case "About": AboutCard()
                default: generalSettings
                }
            }
        }
    }

    @AppStorage("settingsSub") private var settingsSub = "General"

    private var generalSettings: some View {
            Card("General", icon: "slider.horizontal.3") {
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
            Text("Every app must ask again. Open apps keep access until they quit.")
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
                Button { model.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Read everything again now (⌘R)")
                    .keyboardShortcut("r")
                    .padding(.trailing, 6)
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
                ForEach(model.summaryTiles) { tileView($0).frame(height: 76) }
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Brand.teal.opacity(0.18), Brand.teal.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.teal.opacity(0.25)))
    }

    /// Which tab a tile opens when clicked.
    private func destination(_ tile: SummaryTile) -> DashboardTab {
        switch tile {
        case .battery, .health, .thermal, .cycles, .timeLeft: .power
        case .agents: .agents
        case .mic, .camera: .privacy
        case .cpu, .memory, .ports: .ports
        case .security: .security
        }
    }

    @ViewBuilder private func tileView(_ tile: SummaryTile) -> some View {
        Button {
            if tile == .ports { UserDefaults.standard.set("Ports", forKey: "appsSub") }
            if tile == .memory || tile == .cpu { UserDefaults.standard.set("Memory", forKey: "appsSub") }
            withAnimation(.snappy(duration: 0.2)) { tab = destination(tile) }
        } label: { tileContent(tile).contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .help("Open \(destination(tile).title)")
    }

    @ViewBuilder private func tileContent(_ tile: SummaryTile) -> some View {
        let p = model.power
        switch tile {
        case .battery:
            let pct = p?.batteryPercent
            let low = (pct ?? 100) <= 20 && p?.onBattery == true
            StatTile(value: pct.map { "\($0)%" } ?? "–",
                     caption: p.map { $0.charging ? "Charging" : ($0.onBattery ? "On battery" : "Plugged in") } ?? "Battery",
                     icon: p?.onBattery == false ? "powerplug.fill" : "battery.75percent",
                     tint: low ? .orange : Brand.teal, fraction: pct.map { Double($0) / 100 })
        case .health:
            let h = p?.healthPercent
            StatTile(value: h.map { "\($0)%" } ?? "–", caption: "Health", icon: "battery.100percent",
                     tint: (h ?? 100) < 80 ? .orange : Brand.teal, fraction: h.map { Double($0) / 100 })
        case .agents:
            let n = model.agents.sessionCount
            StatTile(value: n == 0 ? "None" : "\(n) running", caption: "Agents", icon: "terminal.fill")
        case .mic:
            let live = model.privacy.micInUse && model.privacy.micMuted != true
            StatTile(value: model.privacy.micMuted == true ? "Muted" : (live ? "Live" : "Idle"),
                     caption: "Microphone", icon: live ? "mic.fill" : (model.privacy.micMuted == true ? "mic.slash.fill" : "mic"),
                     tint: live ? Brand.live : Brand.teal)
        case .camera:
            let live = model.privacy.cameraInUse
            StatTile(value: live ? "Live" : "Off", caption: "Camera", icon: live ? "video.fill" : "video.slash",
                     tint: live ? Brand.live : Brand.teal)
        case .cpu:
            let cpu = model.load.cpuPercent
            StatTile(value: cpu.map { "\($0)%" } ?? "–", caption: "CPU", icon: "cpu",
                     tint: (cpu ?? 0) >= 85 ? .orange : Brand.teal, fraction: cpu.map { Double($0) / 100 })
        case .memory:
            let mem = model.load.memoryPercent
            StatTile(value: mem.map { "\($0)%" } ?? "–", caption: "Memory", icon: "memorychip",
                     tint: (mem ?? 0) >= 90 ? .orange : Brand.teal, fraction: mem.map { Double($0) / 100 })
        case .thermal:
            let hot = p.map { $0.thermal == .serious || $0.thermal == .critical } ?? false
            StatTile(value: p.map { PowerFacts.thermalName($0.thermal) } ?? "–", caption: "Temperature",
                     icon: "thermometer.medium", tint: hot ? .orange : Brand.teal)
        case .cycles:
            StatTile(value: p?.cycleCount.map(String.init) ?? "–", caption: "Cycles", icon: "arrow.triangle.2.circlepath")
        case .timeLeft:
            StatTile(value: p?.minutesRemaining.map { Format.duration(TimeInterval($0 * 60)) }
                         ?? (p?.onBattery == false ? "Plugged in" : "Working it out"),
                     caption: "Time left", icon: "hourglass")
        case .ports:
            StatTile(value: String(model.ports.count), caption: "Ports", icon: "network")
        case .security:
            let weak = model.security.values.filter { if case .weak = $0 { true } else { false } }.count
            StatTile(value: weak == 0 ? "All good" : "\(weak) to check", caption: "Security",
                     icon: weak == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
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
    var subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String, icon: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        Panel(padding: 16) {
            SectionHeader(icon: icon, title: title, subtitle: subtitle)
            content
        }
    }
}

/// Your processes listening on TCP ports, with a confirmed Stop.
struct PortsList: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming: ListeningPort?
    var query = ""

    private var shown: [ListeningPort] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(model.ports.prefix(40)) }
        return model.ports.filter { $0.process.localizedCaseInsensitiveContains(q) || String($0.port).hasPrefix(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.ports.isEmpty {
                Text("No open ports.").font(.callout).foregroundStyle(.secondary)
            } else if shown.isEmpty {
                Text("Nothing matches “\(query)”.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.self) { p in
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
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { p in
            // Use the presented value: the dialog clears `confirming` before this runs.
            Button("Stop process", role: .destructive) { model.stopProcess(p) }
        } message: { _ in
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
        .confirmationDialog(title, isPresented: Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } }),
                            presenting: confirming) { sessions in
            Button(sessions.count > 1 ? "Stop \(sessions.count) sessions" : "Stop session", role: .destructive) {
                for s in sessions { model.stopAgent(s) }
            }
        } message: { _ in
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
    var query = ""

    /// The top 12, or every app that matches the search.
    private var shown: [AppUsage] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(model.topApps.prefix(12)) }
        return model.topApps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.topApps.isEmpty { Text("Reading memory use…").font(.callout).foregroundStyle(.secondary) }
            let top = model.topApps.first?.bytes ?? 1
            if !model.topApps.isEmpty, shown.isEmpty {
                Text("Nothing matches “\(query)”.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(shown) { app in
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
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { app in
            Button("Quit", role: .destructive) { model.quitApp(app) }
        } message: { _ in
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

    private struct Point: Identifiable {
        var date: Date
        var health: Int
        var id: Date { date }
    }

    var body: some View {
        let r = model.batteryHistory.readings
        let f = DateFormatter.yyyyMMdd
        let points = r.compactMap { reading in f.date(from: reading.day).map { Point(date: $0, health: reading.healthPercent) } }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                fact(r.last.map { "\($0.healthPercent)%" } ?? "–", "Health now")
                fact(model.batteryHistory.change.map { "\($0 >= 0 ? "+" : "")\($0) pts" } ?? "–",
                     r.first.map { "Since \(Self.short($0.day))" } ?? "Change")
                fact(model.power?.cycleCount.map(String.init) ?? "–", "Charge cycles")
                fact("80%", "Worn below")
            }
            if points.count < 2 {
                Label("One reading a day; the chart fills in over a few days.", systemImage: "calendar")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                let lowest = min(points.map(\.health).min() ?? 80, 80)
                Chart {
                    RuleMark(y: .value("Worn", 80))
                        .foregroundStyle(Color.orange.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("80%: Apple calls it worn").font(.caption2).foregroundStyle(.orange)
                        }
                    ForEach(points) { pt in
                        AreaMark(x: .value("Day", pt.date), yStart: .value("Base", lowest - 2), yEnd: .value("Health", pt.health))
                            .foregroundStyle(LinearGradient(colors: [Brand.teal.opacity(0.35), Brand.teal.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Day", pt.date), y: .value("Health", pt.health))
                            .foregroundStyle(Brand.teal)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Day", pt.date), y: .value("Health", pt.health))
                            .foregroundStyle(Brand.teal).symbolSize(points.count > 20 ? 0 : 28)
                    }
                }
                .chartYScale(domain: (lowest - 2)...100)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%") } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                } }
                .frame(height: 150)
            }
        }
    }

    private func fact(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func short(_ day: String) -> String {
        guard let d = DateFormatter.yyyyMMdd.date(from: day) else { return day }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Which keep-awake lengths get a button in the menu.
struct MenuButtonsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card("What the menu shows", icon: "menubar.rectangle") {
            Text("Pick what the menu-bar window shows.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(MenuSection.allCases) { section in
                SwitchRow(icon: section.icon, title: section.title,
                          isOn: Binding(get: { model.menuSections.contains(section) },
                                        set: { _ in model.menuSections = MenuSection.toggle(section, in: model.menuSections) }))
            }
            Button("Reset to default") { model.menuSections = MenuSection.defaults }
                .buttonStyle(.borderless).font(.caption)
        }
    }
}

/// Mic and camera time per app, from the privacy history.
struct PrivacyByApp: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("privacyRange") private var days = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach([1, 7, 30], id: \.self) { d in
                    Button(d == 1 ? "Today" : "\(d) days") { days = d }.buttonStyle(ChipButtonStyle(selected: days == d))
                }
                Spacer(minLength: 0)
            }
            let now = Date()
            let since = days == 1 ? Calendar.current.startOfDay(for: now) : now.addingTimeInterval(-Double(days) * 86_400)
            let rows = model.privacyLog.usage(since: since, now: now)
            if rows.isEmpty {
                Text("No mic or camera use recorded in this time.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows) { u in
                HStack(spacing: 10) {
                    Image(systemName: u.device == .mic ? "mic.fill" : "video.fill").foregroundStyle(Brand.teal).frame(width: 18)
                    Text(u.app).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("\(u.sessions)×").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(Format.duration(u.seconds)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .frame(minWidth: 80, alignment: .trailing)
                }
            }
            Text("Recorded while Keepwatch runs.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Keepwatch's own activity log, newest first, 15 per page.
struct ActivityLogView: View {
    @EnvironmentObject var model: AppModel
    @State private var page = 0
    @State private var confirmClear = false
    static let pageSize = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Everything Keepwatch changed on this Mac. Stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.auditLog.entries.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.auditLog.page(page, size: Self.pageSize)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    Text(e.action).font(.system(size: 12, weight: .semibold))
                    Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            HStack {
                let pages = model.auditLog.pageCount(size: Self.pageSize)
                if pages > 1 {
                    Button("Newer") { page = max(0, page - 1) }.disabled(page == 0)
                    Text("Page \(min(page, pages - 1) + 1) of \(pages)").font(.caption).foregroundStyle(.secondary)
                    Button("Older") { page = min(pages - 1, page + 1) }.disabled(page >= pages - 1)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.auditLog.text(), forType: .string)
                }
                Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([AuditLog.defaultURL()]) }
                Button("Clear…") { confirmClear = true }
            }
            .controlSize(.small)
        }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearAuditLog(); page = 0 }
        } message: { Text("A note that you cleared it stays.") }
    }
}

/// A rounded search box that filters a list as you type.
struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).frame(width: 220, height: 28)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
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
                      subtitle: "Asks GitHub for the latest version. Nothing else is sent.",
                      isOn: $model.autoCheckUpdates)
        }
    }
}

/// The difference between the two ways to stay awake, in two lines.
/// Keeps chat and meeting apps from marking you away.
struct StayActiveRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SwitchRow(icon: "cursorarrow.motionlines", title: "Stay active in chat apps",
                      subtitle: "Slack, Teams and Zoom won't show you as away.",
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
