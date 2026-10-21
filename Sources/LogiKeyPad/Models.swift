import Foundation
import SwiftUI

/// Single source for the Application Support directory.
enum AppPaths {
    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LogiKeyPad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

}

// MARK: - Catalog (single source of truth: Resources/catalog.json)

struct Catalog: Codable, Sendable {
    let version: Int
    let pages: [CatalogPage]
    let actions: [CatalogAction]

    func action(_ id: String) -> CatalogAction? { actions.first { $0.id == id } }

    static func load() -> Catalog {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return Catalog(version: 0, pages: [], actions: [])
        }
        return catalog
    }
}

struct CatalogPage: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    var keys: [String]  // action ids, exactly 9 slots
}

struct CatalogAction: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let sub: String
    let symbol: String  // SF Symbol name (SwiftUI + key-art rendering)
    let kind: Kind
    let arg: String
    var confirm: Bool?  // destructive actions ask in-app first

    enum Kind: String, Codable, Sendable {
        case openApp, terminal, prompt, task, editor, git, github, flow
    }
    var needsConfirm: Bool { confirm == true }
}

// MARK: - Theme (black/white or blue/white, per spec)

enum PadTheme: String, Codable, CaseIterable, Sendable {
    case midnight, blueprint

    var label: String { self == .midnight ? "Midnight" : "Blueprint" }
    var keyBackground: Color { self == .midnight ? .black : Color(red: 0.02, green: 0.18, blue: 0.85) }
    var keyForeground: Color { .white }
    /// Hex used by the plugin SVG generator — keep in sync with keyBackground.
    var svgBackground: String { self == .midnight ? "#000000" : "#052ED9" }
}

// MARK: - User config (pages are reassignable; persisted as JSON)

struct PadConfig: Codable, Sendable {
    var theme: PadTheme = .midnight
    var repoPath: String = ""
    var pages: [CatalogPage]
    var editorApp: String = "Visual Studio Code"
    var terminalApp: String = "Terminal"  // Terminal (scriptable) or Ghostty (open-at-dir)
    var recentCount: Int = 5               // GitHub repo picker: recent 5 or 10
    var executionMode: String = "visible"  // "visible" (your terminal) | "headless" (in app)

    init(theme: PadTheme = .midnight, repoPath: String = "", pages: [CatalogPage],
         editorApp: String = "Visual Studio Code", terminalApp: String = "Terminal",
         recentCount: Int = 5, executionMode: String = "visible") {
        self.theme = theme; self.repoPath = repoPath; self.pages = pages
        self.editorApp = editorApp; self.terminalApp = terminalApp
        self.recentCount = recentCount; self.executionMode = executionMode
    }

    // decodeIfPresent throughout: configs written by older builds keep loading
    // as fields are added (synthesized Codable would reject missing keys).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(PadTheme.self, forKey: .theme) ?? .midnight
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? ""
        pages = try c.decodeIfPresent([CatalogPage].self, forKey: .pages) ?? []
        editorApp = try c.decodeIfPresent(String.self, forKey: .editorApp) ?? "Visual Studio Code"
        terminalApp = try c.decodeIfPresent(String.self, forKey: .terminalApp) ?? "Terminal"
        recentCount = try c.decodeIfPresent(Int.self, forKey: .recentCount) ?? 5
        executionMode = try c.decodeIfPresent(String.self, forKey: .executionMode) ?? "visible"
    }

    static func defaults(catalog: Catalog) -> PadConfig {
        PadConfig(pages: catalog.pages)
    }

    private static var fileURL: URL {
        AppPaths.supportDir.appendingPathComponent("config.json")
    }

    static func load(catalog: Catalog) -> PadConfig {
        guard let data = try? Data(contentsOf: fileURL),
              var cfg = try? JSONDecoder().decode(PadConfig.self, from: data) else {
            return defaults(catalog: catalog)
        }
        // Catalog upgrades add pages; never lose the user's existing layout.
        for page in catalog.pages where !cfg.pages.contains(where: { $0.id == page.id }) {
            cfg.pages.append(page)
        }
        return cfg
    }

    func save() {
        guard let data = try? JSONEncoder.pretty.encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

// MARK: - Repo state (rendered in menu bar, window header, and prompts)

struct RepoState: Sendable, Equatable {
    var branch: String = "—"
    var staged: Int = 0
    var dirty: Int = 0
    var ahead: Int = 0
    var behind: Int = 0
    var hasStash: Bool = false
    var ci: CIState = .unknown
    var prURL: String = ""
    var isRepo: Bool = false

    enum CIState: String, Sendable { case unknown, pass, fail, pending, none }

    var menuBarTitle: String {
        guard isRepo else { return "⌨︎" }
        var parts = [branch]
        if dirty > 0 { parts.append("●\(dirty)") }
        if ahead > 0 { parts.append("↑\(ahead)") }
        switch ci {
        case .pass: parts.append("✓")
        case .fail: parts.append("✗")
        case .pending: parts.append("…")
        default: break
        }
        return parts.joined(separator: " ")
    }

    /// Parses `git status --porcelain=v2 --branch` output. Pure + tested.
    static func parse(porcelain: String, stashCount: Int) -> RepoState {
        var s = RepoState()
        s.isRepo = true
        s.hasStash = stashCount > 0
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                s.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // e.g. "# branch.ab +2 -1"
                for tok in line.split(separator: " ").dropFirst(2) {
                    if tok.hasPrefix("+") { s.ahead = Int(tok.dropFirst()) ?? 0 }
                    if tok.hasPrefix("-") { s.behind = Int(tok.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // XY at fixed offset 2...3 in v2 ordinary/rename lines
                let chars = Array(line)
                if chars.count > 3 {
                    if chars[2] != "." { s.staged += 1 }
                    if chars[3] != "." { s.dirty += 1 }
                }
            } else if line.hasPrefix("? ") {
                s.dirty += 1
            }
        }
        return s
    }
}

// MARK: - Bridge wire format (newline-delimited JSON, v1)

struct BridgeMessage: Codable, Sendable {
    var v: Int = 1
    var type: String          // hello | key | result | state
    var id: String = ""        // action id for key/result
    var ok: Bool = true
    var text: String = ""      // human-readable result / state summary
    var token: String = ""     // required on hello

    // Synthesized Codable ignores the defaults above and would reject
    // the plugin's partial messages (e.g. hello has no id/ok/text).
    init(v: Int = 1, type: String, id: String = "", ok: Bool = true, text: String = "", token: String = "") {
        self.v = v; self.type = type; self.id = id; self.ok = ok; self.text = text; self.token = token
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
    }
}
