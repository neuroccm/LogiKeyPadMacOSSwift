import Foundation

/// Minimal async process runner. Output is capped so a chatty build
/// can never grow memory without bound (resource-efficiency requirement).
enum Shell {
    struct Result: Sendable {
        let code: Int32
        let out: String
        var ok: Bool { code == 0 }
        var trimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static let maxBytes = 256 * 1024

    static func run(_ launchPath: String, _ args: [String],
                    cwd: String? = nil, timeout: TimeInterval = 120) async -> Result {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            if let cwd, !cwd.isEmpty { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            // GUI apps inherit a thin PATH; give child tools the usual locations.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" +
                "\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            let box = OutputBox()
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                if !data.isEmpty { box.append(data, cap: maxBytes) }
            }
            proc.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: Result(code: p.terminationStatus, out: box.string))
            }
            do { try proc.run() } catch {
                cont.resume(returning: Result(code: -1, out: "\(launchPath): \(error.localizedDescription)"))
                return
            }
            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if proc.isRunning { proc.terminate() }
                }
            }
        }
    }

    /// Runs through the user's login shell so aliases/functions in ~/.zshrc work.
    static func zsh(_ command: String, cwd: String? = nil, timeout: TimeInterval = 300) async -> Result {
        await run("/bin/zsh", ["-lc", command], cwd: cwd, timeout: timeout)
    }

    static func git(_ args: [String], cwd: String, timeout: TimeInterval = 30) async -> Result {
        await run("/usr/bin/git", args, cwd: cwd, timeout: timeout)
    }

    static func gh(_ args: [String], cwd: String, timeout: TimeInterval = 45) async -> Result {
        // gh lives in Homebrew on this machine; resolve once.
        await run(ghPath, args, cwd: cwd, timeout: timeout)
    }

    static let ghPath: String = {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/opt/homebrew/bin/gh"
    }()

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data, cap: Int) {
            lock.lock(); defer { lock.unlock() }
            guard data.count < cap else { return }
            data.append(chunk.prefix(cap - data.count))
        }
        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Streams a long-running task (dev server) and can stop it. One at a time.
@MainActor
final class LongTask {
    private var proc: Process?
    var isRunning: Bool { proc?.isRunning == true }
    private(set) var label = ""

    func start(command: String, cwd: String, label: String, onLine: @escaping (String) -> Void) {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let s = String(decoding: fh.availableData, as: UTF8.self)
            if !s.isEmpty { onLine(s) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.proc = nil }
        }
        try? p.run()
        proc = p
        self.label = label
    }

    func stop() {
        if let p = proc, p.isRunning { p.terminate() }
        proc = nil
        label = ""
    }
}
