import Foundation

/// One GitHub repo, optionally resolved to a local clone.
struct GitHubRepo: Codable, Identifiable, Sendable, Equatable {
    var nameWithOwner: String   // "neuroccm/LogiKeyPadMacOSSwift"
    var name: String
    var url: String
    var pushedAt: Date
    var isPrivate: Bool
    var localPath: String?      // absolute path when a clone was found
    var id: String { nameWithOwner }
    var slug: String { nameWithOwner.lowercased() }
}

/// Syncs the user's GitHub repos via `gh` and resolves local clones by
/// scanning the usual roots for .git/config origin URLs (file reads only —
/// no per-repo process spawns). Results are cached for instant, offline UI.
@MainActor
final class GitHubSync: ObservableObject {
    @Published private(set) var repos: [GitHubRepo] = []
    @Published private(set) var syncing = false
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?

    var onLog: ((String) -> Void)?

    private struct Cache: Codable {
        var syncedAt: Date
        var repos: [GitHubRepo]
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LogiKeyPad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("github.json")
    }

    func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let cache = try? dec.decode(Cache.self, from: data) {
            repos = cache.repos
            lastSynced = cache.syncedAt
        }
    }

    /// Syncs when cache is older than `maxAge` (default 6h). Cheap no-op otherwise.
    func syncIfStale(maxAge: TimeInterval = 6 * 3600) async {
        if let lastSynced, Date().timeIntervalSince(lastSynced) < maxAge, !repos.isEmpty { return }
        await sync()
    }

    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        let r = await Shell.gh(
            ["repo", "list", "--limit", "100",
             "--json", "nameWithOwner,name,url,pushedAt,isPrivate"],
            cwd: NSHomeDirectory(), timeout: 60)
        guard r.ok else {
            lastError = r.trimmed.isEmpty ? "gh repo list failed (is gh authenticated?)" : r.trimmed
            onLog?("GitHub sync failed: \(lastError!)")
            return
        }
        guard var fresh = Self.parseRepoList(Data(r.out.utf8)) else {
            lastError = "Could not parse gh output"
            onLog?("GitHub sync failed: \(lastError!)")
            return
        }
        let local = await Task.detached { Self.scanLocalClones() }.value
        for i in fresh.indices { fresh[i].localPath = local[fresh[i].slug] }
        repos = fresh
        lastSynced = Date()
        lastError = nil
        saveCache()
        let found = fresh.filter { $0.localPath != nil }.count
        onLog?("GitHub sync: \(fresh.count) repos, \(found) cloned locally.")
    }

    func markCloned(slug: String, path: String) {
        if let i = repos.firstIndex(where: { $0.slug == slug.lowercased() }) {
            repos[i].localPath = path
            saveCache()
        }
    }

    private func saveCache() {
        guard let lastSynced else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(Cache(syncedAt: lastSynced, repos: repos)) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    // MARK: - Pure helpers (tested)

    nonisolated static func parseRepoList(_ data: Data) -> [GitHubRepo]? {
        struct Row: Decodable {
            let nameWithOwner: String
            let name: String
            let url: String
            let pushedAt: Date
            let isPrivate: Bool
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let rows = try? dec.decode([Row].self, from: data) else { return nil }
        return rows
            .map { GitHubRepo(nameWithOwner: $0.nameWithOwner, name: $0.name, url: $0.url,
                              pushedAt: $0.pushedAt, isPrivate: $0.isPrivate, localPath: nil) }
            .sorted { $0.pushedAt > $1.pushedAt }
    }

    /// Normalizes any github remote URL form to "owner/repo" (lowercased).
    nonisolated static func slug(fromRemoteURL raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["git@github.com:", "ssh://git@github.com/",
                       "https://github.com/", "http://github.com/",
                       "git://github.com/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
            let parts = s.split(separator: "/")
            return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
        }
        return nil
    }

    /// Extracts the origin URL from a .git/config text without spawning git.
    nonisolated static func originURL(gitConfigText: String) -> String? {
        var inOrigin = false
        for line in gitConfigText.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inOrigin = (t == "[remote \"origin\"]"); continue }
            if inOrigin, t.hasPrefix("url") {
                let parts = t.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    /// Roots scanned for local clones (depth 2), most specific first.
    nonisolated static func scanRoots() -> [String] {
        let home = NSHomeDirectory()
        return ["Developer", "Downloads", "Documents", "Projects", "src", "code"]
            .map { (home as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// slug -> local path for every clone found under the scan roots.
    nonisolated static func scanLocalClones() -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        var examined = 0
        for root in scanRoots() {
            for candidate in Self.candidateDirs(under: root, fm: fm) {
                examined += 1
                if examined > 800 { return out }  // hard cap: stay lightweight
                let configPath = (candidate as NSString).appendingPathComponent(".git/config")
                guard let text = try? String(contentsOfFile: configPath, encoding: .utf8),
                      let url = originURL(gitConfigText: text),
                      let slug = slug(fromRemoteURL: url) else { continue }
                if out[slug] == nil { out[slug] = candidate }
            }
        }
        return out
    }

    /// Dirs at depth 1 and 2 under root that contain a .git directory.
    nonisolated private static func candidateDirs(under root: String, fm: FileManager) -> [String] {
        var result: [String] = []
        func isRepo(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git"), isDirectory: &isDir) && isDir.boolValue
        }
        func children(_ path: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0 != "node_modules" }
                .map { (path as NSString).appendingPathComponent($0) }
                .filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
        }
        if isRepo(root) { result.append(root) }
        for d1 in children(root) {
            if isRepo(d1) { result.append(d1); continue }
            for d2 in children(d1) where isRepo(d2) { result.append(d2) }
        }
        return result
    }

    /// Default parent directory for new clones.
    nonisolated static func defaultCloneParent() -> String {
        let home = NSHomeDirectory()
        for name in ["Developer", "Downloads", "Documents"] {
            let p = (home as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return home
    }
}
