import AppKit
import Combine
import Foundation
import KeepwatchCore
import ServiceManagement
import UserNotifications

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
    /// Notify when the mic or camera turns on.
    @Published var alertOnMicCamera: Bool { didSet { defaults.set(alertOnMicCamera, forKey: "alertMicCamera") } }
    @Published var customAmount: Double { didSet { defaults.set(customAmount, forKey: "customAmount") } }
    @Published var customUnit: AwakeDuration.Unit { didSet { defaults.set(customUnit.rawValue, forKey: "customUnit") } }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var action: BannerAction?
    }

    enum BannerAction: Equatable { case restoreSleep }

    // MARK: Internals

    private let defaults = UserDefaults.standard
    private var engine = KeepAwakeEngine()
    private let matcher = AgentMatcher()
    private var systemAssertion = PowerAssertion(kind: .system, name: "Keepwatch: keeping your Mac awake")
    private var displayAssertion = PowerAssertion(kind: .display, name: "Keepwatch: keeping the display on")
    private var timer: Timer?
    private var tickCount = 0
    private var lastLidClosed: Bool?
    private var mutedByLid = false
    private let policy = LidModePolicy()

    let stopFile: URL = LidWatchdog.defaultStopFile()

    init() {
        keepDisplayAwake = defaults.bool(forKey: "keepDisplayAwake")
        notifyWhenAgentsFinish = defaults.object(forKey: "notifyAgents") as? Bool ?? true
        muteMicWhenLidCloses = defaults.bool(forKey: "muteOnLid")
        endLidSessionWhenAgentsFinish = defaults.object(forKey: "lidEndsWithAgents") as? Bool ?? true
        lidHours = defaults.object(forKey: "lidHours") as? Double ?? 3
        lidAllowBattery = defaults.bool(forKey: "lidBattery")
        lidSleepAtEnabled = defaults.bool(forKey: "lidSleepAtOn")
        lidSleepAt = defaults.object(forKey: "lidSleepAt") as? Date
            ?? LidSessionPlan.nextTime(hour: 1, minute: 0, after: Date()) ?? Date()
        alertOnMicCamera = defaults.object(forKey: "alertMicCamera") as? Bool ?? true
        let savedTiles = (UserDefaults.standard.stringArray(forKey: "summaryTiles") ?? []).compactMap(SummaryTile.init(rawValue:))
        summaryTiles = savedTiles.isEmpty ? SummaryTile.defaults : Array(savedTiles.prefix(SummaryTile.maxShown))
        customAmount = defaults.object(forKey: "customAmount") as? Double ?? 2
        customUnit = (defaults.string(forKey: "customUnit")).flatMap(AwakeDuration.Unit.init(rawValue:)) ?? .hours
        lidIntent = (defaults.data(forKey: "lidIntent")).flatMap { try? JSONDecoder().decode(LidModeIntent.self, from: $0) } ?? .off
        if let data = defaults.data(forKey: "mode"), let saved = try? JSONDecoder().decode(KeepAwakeMode.self, from: data) {
            // A timer that ran out while we were closed comes back as off.
            if case .until(let end) = saved, end <= Date() { } else { engine.set(saved) }
        }
        mode = engine.mode
        refreshSlow()
        checkLidSessionOnLaunch()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Keep awake

    func setMode(_ newMode: KeepAwakeMode) {
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
        agents = matcher.runningAgents(in: ProcessList.snapshot(wantArguments: matcher.isCandidate))
        let decision = engine.tick(now: now, agents: Set(agents.keys))
        mode = engine.mode
        remaining = decision.remaining
        holding = decision.holdAssertion
        apply()
        for event in decision.events { handle(event) }

        let before = privacy
        privacy = PrivacyMonitor.snapshot()
        if tickCount > 1 { alertIfPrivacyChanged(from: before) }
        if tickCount % 5 == 1 { refreshSlow() }
        if tickCount % 30 == 1 { refreshSecurity() }
        handleLidTransition()
        superviseLidSession(now: now)
    }

    private func refreshSlow() {
        power = SystemState.power()
        pmset = SystemState.pmsetSettings()
        for t in QuickToggle.allCases where toggles[t] == nil { toggles[t] = t.read() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func handle(_ event: KeepAwakeEngine.Event) {
        switch event {
        case .agentFinished(let name):
            if notifyWhenAgentsFinish { notify("\(name) finished", "No \(name) process is running any more.") }
        case .timerEnded:
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
        } else if !closed, mutedByLid {
            PrivacyMonitor.setMicMuted(false)
            mutedByLid = false
        }
    }

    // MARK: Mic, camera and security

    private func alertIfPrivacyChanged(from before: PrivacySnapshot) {
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

    private func setSecurity(_ states: [SecurityCheck: SecurityState]) { security = states }

    func open(_ check: SecurityCheck) {
        if let url = check.settingsURL { NSWorkspace.shared.open(url) }
    }

    nonisolated static let cameraCategory = "camera-on"
    nonisolated static let openCameraAction = "open-camera-settings"

    /// Takes camera permission back from every app (`tccutil reset Camera`), so
    /// each one has to ask again. Apps already open keep access until they quit.
    func resetCameraPermissions() {
        let ok = (SystemState.run("/usr/bin/tccutil", ["reset", "Camera"]) ?? "").contains("Successfully")
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
        if PrivacyMonitor.setMicMuted(!muted) { mutedByLid = false }
        privacy = PrivacyMonitor.snapshot()
    }

    // MARK: Lid session

    var lidSessionPlan: LidSessionPlan {
        LidSessionPlan(afterLidClosed: lidHours > 0 ? lidHours * 3600 : nil,
                       sleepAt: lidSleepAtEnabled ? lidSleepAt : nil,
                       allowOnBattery: lidAllowBattery, minBatteryPercent: 20, sleepWhenDone: true)
    }

    func startLidSession() {
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
            if !ok {
                self.saveIntent(.off)
                if !message.contains("-128") { self.banner = Banner(text: "Lid session not started: \(message)", action: nil) }
            }
            self.pmset = SystemState.pmsetSettings()
        }
    }

    /// Ask the watchdog to restore sleep. No password needed.
    func endLidSession(reason: String) {
        FileManager.default.createFile(atPath: stopFile.path, contents: Data(reason.utf8))
        notify("Lid session ending", "Sleep turns back on within 30 seconds (\(reason)).")
    }

    /// For a setting Keepwatch didn't make, or one left over after a reboot.
    func restoreSleepNow() {
        let script = PMSet.adminAppleScript(for: LidWatchdog.stopNowCommand(), prompt: "Keepwatch needs your password to turn sleep back on.")
        runAdmin(script) { [weak self] ok, _ in
            guard let self else { return }
            if ok { self.saveIntent(.off); self.banner = nil }
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
            banner = Banner(text: "Sleep is still turned off from an earlier lid session (the Mac probably restarted). Turn it back on?",
                            action: .restoreSleep)
        case .askAboutForeignSetting:
            banner = Banner(text: "Sleep is turned off system-wide, but not by Keepwatch. Your Mac won't sleep even with the lid closed.",
                            action: .restoreSleep)
        }
    }

    /// Agents seen during the current lid session, and when last seen.
    private var lidAgentLastSeen: Date?
    private static let lidAgentGrace: TimeInterval = 120

    private func superviseLidSession(now: Date) {
        guard lidIntent.enabled, !lidBusy else { lidAgentLastSeen = nil; return }
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
        lidIntent = intent
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

    func refreshPorts() { ports = ListeningPorts.current() }

    func stopProcess(_ port: ListeningPort) {
        ListeningPorts.stop(pid: port.pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPorts() }
    }

    // MARK: Command-line tool

    func installCLI() {
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
        t.write(value)
        toggles[t] = t.read()
    }

    func setLaunchAtLogin(_ on: Bool) {
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

    private func notify(_ title: String, _ body: String, category: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return } // not running from an .app
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let category { content.categoryIdentifier = category }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if notificationsAsked { send(); return }
        notificationsAsked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
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
