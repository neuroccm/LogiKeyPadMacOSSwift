import Foundation
import AppKit

/// Finds the Terminal.app window whose shell is sitting in a given repo,
/// and (only when that shell is idle) runs a command there via AppleScript.
///
/// Matching: every shell owns a tty; `ps` gives pid/pgid/tpgid/tty/comm in
/// one snapshot, one batched `lsof -d cwd` gives each shell's cwd.
/// Idle guard: the shell's own process group must be the tty foreground
/// group (tpgid == pgid) — otherwise a program (Claude Code, dev server,
/// vim…) is in front and injected text would land inside it.

struct ShellSession: Equatable, Sendable {
    let pid: Int
    let pgid: Int
    let tpgid: Int
    let tty: String        // "/dev/ttys003"
    let comm: String       // "-zsh", "zsh", "-bash", "fish"…
    var cwd: String = ""
    var isIdle: Bool { tpgid == pgid }
}

enum TerminalMatch: Equatable {
    case idle(ShellSession)
    case busyOnly(ShellSession)
    case none
}

enum TerminalTarget {

    // MARK: Pure parsers (tested on captured output)

    /// Parses `ps -axo pid=,pgid=,tpgid=,tty=,comm=` lines, keeping shells on real ttys.
    static func parseSessions(psOutput: String) -> [ShellSession] {
        var out: [ShellSession] = []
        for line in psOutput.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int(f[0]), let pgid = Int(f[1]), let tpgid = Int(f[2]) else { continue }
            let ttyRaw = String(f[3])
            guard ttyRaw != "??", ttyRaw.hasPrefix("ttys") else { continue }
            let comm = String(f[4]).trimmingCharacters(in: .whitespaces)  // remainder keeps padding past maxSplits
            let base = (comm as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard ["zsh", "bash", "fish", "sh"].contains(base) else { continue }
            out.append(ShellSession(pid: pid, pgid: pgid, tpgid: tpgid, tty: "/dev/" + ttyRaw, comm: comm))
        }
        return out
    }

    /// Parses `lsof -a -p <pids> -d cwd -Fn` output into pid → cwd.
    static func parseLsofCwd(_ output: String) -> [Int: String] {
        var out: [Int: String] = [:]
        var pid: Int?
        for line in output.split(separator: "\n") {
            guard let first = line.first else { continue }
            if first == "p" { pid = Int(line.dropFirst()) }
            else if first == "n", let pid { out[pid] = String(line.dropFirst()) }
        }
        return out
    }

    /// Chooses the session for `repo`. Safety is per-shell: typing into ANY
    /// idle shell is safe, so idle wins globally (exact cwd preferred among
    /// idles); busyOnly is reported only when no idle shell matches.
    static func match(repo: String, sessions: [ShellSession]) -> TerminalMatch {
        guard !repo.isEmpty else { return .none }
        let exact = sessions.filter { $0.cwd == repo }
        let inside = sessions.filter { $0.cwd.hasPrefix(repo + "/") }
        if let s = exact.first(where: { $0.isIdle }) { return .idle(s) }
        if let s = inside.first(where: { $0.isIdle }) { return .idle(s) }
        if let s = (exact + inside).first { return .busyOnly(s) }
        return .none
    }

    /// Escapes a string for embedding in an AppleScript double-quoted literal.
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Live enumeration

    static func enumerate() async -> [ShellSession] {
        let ps = await Shell.run("/bin/ps", ["-axo", "pid=,pgid=,tpgid=,tty=,comm="], timeout: 10)
        guard ps.ok else { return [] }
        var sessions = parseSessions(psOutput: ps.out)
        guard !sessions.isEmpty else { return [] }
        let pidList = sessions.map { String($0.pid) }.joined(separator: ",")
        let lsof = await Shell.run("/usr/sbin/lsof", ["-a", "-p", pidList, "-d", "cwd", "-Fn"], timeout: 10)
        if lsof.ok {
            let cwds = parseLsofCwd(lsof.out)
            for i in sessions.indices { sessions[i].cwd = cwds[sessions[i].pid] ?? "" }
        }
        return sessions
    }

    // MARK: Delivery

    /// Runs `command` in the Terminal tab owning `tty`. MainActor: NSAppleScript.
    @MainActor
    static func doScript(tty: String, command: String) -> Bool {
        let source = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(appleScriptEscape(tty))" then
                        set selected of t to true
                        try
                            set index of w to 1
                        end try
                        do script "\(appleScriptEscape(command))" in t
                        return "ok"
                    end if
                end repeat
            end repeat
            return "notfound"
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil && result?.stringValue == "ok"
    }
}
