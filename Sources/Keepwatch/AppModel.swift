import AppKit
import Combine
import Foundation
import KeepwatchCore
import ServiceManagement
import UserNotifications
import os

/// Everything the UI shows and every action it can take. Polls once every two
/// seconds; all system reads are cheap and none of them prompt for permission.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: Published state

    @Published private(set) var mode: KeepAwakeMode = .off
    @Published private(set) var remaining: TimeInterval?
    /// Full length of the current timed session, for the progress ring. Nil if
    /// unknown (a session restored from before a relaunch).
    @Published private(set) var timedLength: TimeInterval?
    @Published private(set) var holding = false
    @Published private(set) var agents: [String: Int] = [:]
    @Published private(set) var agentSessions: [AgentSession] = []
    @Published private(set) var agentActivity: [Int32: AgentActivity] = [:]
    /// Session names by pid (Claude Code only), refreshed every few seconds.
    @Published private(set) var sessionTitles: [Int32: String] = [:]
    @Published private(set) var load = SystemLoad(cpuPercent: nil, memoryPercent: nil)
    @Published private(set) var privacyLog = PrivacyLog.load()
    @Published private(set) var batteryHistory = BatteryHistory.load()
    @Published private(set) var topApps: [AppUsage] = []
    /// Why Keepwatch is holding the Mac awake on its own (plugged in, external display), if it is.
    @Published private(set) var autoReason: String?
    @Published private(set) var privacy = PrivacySnapshot.idle
    @Published private(set) var power: PowerState?
    @Published private(set) var pmset: PMSet.Settings?
    @Published private(set) var lidIntent: LidModeIntent
    @Published private(set) var lidBusy = false
    @Published var banner: Banner?
    @Published private(set) var toggles: [QuickToggle: Bool] = [:]
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var security: [SecurityCheck: SecurityState] = [:]
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    // MARK: Preferences

    @Published var keepDisplayAwake: Bool { didSet { defaults.set(keepDisplayAwake, forKey: "keepDisplayAwake"); apply() } }
    @Published var notifyWhenAgentsFinish: Bool { didSet { defaults.set(notifyWhenAgentsFinish, forKey: "notifyAgents") } }
    @Published var muteMicWhenLidCloses: Bool { didSet { defaults.set(muteMicWhenLidCloses, forKey: "muteOnLid") } }
    @Published var muteMicOnLock: Bool { didSet { defaults.set(muteMicOnLock, forKey: "muteOnLock") } }
    /// A "back in N minutes" countdown, shown in the menu bar.
    @Published private(set) var quickTimer: QuickTimer?
    /// Free disk space, and the big folders (scanned on request).
    @Published private(set) var disk: DiskSpace.Usage?
    @Published var diskWarnGB: Int { didSet { defaults.set(diskWarnGB, forKey: "diskWarnGB") } }
    @Published private(set) var storageSpots: [DiskSpace.Spot] = []
    @Published private(set) var scanningStorage = false
    /// Launch agents and daemons, and which appeared since the last check.
    @Published private(set) var startupItems: [StartupItem] = []
    @Published private(set) var newStartupPaths: Set<String> = []
    @Published var alertNewStartupItems: Bool { didSet { defaults.set(alertNewStartupItems, forKey: "alertNewStartup") } }
    /// Agent time limit in hours (0 = off), and whether to stop or only tell.
    @Published var agentLimitHours: Int { didSet { defaults.set(agentLimitHours, forKey: "agentLimitHours") } }
    @Published var agentLimitStops: Bool { didSet { defaults.set(agentLimitStops, forKey: "agentLimitStops") } }
    private var budgetHandled: Set<Int32> = []
    private var mutedByLock = false
    private var screenLocked = false
    /// Someone connected with Screen Sharing, or a capture in progress.
    @Published private(set) var screenWatchers: [ScreenWatch.Watcher] = []
    /// What happened while you were away; shown once in the menu.
    @Published var awaySummary: AwayLog.Summary?
    private var awayLog = AwayLog()
    /// Every change Keepwatch makes to the Mac or other apps (Settings › Activity log).
    @Published private(set) var auditLog = AuditLog()
    static let logger = Logger(subsystem: "app.keepwatch.Keepwatch", category: "activity")
    @Published var endLidSessionWhenAgentsFinish: Bool { didSet { defaults.set(endLidSessionWhenAgentsFinish, forKey: "lidEndsWithAgents") } }
    @Published var lidHours: Double { didSet { defaults.set(lidHours, forKey: "lidHours") } }
    @Published var lidAllowBattery: Bool { didSet { defaults.set(lidAllowBattery, forKey: "lidBattery") } }
    @Published var lidSleepAtEnabled: Bool { didSet { defaults.set(lidSleepAtEnabled, forKey: "lidSleepAtOn") } }
    @Published var lidSleepAt: Date { didSet { defaults.set(lidSleepAt, forKey: "lidSleepAt") } }
    /// Which tiles the dashboard summary shows, in order.
    @Published var summaryTiles: [SummaryTile] {
        didSet { defaults.set(summaryTiles.map(\.rawValue), forKey: "summaryTiles") }
    }
    /// The last custom keep-awake length, so "Custom" opens where you left it.
    /// Notify when an agent goes quiet after working (done, or waiting for you).
    @Published var notifyAgentWaiting: Bool { didSet { defaults.set(notifyAgentWaiting, forKey: "notifyAgentWaiting") } }
    /// Stop an ordinary keep-awake when unplugged.
    @Published var stopAwakeOnBattery: Bool { didSet { defaults.set(stopAwakeOnBattery, forKey: "stopAwakeOnBattery") } }
    /// Stop an ordinary keep-awake at low battery.
    @Published var stopAwakeOnLowBattery: Bool { didSet { defaults.set(stopAwakeOnLowBattery, forKey: "stopAwakeLow") } }
    /// Keep awake automatically while plugged in / while an external display is connected.
    @Published var autoWhilePlugged: Bool { didSet { defaults.set(autoWhilePlugged, forKey: "autoPlugged"); tick() } }
    @Published var autoWhileDisplay: Bool { didSet { defaults.set(autoWhileDisplay, forKey: "autoDisplay"); tick() } }
    /// Play a sound with Keepwatch's notifications.
    @Published var notificationSound: Bool { didSet { defaults.set(notificationSound, forKey: "sound") } }
    /// ⌃⌥⌘K starts or stops keep-awake from anywhere.
    @Published var hotkeyEnabled: Bool { didSet { defaults.set(hotkeyEnabled, forKey: "hotkey"); Hotkey.shared.setEnabled(hotkeyEnabled) } }
    /// Notify when the mic or camera turns on.
    @Published var alertOnMicCamera: Bool { didSet { defaults.set(alertOnMicCamera, forKey: "alertMicCamera") } }
    /// The keep-awake buttons shown in the menu (the rest are under "More").
    /// Which parts the menu-bar window shows.
    @Published var menuSections: [MenuSection] {
        didSet { defaults.set(menuSections.map(\.rawValue), forKey: "menuSections") }
    }
    @Published var menuPresets: [AwakePreset] {
        didSet { defaults.set(menuPresets.map(\.rawValue), forKey: "menuPresets") }
    }
    /// Opt-in: nudge the pointer when idle so chat apps keep you active.
    @Published var stayActive: Bool {
        didSet {
            defaults.set(stayActive, forKey: "stayActive")
            if stayActive != oldValue { audit(stayActive ? "Stay active turned on" : "Stay active turned off") }
            if stayActive { requestAccessibility() }
        }
    }
    @Published var stayActiveMinutes: Int { didSet { defaults.set(stayActiveMinutes, forKey: "stayActiveMinutes") } }
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private var nudgedThisIdle = false
    /// Opt-in: check GitHub for a newer version once a day.
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    @Published private(set) var availableUpdate: UpdateCheck.Release?
    @Published private(set) var updateStatus: String?
    @Published private(set) var updateInstalling = false
    @Published var customAmount: Double { didSet { defaults.set(customAmount, forKey: "customAmount") } }
    @Published var customUnit: AwakeDuration.Unit { didSet { defaults.set(customUnit.rawValue, forKey: "customUnit") } }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var action: BannerAction?
    }

    enum BannerAction: Equatable { case restoreSleep, openAccessibility }

    // MARK: Internals

    private let defaults = UserDefaults.standard
    private var engine = KeepAwakeEngine()
    private let matcher = AgentMatcher()
    private var systemAssertion = PowerAssertion(kind: .system, name: "Keepwatch: keeping your Mac awake")
    private var displayAssertion = PowerAssertion(kind: .display, name: "Keepwatch: keeping the display on")
    private var timer: Timer?
    /// Set by `loadDemoData`; live refreshes are ignored from then on.
    private var demo = false
    private var tickCount = 0
    private var activityTracker = AgentActivityTracker()
    private var loadSampler = SystemLoadSampler()
    private var lastLidClosed: Bool?
    private var mutedByLid = false
    private let policy = LidModePolicy()

    let stopFile: URL = LidWatchdog.defaultStopFile()

    init() {
        keepDisplayAwake = defaults.bool(forKey: "keepDisplayAwake")
        notifyWhenAgentsFinish = defaults.object(forKey: "notifyAgents") as? Bool ?? true
        muteMicWhenLidCloses = defaults.bool(forKey: "muteOnLid")
        muteMicOnLock = defaults.bool(forKey: "muteOnLock")
        diskWarnGB = defaults.object(forKey: "diskWarnGB") as? Int ?? 10
        alertNewStartupItems = defaults.object(forKey: "alertNewStartup") as? Bool ?? true
        agentLimitHours = defaults.integer(forKey: "agentLimitHours")
        agentLimitStops = defaults.bool(forKey: "agentLimitStops")
        endLidSessionWhenAgentsFinish = defaults.object(forKey: "lidEndsWithAgents") as? Bool ?? true
        lidHours = defaults.object(forKey: "lidHours") as? Double ?? 3
        lidAllowBattery = defaults.object(forKey: "lidBattery") as? Bool ?? true // on battery above 20% by default
        lidSleepAtEnabled = defaults.bool(forKey: "lidSleepAtOn")
        lidSleepAt = defaults.object(forKey: "lidSleepAt") as? Date
            ?? LidSessionPlan.nextTime(hour: 1, minute: 0, after: Date()) ?? Date()
        notifyAgentWaiting = defaults.object(forKey: "notifyAgentWaiting") as? Bool ?? true
        stopAwakeOnBattery = defaults.bool(forKey: "stopAwakeOnBattery")
        stopAwakeOnLowBattery = defaults.object(forKey: "stopAwakeLow") as? Bool ?? true
        hotkeyEnabled = defaults.object(forKey: "hotkey") as? Bool ?? true
        autoWhilePlugged = defaults.bool(forKey: "autoPlugged")
        autoWhileDisplay = defaults.bool(forKey: "autoDisplay")
        notificationSound = defaults.object(forKey: "sound") as? Bool ?? true
        alertOnMicCamera = defaults.object(forKey: "alertMicCamera") as? Bool ?? true
        // "micCamera" was one tile before 0.2; it is now two.
        let savedTiles = (UserDefaults.standard.stringArray(forKey: "summaryTiles") ?? [])
            .flatMap { $0 == "micCamera" ? ["mic", "camera"] : [$0] }
            .compactMap(SummaryTile.init(rawValue:))
        summaryTiles = savedTiles.isEmpty ? SummaryTile.defaults : Array(savedTiles.prefix(SummaryTile.maxShown))
        menuPresets = AwakePreset.menuSelection(from: defaults.stringArray(forKey: "menuPresets"))
        menuSections = MenuSection.selection(from: defaults.stringArray(forKey: "menuSections"))
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        stayActive = defaults.bool(forKey: "stayActive")
        stayActiveMinutes = defaults.object(forKey: "stayActiveMinutes") as? Int ?? StayActive.defaultIdleMinutes
        customAmount = defaults.object(forKey: "customAmount") as? Double ?? 2
        customUnit = (defaults.string(forKey: "customUnit")).flatMap(AwakeDuration.Unit.init(rawValue:)) ?? .hours
        lidIntent = (defaults.data(forKey: "lidIntent")).flatMap { try? JSONDecoder().decode(LidModeIntent.self, from: $0) } ?? .off
        if let data = defaults.data(forKey: "mode"), let saved = try? JSONDecoder().decode(KeepAwakeMode.self, from: data) {
            // A timer that ran out while we were closed comes back as off.
            if case .until(let end) = saved, end <= Date() { } else { engine.set(saved) }
        }
        mode = engine.mode
        refreshSlow()
        Hotkey.shared.setEnabled(hotkeyEnabled)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(LidRequest.notificationName),
                                                            object: nil, queue: .main) { note in
            let hours = LidRequest.hours(from: note.userInfo)
            Task { @MainActor in AppModel.shared.handleLidRequest(hours: hours) }
        }
        if !demo { auditLog = AuditLog.load() }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.userLeft() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.screensWoke() }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.screenLockChanged(locked: true) }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.screenLockChanged(locked: false) }
        }
        checkLidSessionOnLaunch()
        if stayActive && !AXIsProcessTrusted() {
            banner = Banner(text: "Stay active needs Accessibility. Already on? Turn it off and on again.",
                            action: .openAccessibility)
            requestAccessibility()
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Keep awake

    func setMode(_ newMode: KeepAwakeMode) {
        if newMode != mode { audit("Keep awake", Self.describe(newMode)) }
        if case .until(let end) = newMode { timedLength = end.timeIntervalSinceNow } else { timedLength = nil }
        engine.set(newMode)
        mode = engine.mode
        if let data = try? JSONEncoder().encode(newMode) { defaults.set(data, forKey: "mode") }
        tick()
    }

    func keepAwake(for seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        setMode(.until(Date().addingTimeInterval(min(seconds, AwakeDuration.maxSeconds))))
    }

    /// Keep awake for the custom amount and unit chosen in the menu.
    func keepAwakeCustom() {
        if let seconds = AwakeDuration.seconds(customAmount, customUnit) { keepAwake(for: seconds) }
    }

    /// Keep awake until a clock time (today, or tomorrow if it has passed).
    func keepAwake(until date: Date) {
        let now = Date()
        var end = date
        if end <= now {
            let hm = Calendar.current.dateComponents([.hour, .minute], from: date)
            guard let next = Calendar.current.nextDate(after: now, matching: DateComponents(hour: hm.hour, minute: hm.minute, second: 0),
                                                       matchingPolicy: .nextTime) else { return }
            end = next
        }
        keepAwake(for: end.timeIntervalSince(now))
    }

    /// The preset length the current timed session was started with, if any.
    var timedPreset: TimeInterval? {
        guard case .until = mode, let timedLength else { return nil }
        return timedLength
    }

    private func apply() {
        if holding {
            systemAssertion.hold()
            if keepDisplayAwake { displayAssertion.hold() } else { displayAssertion.release() }
        } else {
            systemAssertion.release()
            displayAssertion.release()
        }
    }

    func tick() {
        tickCount += 1
        let now = Date()
        let processes = ProcessList.snapshot(wantArguments: matcher.isCandidate)
        let running = matcher.runningAgents(in: processes)
        if running != agents { agents = running }
        if tickCount % 2 == 0 { updateScreenWatchers(Set(processes.map(\.name))) }
        let sessions = matcher.sessions(in: processes)
        if sessions != agentSessions { agentSessions = sessions }
        trackAgentActivity(now: now)
        let decision = engine.tick(now: now, agents: Set(agents.keys))
        if engine.mode != mode { mode = engine.mode }
        if decision.remaining != remaining { remaining = decision.remaining }
        let auto = AutoAwake(whilePluggedIn: autoWhilePlugged, whileExternalDisplay: autoWhileDisplay)
            .reason(onBattery: power?.onBattery, screens: NSScreen.screens.count)
        if auto != autoReason { autoReason = auto }
        let hold = decision.holdAssertion || auto != nil
        if hold != holding { holding = hold }
        apply()
        for event in decision.events { handle(event) }

        guardKeepAwake()
        keepActiveIfIdle()
        checkQuickTimer(now: now)
        if tickCount % 15 == 0 { checkAgentBudget(now: now) }
        let l = loadSampler.sample()
        if l != load { load = l }

        let before = privacy
        let snap = PrivacyMonitor.snapshot()
        if snap != privacy { privacy = snap }
        if tickCount > 1 { alertIfPrivacyChanged(from: before) }
        if tickCount % 5 == 1 { refreshSlow() }
        if tickCount % 30 == 1 { refreshSecurity(); refreshStartupItems() }
        handleLidTransition()
        superviseLidSession(now: now)
    }

    private func refreshSessionTitles() {
        guard !demo else { return }
        let sessions = agentSessions
        Task.detached(priority: .utility) { [weak self] in
            let titles = SessionTitles.titles(for: sessions)
            await self?.setSessionTitles(titles)
        }
    }

    private func setSessionTitles(_ titles: [Int32: String]) { if !demo, titles != sessionTitles { sessionTitles = titles } }

    private func refreshSlow() {
        refreshSessionTitles()
        if autoCheckUpdates, !demo,
           UpdateCheck.isDue(lastCheck: defaults.object(forKey: "lastUpdateCheck") as? Date, now: Date()) {
            checkForUpdates(userAsked: false)
        }
        let p = SystemState.power()
        if p != power { power = p }
        checkDisk()
        if batteryHistory.record(health: p.healthPercent, cycles: p.cycleCount, on: Date()) { batteryHistory.save() }
        pmset = SystemState.pmsetSettings()
        for t in QuickToggle.allCases where toggles[t] == nil { toggles[t] = t.read() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func handle(_ event: KeepAwakeEngine.Event) {
        switch event {
        case .agentFinished(let name):
            awayLog.record(.init(date: Date(), icon: "checkmark.circle.fill", text: "\(name) finished"))
            if notifyWhenAgentsFinish { notify("\(name) finished", "No \(name) process is running any more.") }
        case .timerEnded:
            awayLog.record(.init(date: Date(), icon: "moon.zzz.fill", text: "Keep-awake time ran out"))
            notify("Keep-awake ended", "Your Mac can sleep normally again.")
        case .agentsIdle:
            break // lid sessions track agents themselves in superviseLidSession
        }
    }

    // MARK: Lid close

    private func handleLidTransition() {
        let closed = power?.lidClosed ?? SystemState.lidClosed()
        defer { lastLidClosed = closed }
        guard let closed, let previous = lastLidClosed, closed != previous else { return }
        if closed, muteMicWhenLidCloses, privacy.micMuted == false {
            mutedByLid = PrivacyMonitor.setMicMuted(true)
            if mutedByLid { audit("Microphone muted", "lid closed") }
        } else if !closed, mutedByLid {
            PrivacyMonitor.setMicMuted(false)
            mutedByLid = false
        }
    }

    // MARK: Mic, camera and security

    private func alertIfPrivacyChanged(from before: PrivacySnapshot) {
        logPrivacyChanges(from: before)
        guard alertOnMicCamera else { return }
        if privacy.micInUse && !before.micInUse {
            let who = privacy.micUsers.map { appName(for: $0) }.joined(separator: ", ")
            notify("Microphone turned on", who.isEmpty ? "An app started using your microphone." : "In use by \(who).")
        }
        if privacy.cameraInUse && !before.cameraInUse {
            notify("Camera turned on", "An app started using your camera. Not you? Open the Camera list to remove its access.",
                   category: AppModel.cameraCategory)
        }
    }

    private func logPrivacyChanges(from before: PrivacySnapshot) {
        var changed = false
        if privacy.micInUse != before.micInUse {
            privacyLog.record(PrivacyEvent(date: Date(), device: .mic, on: privacy.micInUse,
                                           apps: privacy.micUsers.map { appName(for: $0) }))
            changed = true
        }
        if privacy.cameraInUse != before.cameraInUse {
            privacyLog.record(PrivacyEvent(date: Date(), device: .camera, on: privacy.cameraInUse))
            changed = true
        }
        if changed { privacyLog.save() }
    }

    func clearPrivacyLog() {
        privacyLog.clear()
        privacyLog.save()
    }

    // MARK: Agent activity and battery guard

    private func trackAgentActivity(now: Date) {
        var cpu: [Int32: TimeInterval] = [:]
        for s in agentSessions { if let t = ProcessList.cpuSeconds(of: s.pid) { cpu[s.pid] = t } }
        let quiet = activityTracker.update(cpu: cpu, now: now)
        let states = activityTracker.states.mapValues(\.activity)
        if states != agentActivity { agentActivity = states }
        guard notifyAgentWaiting else { return }
        for pid in quiet {
            guard let s = agentSessions.first(where: { $0.pid == pid }) else { continue }
            let name = sessionTitles[pid]
            awayLog.record(.init(date: now, icon: "hourglass", text: "\(name.map { "“\($0)”" } ?? s.agent) went quiet"))
            let host = HostApp.host(of: pid) { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
            let hostName = host.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
            notify(name.map { "“\($0)” is waiting" } ?? "\(s.agent) went quiet",
                   "\(s.agent) in \(s.folderName ?? "a session"). It may be done, or waiting for your answer."
                       + (hostName.map { " Click to open \($0)." } ?? ""),
                   category: Self.agentCategory, userInfo: host.map { ["hostPID": Int($0)] } ?? [:])
        }
    }

    private func guardKeepAwake() {
        guard mode != .off, !lidIntent.enabled, let p = power else { return }
        let g = KeepAwakeGuard(stopOnBattery: stopAwakeOnBattery, stopBelowPercent: stopAwakeOnLowBattery ? 15 : 0)
        guard let why = g.reason(onBattery: p.onBattery, batteryPercent: p.batteryPercent) else { return }
        setMode(.off)
        notify("Keep-awake stopped", "Because \(why). Your Mac can sleep normally.")
    }

    /// The ⌃⌥⌘K shortcut: keep awake until turned off, or stop.
    func toggleFromHotkey() {
        setMode(mode == .off ? .indefinite : .off)
        notify(mode == .off ? "Keep-awake off" : "Keeping your Mac awake", mode == .off ? "Your Mac sleeps as usual." : "Until you press ⌃⌥⌘K again.")
    }

    /// Reads the security checks off the main thread; each one runs a small system tool.
    func refreshSecurity() {
        Task.detached(priority: .utility) { [weak self] in
            var states: [SecurityCheck: SecurityState] = [:]
            for check in SecurityCheck.allCases { states[check] = check.read() }
            await self?.setSecurity(states)
        }
    }

    /// Synchronous read, for snapshot rendering only.
    func refreshSecurityNow() {
        var states: [SecurityCheck: SecurityState] = [:]
        for check in SecurityCheck.allCases { states[check] = check.read() }
        security = states
    }

    private func setSecurity(_ states: [SecurityCheck: SecurityState]) { if !demo { security = states } }

    func open(_ check: SecurityCheck) {
        if let url = check.settingsURL { NSWorkspace.shared.open(url) }
    }

    nonisolated static let cameraCategory = "camera-on"
    nonisolated static let agentCategory = "agent-waiting"
    nonisolated static let screenCategory = "screen-watched"
    nonisolated static let startupCategory = "startup-item"
    nonisolated static let openCameraAction = "open-camera-settings"

    /// Takes camera permission back from every app (`tccutil reset Camera`), so
    /// each one has to ask again. Apps already open keep access until they quit.
    func resetCameraPermissions() {
        let ok = (SystemState.run("/usr/bin/tccutil", ["reset", "Camera"]) ?? "").contains("Successfully")
        audit("Camera access reset for every app", ok ? "done" : "failed")
        notify(ok ? "Camera access reset" : "Couldn't reset camera access",
               ok ? "Every app now has to ask before using the camera. Apps that are open keep access until you quit them."
                  : "Open the Camera list in System Settings to remove apps by hand.")
    }

    func toggleTile(_ tile: SummaryTile) {
        if let i = summaryTiles.firstIndex(of: tile) {
            if summaryTiles.count > 1 { summaryTiles.remove(at: i) }
        } else if summaryTiles.count < SummaryTile.maxShown {
            summaryTiles.append(tile)
        }
    }

    func setMicMuted(_ muted: Bool) {
        guard privacy.micMuted != nil, privacy.micMuted != muted else { return }
        toggleMicMute()
    }

    func toggleMicMute() {
        guard let muted = privacy.micMuted else { return }
        if PrivacyMonitor.setMicMuted(!muted) {
            mutedByLid = false
            mutedByLock = false
            audit(muted ? "Microphone unmuted" : "Microphone muted", "you clicked")
        }
        privacy = PrivacyMonitor.snapshot()
    }

    // MARK: Lid session

    var lidSessionPlan: LidSessionPlan {
        LidSessionPlan(afterLidClosed: lidHours > 0 ? lidHours * 3600 : nil,
                       sleepAt: lidSleepAtEnabled ? lidSleepAt : nil,
                       allowOnBattery: lidAllowBattery, minBatteryPercent: 20, sleepWhenDone: true)
    }

    /// `keepwatch lid start` from the CLI. Starting still goes through the
    /// macOS password prompt, so only the person at the Mac can allow it.
    func handleLidRequest(hours: Double?) {
        guard !lidIntent.enabled, !lidBusy else { return }
        if let hours { lidHours = hours }
        NSApp.activate(ignoringOtherApps: true)
        startLidSession()
    }

    func startLidSession() {
        if let p = power, p.onBattery {
            guard lidAllowBattery else { banner = Banner(text: "Plug in, or turn on “Allow on battery”.", action: nil); return }
            if let pct = p.batteryPercent, pct <= lidSessionPlan.minBatteryPercent {
                banner = Banner(text: "Battery is at \(pct)%. Plug in to start a lid session.", action: nil)
                return
            }
        }
        let plan = lidSessionPlan
        let now = Date()
        let command: String
        do {
            command = try LidWatchdog.startCommand(plan: plan, stopFile: stopFile.path, now: now)
        } catch {
            banner = Banner(text: "Couldn't prepare the lid session (\(error)).", action: nil)
            return
        }
        // Save intent BEFORE changing the system, so a crash mid-way is caught on next launch.
        saveIntent(LidModeIntent(enabled: true, since: now,
                                 expires: now.addingTimeInterval(TimeInterval(LidWatchdog.deadlineSeconds(plan, now: now)))))
        let script = PMSet.adminAppleScript(for: command, prompt: "Keepwatch needs your password to keep your Mac awake with the lid closed. Sleep turns back on automatically.")
        lidBusy = true
        runAdmin(script) { [weak self] ok, message in
            guard let self else { return }
            self.lidBusy = false
            self.audit(ok ? "Lid session started" : "Lid session not started",
                       ok ? "sleep after \(Format.duration(plan.afterLidClosed ?? 0)) closed, at most until \(Date().addingTimeInterval(TimeInterval(LidWatchdog.deadlineSeconds(plan, now: now))).formatted(date: .omitted, time: .shortened))"
                          : message)
            if !ok {
                self.saveIntent(.off)
                if !message.contains("-128") { self.banner = Banner(text: "Lid session not started: \(message)", action: nil) }
            }
            self.pmset = SystemState.pmsetSettings()
        }
    }

    /// Ask the watchdog to restore sleep. No password needed.
    func endLidSession(reason: String) {
        // Only the watchdog reads the stop file. If it is gone, the stop file
        // would do nothing, so turn sleep back on directly (password prompt).
        guard watchdogAlive() else { restoreSleepNow(); return }
        audit("Lid session end requested", reason)
        FileManager.default.createFile(atPath: stopFile.path, contents: Data(reason.utf8))
        lidStopRequestedAt = Date()
        notify("Lid session ending", "Sleep turns back on within 30 seconds (\(reason)).")
    }

    /// True after End was pressed and before sleep is back on.
    var lidEnding: Bool { lidStopRequestedAt != nil }

    /// For a setting Keepwatch didn't make, or one left over after a reboot.
    func restoreSleepNow() {
        let script = PMSet.adminAppleScript(for: LidWatchdog.stopNowCommand(), prompt: "Keepwatch needs your password to turn sleep back on.")
        runAdmin(script) { [weak self] ok, _ in
            guard let self else { return }
            if ok { self.saveIntent(.off); self.banner = nil }
            self.audit(ok ? "Sleep turned back on" : "Turning sleep back on failed", "with your password")
            self.pmset = SystemState.pmsetSettings()
        }
    }

    private func checkLidSessionOnLaunch() {
        let action = LidModeGuard.onLaunch(systemSleepDisabled: pmset?.sleepDisabled ?? false,
                                           intent: lidIntent, watchdogAlive: watchdogAlive(),
                                           bootTime: BootTime.current())
        switch action {
        case .none:
            if lidIntent.enabled && !(pmset?.sleepDisabled ?? false) { saveIntent(.off) }
        case .restore:
            banner = Banner(text: "Sleep is still off from an earlier lid session. Turn it back on?",
                            action: .restoreSleep)
        case .askAboutForeignSetting:
            banner = Banner(text: "Sleep is off, but not by Keepwatch. Your Mac won't sleep.",
                            action: .restoreSleep)
        }
    }

    /// Agents seen during the current lid session, and when last seen.
    private var lidAgentLastSeen: Date?
    @Published private(set) var lidStopRequestedAt: Date?
    /// Whether the session's watchdog was running at the last check (nil: no session).
    @Published private(set) var lidWatchdogRunning: Bool?
    private var lidRescuePrompted = false
    private static let lidAgentGrace: TimeInterval = 120

    private func superviseLidSession(now: Date) {
        guard lidIntent.enabled, !lidBusy else { lidAgentLastSeen = nil; return }
        rescueLidSessionIfStuck(now: now)
        if !agents.isEmpty { lidAgentLastSeen = now }
        if endLidSessionWhenAgentsFinish, agents.isEmpty, let seen = lidAgentLastSeen,
           now.timeIntervalSince(seen) >= Self.lidAgentGrace, !FileManager.default.fileExists(atPath: stopFile.path) {
            lidAgentLastSeen = nil
            endLidSession(reason: "all agents finished")
        }
        if let pm = pmset, !pm.sleepDisabled, tickCount % 5 == 1 {
            saveIntent(.off)
            notify("Lid session ended", "Your Mac sleeps normally again.")
            return
        }
        let action = LidModeGuard.onTick(intent: lidIntent, policy: policy, now: now,
                                         batteryPercent: power?.batteryPercent, onBattery: power?.onBattery ?? false,
                                         thermal: .init(ProcessInfo.processInfo.thermalState))
        if case .restore(let reason) = action, reason == .thermal, !FileManager.default.fileExists(atPath: stopFile.path) {
            endLidSession(reason: reason.rawValue)
        }
    }

    /// If the watchdog is gone or not answering while sleep is still off, the
    /// Mac would never sleep again. Ask for the password once to fix it, and
    /// leave a banner in case the prompt is dismissed.
    private func rescueLidSessionIfStuck(now: Date) {
        guard tickCount % 5 == 0, let pm = pmset else { return }
        let alive = watchdogAlive()
        if alive != lidWatchdogRunning { lidWatchdogRunning = alive }
        guard !lidRescuePrompted else { return }
        let action = LidModeGuard.supervise(intent: lidIntent, systemSleepDisabled: pm.sleepDisabled,
                                            watchdogAlive: alive, stopRequestedAt: lidStopRequestedAt, now: now)
        guard case .restore = action else { return }
        lidRescuePrompted = true
        banner = Banner(text: "The lid session stopped. Turn sleep back on.",
                        action: .restoreSleep)
        notify("Your Mac can't sleep", "The lid session stopped working. Type your password to turn sleep back on.")
        restoreSleepNow()
    }

    private func watchdogAlive() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", stopFile.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func saveIntent(_ intent: LidModeIntent) {
        if lidIntent.enabled && !intent.enabled {
            awayLog.record(.init(date: Date(), icon: "laptopcomputer", text: "Lid session ended; sleep is back on"))
        }
        lidIntent = intent
        if !intent.enabled { lidStopRequestedAt = nil; lidRescuePrompted = false; lidWatchdogRunning = nil }
        if let data = try? JSONEncoder().encode(intent) { defaults.set(data, forKey: "lidIntent") }
    }

    /// Runs an AppleScript through osascript off the main thread, so the
    /// password dialog never freezes the menu.
    private func runAdmin(_ script: String, completion: @escaping @MainActor (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            var ok = false
            var message = ""
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
                message = String(data: err.fileHandleForReading.readDataToEndOfFile().prefix(2000), encoding: .utf8) ?? ""
            } catch { message = error.localizedDescription }
            Task { @MainActor in completion(ok, message.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    // MARK: Ports

    /// Reads everything again now, for the refresh button.
    func refreshNow() {
        refreshSlow()
        tick()
        refreshSecurity()
        refreshPorts()
        refreshTopApps()
    }

    func refreshPorts() { if !demo { ports = ListeningPorts.current() } }

    /// Quits one agent session, after the UI asked the user to confirm.
    func stopAgent(_ session: AgentSession) {
        audit("Stopped agent session", "\(session.agent) in \(session.folderName ?? "unknown folder") (pid \(session.pid))")
        _ = matcher.stop(session, current: ProcessList.snapshot(wantArguments: matcher.isCandidate))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
    }

    func refreshTopApps() {
        Task.detached(priority: .utility) { [weak self] in
            let apps = TopApps.current(limit: 60)
            await self?.setTopApps(apps)
        }
    }

    /// Synchronous read, for snapshot rendering only.
    func refreshTopAppsNow() { if !demo { topApps = TopApps.current(limit: 60) } }

    /// Replaces live readings with `DemoData` for `--render-snapshots DIR --demo`.
    /// Stops polling so nothing real comes back, and saves nothing.
    func loadDemoData() {
        demo = true
        timer?.invalidate()
        timer = nil
        let now = Date()
        let left: TimeInterval = 2 * 3_600 + 41 * 60
        mode = .until(now.addingTimeInterval(left))
        awaySummary = DemoData.awaySummary(now: now)
        auditLog = DemoData.auditLog(now: now)
        remaining = left
        timedLength = 3 * 3_600
        holding = true
        autoReason = nil
        agentSessions = DemoData.agentSessions(now: now)
        agents = Dictionary(grouping: agentSessions, by: \.agent).mapValues(\.count)
        agentActivity = DemoData.activity
        sessionTitles = DemoData.titles
        privacy = DemoData.privacy
        privacyLog = DemoData.privacyLog(now: now)
        power = DemoData.power
        pmset = DemoData.pmset
        load = DemoData.load
        batteryHistory = DemoData.batteryHistory(now: now)
        ports = DemoData.ports
        topApps = DemoData.apps
        security = DemoData.security
        disk = DemoData.disk
        storageSpots = DemoData.storageSpots
        startupItems = DemoData.startupItems
        newStartupPaths = [DemoData.startupItems[0].path]
        quickTimer = QuickTimer(minutes: 25, now: now.addingTimeInterval(-7 * 60), keepAwake: false)
        lidIntent = .off
        banner = nil
    }

    private func setTopApps(_ apps: [AppUsage]) { if !demo, apps != topApps { topApps = apps } }

    /// Quits an app politely (like ⌘Q), after the UI confirmed. Plain tools get SIGTERM.
    /// Never macOS's own processes or Keepwatch itself.
    func quitApp(_ app: AppUsage) {
        guard !app.isSystem else { return }
        audit("Quit app", app.name)
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.path }
        if !running.isEmpty {
            for r in running where r.processIdentifier != getpid() { r.terminate() }
        } else {
            for pid in app.pids { _ = ListeningPorts.stop(pid: pid) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshTopApps() }
    }

    func stopProcess(_ port: ListeningPort) {
        audit("Stopped process", "\(port.process) on port \(port.port) (pid \(port.pid))")
        ListeningPorts.stop(pid: port.pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPorts() }
    }

    // MARK: Command-line tool

    func installCLI() {
        audit("Installed the keepwatch command")
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/keepwatch-cli").path
        switch CLIInstaller.install(cliPath: cli) {
        case .installed(let link), .alreadyInstalled(let link):
            banner = Banner(text: "Installed: run `keepwatch help` in Terminal (\(link)).", action: nil)
        case .noWritableDirectory:
            banner = Banner(text: "No writable bin folder found. Run: ln -s \"\(cli)\" /usr/local/bin/keepwatch", action: nil)
        case .failed(let message):
            banner = Banner(text: "Couldn't install the command: \(message)", action: nil)
        }
    }

    // MARK: Toggles, login item, panes

    func setToggle(_ t: QuickToggle, _ value: Bool) {
        audit("Mac tweak", "\(t.title): \(value ? "on" : "off")")
        t.write(value)
        toggles[t] = t.read()
    }

    func setLaunchAtLogin(_ on: Bool) {
        audit(on ? "Open at login turned on" : "Open at login turned off")
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            banner = Banner(text: "Couldn't change Launch at Login: \(error.localizedDescription)", action: nil)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func open(_ pane: PrivacyPane) {
        if let url = pane.url { NSWorkspace.shared.open(url) }
    }

    func appName(for user: MicUser) -> String {
        if let app = NSRunningApplication(processIdentifier: user.pid), let name = app.localizedName { return name }
        if let id = user.bundleID { return id }
        return "pid \(user.pid)"
    }

    /// Set by the menu-bar label, which is always on screen and so always has
    /// SwiftUI's openWindow action available.
    var openDashboardAction: (() -> Void)?

    func showDashboard() {
        openDashboardAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func showDashboard(tab: DashboardTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: "dashboardTab")
        showDashboard()
    }

    /// Asks macOS to list Keepwatch under Accessibility (only when Stay active is turned on).
    func requestAccessibility() {
        if !AXIsProcessTrusted() { audit("Asked macOS for Accessibility", "for Stay active") }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    private func keepActiveIfIdle() {
        guard stayActive else { return }
        if tickCount % 5 == 0 {
            let trusted = AXIsProcessTrusted()
            if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
            if trusted, banner?.action == .openAccessibility { banner = nil }
        }
        let idle = StayActive.idleSeconds()
        if let idle, idle < 5 { nudgedThisIdle = false }
        guard !nudgedThisIdle,
              StayActive.shouldNudge(enabled: stayActive, trusted: accessibilityTrusted, lidSession: lidIntent.enabled,
                                     idleSeconds: idle, idleMinutes: stayActiveMinutes) else { return }
        // One nudge resets the idle time; the flag only guards a nudge macOS ignored.
        nudgedThisIdle = !StayActive.nudge()
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// One request to GitHub's latest-release API; never downloads anything.
    func checkForUpdates(userAsked: Bool) {
        defaults.set(Date(), forKey: "lastUpdateCheck")
        if userAsked { updateStatus = "Checking…" }
        Task { @MainActor in
            guard let latest = await UpdateCheck.fetchLatest() else {
                if userAsked { updateStatus = "Couldn't reach GitHub. Try again later." }
                return
            }
            if UpdateCheck.isNewer(latest.version, than: Self.currentVersion) {
                let isNew = availableUpdate != latest
                availableUpdate = latest
                updateStatus = "Keepwatch \(latest.version) is available."
                if isNew || userAsked {
                    notify("Keepwatch \(latest.version) is available", "Open Keepwatch › Settings to install it.")
                }
            } else {
                availableUpdate = nil
                updateStatus = userAsked ? "You have the latest version (\(Self.currentVersion))." : nil
            }
        }
    }

    /// Downloads the offered release, checks its checksum, signature and
    /// notarization, swaps it in (old app to the Trash) and relaunches.
    func installUpdate() {
        guard let release = availableUpdate, !updateInstalling else { return }
        guard !lidIntent.enabled else {
            updateStatus = "Finish the lid session first; updating restarts Keepwatch."
            return
        }
        let installed = Bundle.main.bundleURL
        guard installed.pathExtension == "app" else { updateStatus = "Only the installed app can update itself."; return }
        updateInstalling = true
        updateStatus = "Downloading Keepwatch \(release.version)…"
        Task { @MainActor in
            let failure = await UpdateInstaller.install(release, over: installed, current: Self.currentVersion)
            updateInstalling = false
            audit(failure == nil ? "Update installed" : "Update not installed",
                  failure.map { "\(release.version): \($0)" } ?? "\(Self.currentVersion) → \(release.version)")
            if let failure {
                updateStatus = "\(failure) Nothing was changed; you can download it from the release page."
                return
            }
            updateStatus = "Installed. Relaunching…"
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", installed.path]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
    }

    func keepAwake(_ preset: AwakePreset) {
        if let seconds = preset.seconds { keepAwake(for: seconds) } else { setMode(.indefinite) }
    }

    static let websiteURL = URL(string: "https://agentskilldeck.github.io/keepwatch/")
    static let sourceURL = URL(string: "https://github.com/AgentSkillDeck/keepwatch")

    // MARK: URL commands

    func perform(_ command: URLCommand) {
        switch command {
        case .awake(let minutes): keepAwake(for: TimeInterval(minutes) * 60)
        case .awakeIndefinitely: setMode(.indefinite)
        case .awakeWhileAgentsRun: setMode(.whileAgentsRun(grace: 120))
        case .awakeOff: setMode(.off)
        case .micMute(let muted):
            PrivacyMonitor.setMicMuted(muted)
            privacy = PrivacyMonitor.snapshot()
        case .endLidSession: if lidIntent.enabled { endLidSession(reason: "requested by a shortcut") }
        case .dashboard: showDashboard()
        }
    }

    // MARK: Notifications

    private var notificationsAsked = false

    private func notify(_ title: String, _ body: String, category: String? = nil, userInfo: [String: Int] = [:]) {
        guard Bundle.main.bundleIdentifier != nil else { return } // not running from an .app
        let center = UNUserNotificationCenter.current()
        let sound = notificationSound
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let category { content.categoryIdentifier = category }
            content.userInfo = userInfo
            if sound { content.sound = .default }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if notificationsAsked { send(); return }
        notificationsAsked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
    }

    // MARK: Quick timer

    func startQuickTimer(minutes: Int) {
        let now = Date()
        // Keep the Mac awake for the timer, unless something already does.
        guard let timer = QuickTimer(minutes: minutes, now: now, keepAwake: mode == .off && !lidIntent.enabled) else { return }
        if timer.keptAwake { keepAwake(for: TimeInterval(minutes) * 60) }
        quickTimer = timer
    }

    func cancelQuickTimer() {
        if let t = quickTimer, t.keptAwake, case .until = mode { setMode(.off) }
        quickTimer = nil
    }

    private func checkQuickTimer(now: Date) {
        guard !demo, let t = quickTimer, t.isDone(at: now) else { return }
        quickTimer = nil
        notify("Time's up", "Your \(t.minutes)-minute timer has ended.")
    }

    // MARK: Disk space

    private func checkDisk() {
        guard !demo, let usage = DiskSpace.usage() else { return }
        if usage != disk { disk = usage }
        let last = defaults.object(forKey: "lastDiskWarning") as? Date
        if DiskSpace.shouldWarn(available: usage.available, thresholdGB: diskWarnGB, lastWarned: last, now: Date()) {
            defaults.set(Date(), forKey: "lastDiskWarning")
            notify("Disk almost full", "\(ByteCountFormatter.string(fromByteCount: usage.available, countStyle: .file)) left. Open Keepwatch › Apps › Storage to see what's big.")
        }
    }

    func scanStorage() {
        guard !scanningStorage, !demo else { return }
        scanningStorage = true
        Task.detached(priority: .utility) { [weak self] in
            let spots = DiskSpace.spots()
            await self?.setStorageSpots(spots)
        }
    }

    private func setStorageSpots(_ spots: [DiskSpace.Spot]) {
        storageSpots = spots
        scanningStorage = false
    }

    // MARK: Startup items

    func refreshStartupItems() {
        guard !demo else { return }
        Task.detached(priority: .utility) { [weak self] in
            let items = StartupItems.scan()
            await self?.setStartupItems(items)
        }
    }

    private func setStartupItems(_ items: [StartupItem]) {
        let seen = defaults.stringArray(forKey: "seenStartupItems").map(Set.init)
        let fresh = StartupItems.newItems(items, seen: seen)
        if !fresh.isEmpty {
            newStartupPaths.formUnion(fresh.map(\.path))
            for item in fresh.prefix(5) {
                audit("New startup item seen", "\(item.name) (\(item.domain.rawValue))")
                if alertNewStartupItems {
                    notify("New startup item: \(item.name)", "It starts by itself (\(item.domain.rawValue.lowercased())). Not yours? Check Keepwatch › Security.",
                           category: Self.startupCategory)
                }
            }
        }
        defaults.set(items.map(\.path), forKey: "seenStartupItems")
        if items != startupItems { startupItems = items }
    }

    /// Stops one of your own launch agents and moves its file to the Trash.
    func removeStartupItem(_ item: StartupItem) {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents").path + "/"
        guard item.domain == .user, item.path.hasPrefix(folder), !item.path.dropFirst(folder.count).contains("/"),
              !item.label.isEmpty, !item.label.contains("/") else { return }
        _ = SystemState.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])
        var trashed: NSURL?
        let ok = (try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &trashed)) != nil
        audit(ok ? "Removed startup item" : "Couldn't remove startup item", "\(item.name) (\(item.label))")
        newStartupPaths.remove(item.path)
        refreshStartupItems()
    }

    // MARK: Agent time limit

    private func checkAgentBudget(now: Date) {
        guard !demo else { return }
        budgetHandled.formIntersection(agentSessions.map(\.pid))
        for s in AgentBudget.overLimit(agentSessions, limitHours: agentLimitHours, handled: budgetHandled, now: now) {
            budgetHandled.insert(s.pid)
            let name = sessionTitles[s.pid].map { "“\($0)”" } ?? "\(s.agent) in \(s.folderName ?? "a folder")"
            if agentLimitStops {
                stopAgent(s)
                notify("Stopped \(name)", "It ran longer than your \(agentLimitHours) h limit.")
            } else {
                notify("\(name) has run \(agentLimitHours) h", "Still needed? Stop it from the Keepwatch menu.")
            }
        }
    }

    // MARK: Away summary, lock and screen sharing

    func userLeft() {
        guard !demo else { return }
        awayLog.leave(at: Date(), battery: power?.batteryPercent)
    }

    /// The screens woke. If the Mac is still locked you aren't back yet.
    func screensWoke() {
        guard !screenLocked else { return }
        cameBack()
    }

    func screenLockChanged(locked: Bool) {
        screenLocked = locked
        if locked {
            userLeft()
            if muteMicOnLock, privacy.micMuted == false, PrivacyMonitor.setMicMuted(true) {
                mutedByLock = true
                audit("Microphone muted", "screen locked")
            }
        } else {
            if mutedByLock {
                PrivacyMonitor.setMicMuted(false)
                mutedByLock = false
                audit("Microphone unmuted", "screen unlocked")
            }
            cameBack()
        }
        privacy = PrivacyMonitor.snapshot()
    }

    private func cameBack() {
        refreshSlow()
        if let summary = awayLog.comeBack(at: Date(), battery: power?.batteryPercent) { awaySummary = summary }
    }

    private func updateScreenWatchers(_ names: Set<String>) {
        let now = ScreenWatch.watchers(processNames: names)
        guard now != screenWatchers else { return }
        let started = now.filter { !screenWatchers.contains($0) }
        screenWatchers = now
        if started.contains(.remoteViewer) {
            audit("Screen Sharing connection seen")
            awayLog.record(.init(date: Date(), icon: "rectangle.on.rectangle", text: "Someone connected with Screen Sharing"))
            if alertOnMicCamera {
                notify("Someone is connected to your screen", "Screen Sharing is active. Not expected? Open Sharing settings.",
                       category: Self.screenCategory)
            }
        }
    }

    static func openSharingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// How a mode reads in the activity log.
    static func describe(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: "off"
        case .indefinite: "until turned off"
        case .until(let end): "until \(end.formatted(date: .abbreviated, time: .shortened))"
        case .whileAgentsRun: "while AI agents run"
        @unknown default: "changed"
        }
    }

    /// Adds to the activity log (and the system log, for Console).
    func audit(_ action: String, _ detail: String = "") {
        guard !demo else { return }
        auditLog.append(action, detail)
        auditLog.save()
        Self.logger.notice("\(action, privacy: .public) \(detail, privacy: .private)")
    }

    func clearAuditLog() {
        auditLog.clear()
        auditLog.save()
        audit("Activity log cleared")
    }

    /// The Mac's temperature in plain words, for lid sessions.
    var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        @unknown default: "Unknown"
        }
    }

    func quit() {
        systemAssertion.release()
        displayAssertion.release()
        if mutedByLid { PrivacyMonitor.setMicMuted(false) }
        // A running lid session is left to its watchdog on purpose: it has its
        // own deadline, and ending it here would need a password.
        NSApp.terminate(nil)
    }
}
