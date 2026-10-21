import SwiftUI
import AppKit
import Combine
import IOKit.hid
import ServiceManagement

@main
struct LogiKeyPadApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("LogiKeyPad", id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.github)
                .frame(minWidth: 880, minHeight: 620)
                .task { appState.start() }
        }
        .windowStyle(.titleBar)

        MenuBarExtra {
            MenuBarView().environmentObject(appState)
        } label: {
            Text(appState.pomodoroText ?? appState.monitor.state.menuBarTitle)
                .font(.system(.body, design: .monospaced))
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        let s = app.monitor.state
        Text(s.isRepo ? "\(s.branch) · \(s.staged) staged · \(s.dirty) dirty · CI \(s.ci.rawValue)"
                      : "No repo selected")
        Text(app.bridge.pluginConnected ? "Keypad plugin: connected" : "Keypad plugin: not connected")
        Divider()
        Button("Open LogiKeyPad") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh State") { app.monitor.scheduleRefresh(includeCI: true) }
        Divider()
        Button("Quit LogiKeyPad") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Owns everything long-lived. Created once; views are disposable.
@MainActor
final class AppState: ObservableObject {
    let catalog = Catalog.load()
    @Published var config: PadConfig
    @Published var commitMessage = ""
    @Published var pomodoroText: String?
    @Published var pendingConfirm: CatalogAction?
    @Published private(set) var keypadPresent = false
    @Published private(set) var optionsPlusInstalled = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let monitor = RepoMonitor()
    let bridge = BridgeServer()       // legacy Actions SDK path (optional)
    let hid = MXKeypadHID()            // primary: direct HID, no Options+
    let github = GitHubSync()
    @Published var cloningSlug: String?
    @Published var devicePage = 0 {
        didSet { repaintPanel(force: true) }
    }
    private var cancellables = Set<AnyCancellable>()
    private var lastPaintHash = ""
    private(set) lazy var executor = Executor(
        monitor: monitor,
        config: { [weak self] in self?.config ?? PadConfig(pages: []) },
        commitMessage: { [weak self] in self?.commitMessage ?? "" },
        bringAppToFront: { NSApp.activate(ignoringOtherApps: true) }
    )

    private var started = false

    init() {
        config = PadConfig.load(catalog: catalog)
    }

    func start() {
        guard !started else { return }
        started = true
        // Views observe AppState, not these child objects — forward their
        // changes or the header/log go stale until an unrelated rerender
        // (found when repo state updated silently under a frozen header).
        for child in [monitor.objectWillChange, hid.objectWillChange, bridge.objectWillChange] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        monitor.setRepo(config.repoPath)
        monitor.startSlowTimer()
        executor.onPomodoroTick = { [weak self] text in
            self?.pomodoroText = text
            self?.repaintPomodoroTile()
        }
        hid.onKey = { [weak self] slot, isDown in
            guard let self, isDown else { return }
            guard self.config.pages.indices.contains(self.devicePage) else { return }
            let keys = self.config.pages[self.devicePage].keys
            guard keys.indices.contains(slot), let action = self.catalog.action(keys[slot]) else { return }
            Task { await self.fire(action) }
        }
        hid.onPageButton = { [weak self] next in
            guard let self, !self.config.pages.isEmpty else { return }
            let count = self.config.pages.count
            self.devicePage = next ? (self.devicePage + 1) % count
                                    : (self.devicePage + count - 1) % count
            self.monitor.log("Keypad page → \(self.config.pages[self.devicePage].title)")
        }
        hid.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.keypadPresent = connected
            self.monitor.log(connected
                ? "MX Creative Keypad connected via direct HID — painting page “\(self.config.pages.indices.contains(self.devicePage) ? self.config.pages[self.devicePage].title : "?")”."
                : "MX Creative Keypad disconnected.")
            if connected { self.repaintPanel(force: true) }
        }
        hid.start()
        // Leave the hardware as we found it: blank panel, default buttons.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hid.restoreDefaultsAndClose() }
        }
        monitor.$state
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.repaintPanel() }
            .store(in: &cancellables)
        bridge.onKey = { [weak self] id in
            guard let self else { return (false, "App unavailable") }
            return await self.handleBridgeKey(id)
        }
        bridge.start()
        github.onLog = { [weak self] line in self?.monitor.log(line) }
        github.loadCache()
        Task { await github.syncIfStale() }
        refreshHealth()
        monitor.log("LogiKeyPad ready — \(catalog.actions.count) actions, \(catalog.pages.count) pages.")
        if !hid.connected {
            monitor.log("Waiting for MX Creative Keypad on USB (direct HID — Options+ not required).")
        }
        // Push state summaries to the plugin (logged there today; LCD-ready later).
        Task { [weak self] in
            guard let self else { return }
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self.monitor.scheduleRefresh()
                self.refreshHealth()
            }
        }
    }

    func refreshHealth() {
        keypadPresent = DeviceProbe.mxCreativeKeypadPresent()
        optionsPlusInstalled = DeviceProbe.optionsPlusInstalled()
    }

    // MARK: Panel painting (direct HID)

    private func currentActions() -> [CatalogAction?] {
        guard config.pages.indices.contains(devicePage) else { return [] }
        return config.pages[devicePage].keys.map { catalog.action($0) }
    }

    private func currentBadges() -> [Int: KeyArt.Badge] {
        let s = monitor.state
        var out: [Int: KeyArt.Badge] = [:]
        for (slot, action) in currentActions().enumerated() {
            guard let action else { continue }
            switch action.id {
            case "git_status" where s.isRepo:
                out[slot] = .init(text: s.branch, color: .white)
            case "stage_all" where s.dirty > 0:
                out[slot] = .init(text: "\(s.dirty) dirty", color: .systemYellow)
            case "commit" where s.staged > 0:
                out[slot] = .init(text: "\(s.staged) staged", color: .systemGreen)
            case "push" where s.ahead > 0:
                out[slot] = .init(text: "↑\(s.ahead)", color: .white)
            case "pull" where s.behind > 0:
                out[slot] = .init(text: "↓\(s.behind)", color: .white)
            case "ci_status":
                switch s.ci {
                case .pass: out[slot] = .init(text: "PASS ✓", color: .systemGreen)
                case .fail: out[slot] = .init(text: "FAIL ✗", color: .systemRed)
                case .pending: out[slot] = .init(text: "RUNNING…", color: .systemYellow)
                default: break
                }
            case "pr" where !s.prURL.isEmpty:
                out[slot] = .init(text: "PR open", color: .systemGreen)
            case "pomodoro" where pomodoroText != nil:
                out[slot] = .init(text: pomodoroText!, color: .white)
            default: break
            }
        }
        return out
    }

    func repaintPanel(force: Bool = false) {
        guard hid.connected else { return }
        let actions = currentActions()
        let badges = currentBadges()
        let hash = "\(devicePage)|\(config.theme.rawValue)|" +
            actions.map { $0?.id ?? "-" }.joined(separator: ",") + "|" +
            badges.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.text)" }.joined(separator: ",")
        guard force || hash != lastPaintHash else { return }
        lastPaintHash = hash
        guard let jpeg = KeyArt.panelJPEG(actions: actions, theme: config.theme, badges: badges) else { return }
        Task { await hid.paint(jpeg: jpeg, x: 0, y: 0, w: 480, h: 480) }
    }

    private func repaintPomodoroTile() {
        guard hid.connected else { return }
        let actions = currentActions()
        guard let slot = actions.firstIndex(where: { $0?.id == "pomodoro" }),
              let action = actions[slot] else { return }
        let badge = pomodoroText.map { KeyArt.Badge(text: $0, color: .white) }
        guard let jpeg = KeyArt.tileJPEG(action: action, theme: config.theme, badge: badge) else { return }
        let o = KeyArt.tileOrigin(slot: slot)
        Task { await hid.paint(jpeg: jpeg, x: UInt16(o.x), y: UInt16(o.y), w: 118, h: 118) }
    }

    func saveConfig() {
        config.save()
        repaintPanel(force: true)
        // Keep the plugin's SVG theme in sync on next `npm run gen`.
        let themeURL = BridgeServer.tokenFileURL().deletingLastPathComponent()
            .appendingPathComponent("theme.txt")
        try? config.theme.rawValue.write(to: themeURL, atomically: true, encoding: .utf8)
    }

    /// Clones a GitHub repo into the default parent, then selects it.
    func cloneRepo(_ repo: GitHubRepo) async {
        guard cloningSlug == nil else { return }
        cloningSlug = repo.slug
        defer { cloningSlug = nil }
        let parent = GitHubSync.defaultCloneParent()
        let dest = (parent as NSString).appendingPathComponent(repo.name)
        if FileManager.default.fileExists(atPath: dest) {
            monitor.log("\(repo.name) already exists at \(dest) — selecting it.")
            github.markCloned(slug: repo.slug, path: dest)
            setRepo(dest)
            return
        }
        monitor.log("Cloning \(repo.nameWithOwner) → \(dest) …")
        let r = await Shell.gh(["repo", "clone", repo.nameWithOwner, dest], cwd: parent, timeout: 600)
        if r.ok {
            github.markCloned(slug: repo.slug, path: dest)
            setRepo(dest)
            monitor.log("Cloned \(repo.nameWithOwner).")
        } else {
            monitor.log("Clone failed: \(r.trimmed)")
        }
    }

    func setRepo(_ path: String) {
        config.repoPath = path
        saveConfig()
        monitor.setRepo(path)
        bridge.pushState(summary: monitor.state.menuBarTitle)
    }

    /// Fires an action from any source (grid click or physical key).
    /// Destructive actions require an in-app confirmation first.
    func fire(_ action: CatalogAction, confirmed: Bool = false) async -> (ok: Bool, text: String) {
        if action.needsConfirm && !confirmed {
            pendingConfirm = action
            NSApp.activate(ignoringOtherApps: true)
            return (false, "Confirm “\(action.title)” in LogiKeyPad")
        }
        let r = await executor.perform(action)
        bridge.pushState(summary: monitor.state.menuBarTitle)
        return r
    }

    private func handleBridgeKey(_ id: String) async -> (ok: Bool, text: String) {
        guard let action = catalog.action(id) else { return (false, "Unknown action \(id)") }
        return await fire(action)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            monitor.log("Launch-at-login failed: \(error.localizedDescription) (needs the .app bundle)")
        }
    }
}

enum DeviceProbe {
    /// MX Creative Keypad: Logitech vendor 0x046D, product 50004 (observed via IOKit).
    static func mxCreativeKeypadPresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x046D,
            kIOHIDProductIDKey as String: 50004,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return !devices.isEmpty
    }

    static func optionsPlusInstalled() -> Bool {
        let fm = FileManager.default
        return ["/Applications/Logi Options+.app",
                "/Applications/logioptionsplus.app",
                "/Library/Application Support/Logitech/LogiOptionsPlus"]
            .contains { fm.fileExists(atPath: $0) }
    }
}
