import Foundation
import AppKit

/// Executes catalog actions. Every action funnels through a handful of
/// primitives (shell task, git, gh, open app/URL, terminal, clipboard
/// prompt) so the 36-key catalog stays data, not code.
@MainActor
final class Executor {
    let monitor: RepoMonitor
    var config: () -> PadConfig
    var commitMessage: () -> String
    var bringAppToFront: () -> Void

    private let devServer = LongTask()
    private var pomodoroEndsAt: Date?
    private var pomodoroTask: Task<Void, Never>?
    var onPomodoroTick: ((String?) -> Void)?  // "24:31" or nil when idle

    init(monitor: RepoMonitor,
         config: @escaping () -> PadConfig,
         commitMessage: @escaping () -> String,
         bringAppToFront: @escaping () -> Void) {
        self.monitor = monitor
        self.config = config
        self.commitMessage = commitMessage
        self.bringAppToFront = bringAppToFront
    }

    private var repo: String { monitor.repoPath }
    private func log(_ s: String) { monitor.log(s) }

    @discardableResult
    func perform(_ action: CatalogAction) async -> (ok: Bool, text: String) {
        log("▶ \(action.title)\(action.sub.isEmpty ? "" : " · \(action.sub)")")
        let result: (Bool, String)
        switch action.kind {
        case .openApp:  result = openApp(action.arg)
        case .terminal: result = openTerminal(command: action.arg)
        case .prompt:   result = await copyPrompt(kind: action.arg)
        case .task:     result = await runTask(action.arg)
        case .editor:   result = openEditor()
        case .git:      result = await runGit(action.arg)
        case .github:   result = await runGitHub(action.arg)
        case .flow:     result = await runFlow(action.arg)
        }
        log(result.0 ? "✓ \(result.1)" : "✗ \(result.1)")
        monitor.scheduleRefresh(includeCI: action.kind == .git || action.kind == .github)
        return result
    }

    // MARK: - Primitives

    private func requireRepo() -> (Bool, String)? {
        repo.isEmpty ? (false, "No repo selected — pick a folder in LogiKeyPad") : nil
    }

    private func openApp(_ name: String) -> (Bool, String) {
        let ws = NSWorkspace.shared
        if let app = ws.runningApplications.first(where: { $0.localizedName == name }) {
            app.activate()
            return (true, "\(name) focused")
        }
        guard let url = ws.urlForApplication(withBundleIdentifier: Self.bundleID(for: name))
            ?? URL(fileURLWithPath: "/Applications/\(name).app") as URL?,
              FileManager.default.fileExists(atPath: url.path) else {
            return (false, "\(name).app not found in /Applications")
        }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return (true, "\(name) launched")
    }

    private static func bundleID(for app: String) -> String {
        switch app {
        case "Muse": return "com.muse.Muse"  // falls back to /Applications path if wrong
        case "Codex": return "com.openai.codex"
        case "Claude": return "com.anthropic.claudefordesktop"
        default: return ""
        }
    }

    private func openTerminal(command: String) -> (Bool, String) {
        let dir = repo.isEmpty ? NSHomeDirectory() : repo
        if config().terminalApp == "Ghostty" {
            // Ghostty has no "do script" API; open at dir, put command on clipboard.
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ghostty.app"))
            if !command.isEmpty {
                copyToClipboard("cd \(shellQuote(dir)) && \(command)")
                return (true, "Ghostty open — ⌘V runs: \(command)")
            }
            copyToClipboard("cd \(shellQuote(dir))")
            return (true, "Ghostty open — ⌘V to cd into repo")
        }
        // Terminal.app is fully scriptable (one-time Automation permission).
        let script = command.isEmpty
            ? "cd \(shellQuote(dir))"
            : "cd \(shellQuote(dir)) && \(command)"
        let apple = """
        tell application "Terminal"
            activate
            do script "\(script.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: apple)?.executeAndReturnError(&err)
        if let err { return (false, "Terminal scripting failed: \(err[NSAppleScript.errorMessage] ?? "?")") }
        return (true, command.isEmpty ? "Terminal at repo" : "Terminal: \(command)")
    }

    private func openEditor() -> (Bool, String) {
        if let fail = requireRepo() { return fail }
        let editor = config().editorApp
        let cli = editor == "Cursor" ? "/usr/local/bin/cursor" : "/usr/local/bin/code"
        if FileManager.default.isExecutableFile(atPath: cli) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [repo]
            try? p.run()
            return (true, "\(editor) opened repo")
        }
        openInEditor([URL(fileURLWithPath: repo)])
        return (true, "\(editor) opened repo")
    }

    /// NSWorkspace's open-with-app API is async; fire-and-forget is correct here.
    private func openInEditor(_ urls: [URL]) {
        let appURL = URL(fileURLWithPath: "/Applications/\(config().editorApp).app")
        Task {
            try? await NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openURL(_ string: String) -> (Bool, String) {
        guard let url = URL(string: string) else { return (false, "Bad URL") }
        NSWorkspace.shared.open(url)
        return (true, "Opened \(string)")
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Build tasks (auto-detected per project kind)

    private func runTask(_ verb: String) async -> (Bool, String) {
        if let fail = requireRepo() { return fail }
        if verb == "dev" { return toggleDevServer() }
        guard let cmd = taskCommand(verb) else {
            return (false, "No \(verb) command for this project (\(monitor.projectKind.rawValue))")
        }
        log("$ \(cmd)")
        let r = await Shell.zsh(cmd, cwd: repo, timeout: verb == "test" || verb == "build" ? 600 : 300)
        let tail = r.out.split(separator: "\n").suffix(25).joined(separator: "\n")
        if !tail.isEmpty { log(tail) }
        return (r.ok, r.ok ? "\(verb) passed" : "\(verb) failed (exit \(r.code)) — see log")
    }

    private func taskCommand(_ verb: String) -> String? {
        switch (monitor.projectKind, verb) {
        case (.swift, "build"): return "swift build"
        case (.swift, "test"): return "swift test"
        case (.swift, "run"): return "swift run"
        case (.swift, "format"): return "command -v swift-format >/dev/null && swift-format -i -r Sources Tests 2>/dev/null || echo 'swift-format not installed'"
        case (.swift, "lint"): return "command -v swiftlint >/dev/null && swiftlint || swift build 2>&1 | grep -E 'warning|error' || true"
        case (.swift, "clean"): return "rm -rf .build"
        case (.node, let v):
            let script = ["run": "start", "format": "format"][v] ?? v
            if v == "clean" { return "rm -rf dist build .next/.cache" }
            return monitor.nodeScripts().contains(script) ? "npm run \(script)" : nil
        case (.xcode, "build"): return "xcodebuild build 2>&1 | tail -30"
        case (.xcode, "test"): return "xcodebuild test 2>&1 | tail -30"
        case (.xcode, "clean"): return "xcodebuild clean"
        case (.make, "build"): return "make"
        case (.make, "test"): return "make test"
        case (.make, "run"): return "make run"
        case (.make, "clean"): return "make clean"
        default: return nil
        }
    }

    private func toggleDevServer() -> (Bool, String) {
        if devServer.isRunning {
            devServer.stop()
            return (true, "Dev server stopped")
        }
        let cmd: String?
        switch monitor.projectKind {
        case .node: cmd = monitor.nodeScripts().contains("dev") ? "npm run dev" : nil
        case .swift: cmd = "swift run"
        case .make: cmd = "make dev"
        default: cmd = nil
        }
        guard let cmd else { return (false, "No dev command for this project") }
        log("$ \(cmd) (streaming; press Server again to stop)")
        devServer.start(command: cmd, cwd: repo, label: "dev") { [weak self] chunk in
            Task { @MainActor in self?.log(chunk) }
        }
        return (true, "Dev server starting")
    }

    // MARK: - Git

    private func runGit(_ verb: String) async -> (Bool, String) {
        if let fail = requireRepo() { return fail }
        switch verb {
        case "status":
            await monitor.refreshNow(includeCI: true)
            let s = monitor.state
            return (true, "\(s.branch) · \(s.staged) staged · \(s.dirty) dirty · ↑\(s.ahead) ↓\(s.behind)")
        case "stage":
            let r = await Shell.git(["add", "-A"], cwd: repo)
            return (r.ok, r.ok ? "All changes staged" : r.trimmed)
        case "commit":
            let msg = commitMessage().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty else {
                bringAppToFront()
                return (false, "Type a commit message in LogiKeyPad first")
            }
            guard monitor.state.staged > 0 else { return (false, "Nothing staged — press Stage first") }
            let r = await Shell.git(["commit", "-m", msg], cwd: repo)
            if r.ok { log(r.trimmed) }
            return (r.ok, r.ok ? "Committed: \(msg)" : r.trimmed)
        case "push":
            let r = await Shell.git(["push"], cwd: repo, timeout: 120)
            return (r.ok, r.ok ? "Pushed \(monitor.state.branch)" : r.trimmed)
        case "pull":
            let r = await Shell.git(["pull", "--ff-only"], cwd: repo, timeout: 120)
            return (r.ok, r.ok ? "Pulled (fast-forward)" : r.trimmed)
        case "fetch":
            let r = await Shell.git(["fetch", "--prune"], cwd: repo, timeout: 120)
            return (r.ok, r.ok ? "Fetched" : r.trimmed)
        case "stash":
            if monitor.state.dirty + monitor.state.staged > 0 {
                let r = await Shell.git(["stash", "push", "-m", "logikeypad"], cwd: repo)
                return (r.ok, r.ok ? "Stashed (press again on clean tree to pop)" : r.trimmed)
            } else if monitor.state.hasStash {
                let r = await Shell.git(["stash", "pop"], cwd: repo)
                return (r.ok, r.ok ? "Stash popped" : r.trimmed)
            }
            return (false, "Nothing to stash, no stash to pop")
        case "diff":
            let r = await Shell.git(["diff", "HEAD"], cwd: repo)
            guard r.ok else { return (false, r.trimmed) }
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("logikeypad-diff.patch")
            try? r.out.write(to: tmp, atomically: true, encoding: .utf8)
            openInEditor([tmp])
            return (true, r.out.isEmpty ? "No diff — tree is clean" : "Diff opened in editor")
        case "copyBranch":
            copyToClipboard(monitor.state.branch)
            return (true, "Copied branch: \(monitor.state.branch)")
        default:
            return (false, "Unknown git action \(verb)")
        }
    }

    // MARK: - GitHub (via gh)

    private func runGitHub(_ verb: String) async -> (Bool, String) {
        if let fail = requireRepo() { return fail }
        switch verb {
        case "pr":
            let view = await Shell.gh(["pr", "view", "--json", "url", "--jq", ".url"], cwd: repo)
            if view.ok, !view.trimmed.isEmpty { return openURL(view.trimmed) }
            let create = await Shell.gh(["pr", "create", "--fill"], cwd: repo, timeout: 120)
            if create.ok { return (true, "PR created: \(create.trimmed)") }
            return (false, create.trimmed.isEmpty ? "gh pr create failed" : create.trimmed)
        case "checks":
            monitor.refreshCI()
            let r = await Shell.gh(["pr", "checks"], cwd: repo, timeout: 60)
            let tail = r.out.split(separator: "\n").suffix(12).joined(separator: "\n")
            if !tail.isEmpty { log(tail) }
            return (true, "CI: \(monitor.state.ci.rawValue) — details in log")
        case "rerun":
            let run = await Shell.gh(["run", "list", "--limit", "1", "--json", "databaseId", "--jq", ".[0].databaseId"], cwd: repo)
            guard run.ok, !run.trimmed.isEmpty, run.trimmed != "null" else { return (false, "No workflow run found") }
            let r = await Shell.gh(["run", "rerun", run.trimmed, "--failed"], cwd: repo)
            return (r.ok, r.ok ? "Re-running failed jobs" : r.trimmed)
        case "reviews":
            let r = await Shell.gh(["api", "user", "--jq", ".login"], cwd: repo)
            let me = r.ok ? r.trimmed : "@me"
            return openURL("https://github.com/pulls?q=is%3Aopen+is%3Apr+review-requested%3A\(me)")
        case "repo":
            let r = await Shell.gh(["repo", "view", "--json", "url", "--jq", ".url"], cwd: repo)
            return r.ok ? openURL(r.trimmed) : (false, r.trimmed)
        case "copyPR":
            let url = monitor.state.prURL
            guard !url.isEmpty else { return (false, "No PR for this branch yet") }
            copyToClipboard(url)
            return (true, "Copied PR link")
        default:
            return (false, "Unknown GitHub action \(verb)")
        }
    }

    // MARK: - Flow

    private func runFlow(_ verb: String) async -> (Bool, String) {
        switch verb {
        case "standup":
            if let fail = requireRepo() { return fail }
            let me = await Shell.git(["config", "user.name"], cwd: repo)
            let author = me.ok ? me.trimmed : ""
            var args = ["log", "--since=midnight", "--pretty=format:- %s"]
            if !author.isEmpty { args.append("--author=\(author)") }
            let r = await Shell.git(args, cwd: repo)
            let body = r.trimmed.isEmpty ? "(no commits today yet)" : r.trimmed
            copyToClipboard("Standup — \(monitor.state.branch)\n\(body)")
            return (true, "Standup copied to clipboard")
        case "pomodoro":
            return togglePomodoro()
        case "note":
            if let fail = requireRepo() { return fail }
            let url = URL(fileURLWithPath: repo).appendingPathComponent("NOTES.md")
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
            let line = "\n- [ ] \(stamp) — "
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
            } else {
                try? ("# Notes\n" + line).write(to: url, atomically: true, encoding: .utf8)
            }
            openInEditor([url])
            return (true, "Note stub added to NOTES.md")
        default:
            return (false, "Unknown flow action \(verb)")
        }
    }

    private func togglePomodoro() -> (Bool, String) {
        if pomodoroTask != nil {
            pomodoroTask?.cancel(); pomodoroTask = nil; pomodoroEndsAt = nil
            onPomodoroTick?(nil)
            return (true, "Focus timer cancelled")
        }
        let ends = Date().addingTimeInterval(25 * 60)
        pomodoroEndsAt = ends
        pomodoroTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let ends = self.pomodoroEndsAt else { return }
                let left = ends.timeIntervalSinceNow
                if left <= 0 { break }
                self.onPomodoroTick?(String(format: "%02d:%02d", Int(left) / 60, Int(left) % 60))
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self else { return }
            self.pomodoroTask = nil; self.pomodoroEndsAt = nil
            self.onPomodoroTick?(nil)
            NSSound(named: "Glass")?.play()
            self.log("🍅 Focus session done — take 5.")
            self.bringAppToFront()
        }
        return (true, "Focus 25:00 started (menu bar counts down)")
    }

    // MARK: - Agent prompts (clipboard; paste into Muse / Codex / Claude Code)

    private func copyPrompt(kind: String) async -> (Bool, String) {
        if let fail = requireRepo() { return fail }
        let prompt = await Self.buildPrompt(kind: kind, repo: repo, branch: monitor.state.branch)
        copyToClipboard(prompt)
        return (true, "Prompt copied — paste into Muse, Codex, or Claude Code")
    }

    /// Pure-ish prompt builder (shell reads only). Capped so huge diffs stay sane.
    static func buildPrompt(kind: String, repo: String, branch: String) async -> String {
        let stat = await Shell.git(["diff", "--stat", "HEAD"], cwd: repo)
        let diff = await Shell.git(["diff", "HEAD"], cwd: repo)
        let diffText = String(diff.out.prefix(6000))
        let header = "Repo: \((repo as NSString).lastPathComponent) · Branch: \(branch)\n"
        let body = stat.out.isEmpty
            ? "(working tree clean — use the latest commit: `git show HEAD`)"
            : "Changed files:\n\(stat.out)\nDiff (truncated):\n```diff\n\(diffText)\n```"
        let ask: String
        switch kind {
        case "review":
            ask = "Review my diff. Lead with bugs, regressions, and missing tests; cite file and line. Be specific, skip praise."
        case "explain":
            ask = "Explain what my diff does and why, in plain language. Call out anything surprising or risky."
        case "tests":
            ask = "Write tests for my diff following this repo's existing test conventions. Cover the new behavior and one failure path."
        case "commit":
            ask = "Write a conventional commit message for my diff: one summary line (≤72 chars), blank line, short body explaining why. Output only the message."
        default:
            ask = "Help me with my diff."
        }
        return header + ask + "\n\n" + body
    }
}
