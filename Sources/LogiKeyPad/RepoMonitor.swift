import Foundation
import AppKit

/// Event-driven repo state. No polling loops: refresh happens on
/// .git file events, app activation, explicit key presses, and a
/// slow 5-minute timer that only runs while something is watching.
@MainActor
final class RepoMonitor: ObservableObject {
    @Published private(set) var state = RepoState()
    @Published private(set) var projectKind: ProjectKind = .unknown
    @Published var logLines: [String] = []

    private var watchers: [DispatchSourceFileSystemObject] = []
    private var refreshTask: Task<Void, Never>?
    private var ciTask: Task<Void, Never>?
    private var slowTimer: Task<Void, Never>?
    private(set) var repoPath = ""

    enum ProjectKind: String, Sendable { case swift, node, make, xcode, unknown }

    // MARK: Lifecycle

    func setRepo(_ path: String) {
        repoPath = path
        stopWatching()
        projectKind = Self.detectKind(path)
        guard !path.isEmpty else { state = RepoState(); return }
        startWatching()
        scheduleRefresh(includeCI: true)
    }

    func startSlowTimer() {
        slowTimer?.cancel()
        slowTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                self?.scheduleRefresh(includeCI: true)
            }
        }
    }

    // MARK: Log (capped; the only unbounded-looking buffer in the app)

    func log(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            logLines.append("\(stamp)  \(line)")
        }
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }

    // MARK: Refresh

    /// Debounced: bursts of .git events collapse into one refresh.
    func scheduleRefresh(includeCI: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshNow(includeCI: includeCI)
        }
    }

    func refreshNow(includeCI: Bool) async {
        guard !repoPath.isEmpty else { return }
        let path = repoPath
        async let status = Shell.git(["status", "--porcelain=v2", "--branch"], cwd: path)
        async let stash = Shell.git(["stash", "list"], cwd: path)
        let (s, st) = await (status, stash)
        guard s.ok else {
            if state.isRepo { log("git status failed: \(s.trimmed)") }
            state = RepoState()
            return
        }
        let stashCount = st.out.split(separator: "\n").count
        var next = RepoState.parse(porcelain: s.out, stashCount: st.ok ? stashCount : 0)
        next.ci = state.ci
        next.prURL = state.prURL
        if next != state { state = next }
        if includeCI { refreshCI() }
    }

    func refreshCI() {
        ciTask?.cancel()
        let path = repoPath
        guard !path.isEmpty else { return }
        ciTask = Task { [weak self] in
            // One gh call yields both PR presence and check rollup.
            let r = await Shell.gh(
                ["pr", "view", "--json", "url,statusCheckRollup", "--jq",
                 "[.url, ([.statusCheckRollup[]?.conclusion // .statusCheckRollup[]?.status] | join(\",\"))] | @tsv"],
                cwd: path)
            guard !Task.isCancelled, let self else { return }
            guard r.ok, !r.trimmed.isEmpty else {
                if self.state.ci != .none { self.state.ci = .none; self.state.prURL = "" }
                return
            }
            let cols = r.trimmed.split(separator: "\t", omittingEmptySubsequences: false)
            self.state.prURL = cols.first.map(String.init) ?? ""
            let rollup = cols.count > 1 ? String(cols[1]).uppercased() : ""
            self.state.ci = Self.classifyCI(rollup)
        }
    }

    nonisolated static func classifyCI(_ rollup: String) -> RepoState.CIState {
        if rollup.isEmpty { return .none }
        if rollup.contains("FAILURE") || rollup.contains("CANCELLED") || rollup.contains("TIMED_OUT") { return .fail }
        if rollup.contains("IN_PROGRESS") || rollup.contains("QUEUED") || rollup.contains("PENDING") { return .pending }
        return .pass
    }

    // MARK: Project detection (cached per repo; drives Build page commands)

    nonisolated static func detectKind(_ path: String) -> ProjectKind {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: (path as NSString).appendingPathComponent(name)) }
        if exists("Package.swift") { return .swift }
        if exists("package.json") { return .node }
        if let items = try? fm.contentsOfDirectory(atPath: path),
           items.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { return .xcode }
        if exists("Makefile") { return .make }
        return .unknown
    }

    /// npm scripts present in package.json — Build page only runs scripts that exist.
    func nodeScripts() -> Set<String> {
        guard projectKind == .node,
              let data = try? Data(contentsOf: URL(fileURLWithPath: repoPath).appendingPathComponent("package.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = obj["scripts"] as? [String: Any] else { return [] }
        return Set(scripts.keys)
    }

    // MARK: .git watching (kernel events, zero polling cost)

    private func startWatching() {
        let gitDir = (repoPath as NSString).appendingPathComponent(".git")
        for name in ["HEAD", "index"] {
            watchFile((gitDir as NSString).appendingPathComponent(name))
        }
        watchFile((gitDir as NSString).appendingPathComponent("refs/heads"))
    }

    private func watchFile(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleRefresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers.append(src)
    }

    private func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
    }
}
