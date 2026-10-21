import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var github: GitHubSync
    @State private var showRepoPicker = false

    private var pageIndex: Int { app.devicePage }
    private var pageBinding: Binding<Int> {
        Binding(get: { app.devicePage }, set: { app.devicePage = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            keyGrid
            Divider()
            commitRow
            logView
            footer
        }
        .confirmationDialog(
            "Run “\(app.pendingConfirm?.title ?? "")”?",
            isPresented: Binding(get: { app.pendingConfirm != nil },
                                 set: { if !$0 { app.pendingConfirm = nil } }),
            titleVisibility: .visible
        ) {
            Button("Run", role: .destructive) {
                guard let action = app.pendingConfirm else { return }
                app.pendingConfirm = nil
                Task { await app.fire(action, confirmed: true) }
            }
            Button("Cancel", role: .cancel) { app.pendingConfirm = nil }
        } message: {
            Text("This action changes or removes files in the selected repo.")
        }
    }

    // MARK: Header — repo + live state + health

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(repoName).font(.title3).bold().lineLimit(1)
                Text(stateSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            healthDot(ok: app.hid.connected, label: "Keypad HID")
            Button("Repos…") { showRepoPicker = true }
                .popover(isPresented: $showRepoPicker, arrowEdge: .bottom) { repoPicker }
            Button { app.monitor.scheduleRefresh(includeCI: true); app.refreshHealth() } label: {
                Image(systemName: "arrow.clockwise")
            }.help("Refresh git + CI state")
        }
        .padding(12)
    }

    private var repoName: String {
        app.config.repoPath.isEmpty ? "No repo selected" : (app.config.repoPath as NSString).lastPathComponent
    }

    private var stateSummary: String {
        let s = app.monitor.state
        guard s.isRepo else { return app.config.repoPath.isEmpty ? "Pick a git repo to arm the keys" : "Not a git repo" }
        var parts = ["⌥ \(s.branch)", "\(s.staged) staged", "\(s.dirty) dirty", "↑\(s.ahead) ↓\(s.behind)"]
        parts.append("CI: \(s.ci.rawValue)")
        parts.append(app.monitor.projectKind.rawValue)
        if let p = app.pomodoroText { parts.append("🍅 \(p)") }
        return parts.joined(separator: " · ")
    }

    private func healthDot(ok: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Repo picker — GitHub recent pushes, resolved to local clones

    private var recentBinding: Binding<Int> {
        Binding(get: { app.config.recentCount },
                set: { app.config.recentCount = $0; app.saveConfig() })
    }

    private var relativeTime: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }

    private var repoPicker: some View {
        VStack(spacing: 0) {
            HStack {
                Text("GitHub — recent pushes").font(.headline)
                Spacer()
                Picker("Show", selection: recentBinding) {
                    Text("Recent 5").tag(5)
                    Text("Recent 10").tag(10)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            .padding(12)

            Divider()

            if github.syncing && github.repos.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Syncing GitHub…") }
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if github.repos.isEmpty {
                Text(github.lastError ?? "No GitHub repos yet — press Sync GitHub.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                List {
                    ForEach(Array(github.repos.prefix(app.config.recentCount))) { repo in
                        repoRow(repo)
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    Task { await github.sync() }
                } label: {
                    if github.syncing { ProgressView().controlSize(.small) }
                    Text("Sync GitHub")
                }
                .disabled(github.syncing)
                if let last = github.lastSynced {
                    Text("synced \(relativeTime.localizedString(for: last, relativeTo: Date()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Folder…") { showRepoPicker = false; chooseRepo() }
            }
            .padding(12)
        }
        .frame(width: 470, height: 430)
    }

    private func repoRow(_ repo: GitHubRepo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(repo.name).font(.body).bold()
                    if repo.isPrivate {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(repo.nameWithOwner).font(.caption).foregroundStyle(.secondary)
                }
                Text(subtitle(for: repo))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if app.cloningSlug == repo.slug {
                ProgressView().controlSize(.small)
                Text("Cloning…").font(.caption)
            } else if repo.localPath == nil {
                Button("Clone") { Task { await app.cloneRepo(repo) } }
                    .controlSize(.small)
            } else if repo.localPath == app.config.repoPath {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let path = repo.localPath {
                app.setRepo(path)
                showRepoPicker = false
            }
        }
        .padding(.vertical, 3)
    }

    private func subtitle(for repo: GitHubRepo) -> String {
        let pushed = "pushed \(relativeTime.localizedString(for: repo.pushedAt, relativeTo: Date()))"
        guard let path = repo.localPath else { return "\(pushed) · not cloned" }
        let home = NSHomeDirectory()
        let pretty = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return "\(pushed) · \(pretty)"
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Repo"
        panel.message = "Choose the git repo the keys should act on"
        if panel.runModal() == .OK, let url = panel.url {
            app.setRepo(url.path)
        }
    }

    // MARK: Controls — theme, editor, terminal, pages

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Theme", selection: themeBinding) {
                ForEach(PadTheme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 236)

            Picker("Editor", selection: editorBinding) {
                Text("VS Code").tag("Visual Studio Code")
                Text("Cursor").tag("Cursor")
                Text("BBEdit").tag("BBEdit")
                Text("Xcode").tag("Xcode")
            }
            .frame(width: 134)

            Picker("Terminal", selection: terminalBinding) {
                Text("Terminal").tag("Terminal")
                Text("Ghostty").tag("Ghostty")
            }
            .frame(width: 134)

            Spacer()

            Picker("Page", selection: pageBinding) {
                ForEach(Array(app.config.pages.enumerated()), id: \.offset) { i, page in
                    Text(page.title).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 340, maxWidth: 440)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var themeBinding: Binding<PadTheme> {
        Binding(get: { app.config.theme },
                set: { app.config.theme = $0; app.saveConfig() })
    }
    private var editorBinding: Binding<String> {
        Binding(get: { app.config.editorApp },
                set: { app.config.editorApp = $0; app.saveConfig() })
    }
    private var execBinding: Binding<String> {
        Binding(get: { app.config.executionMode },
                set: { app.config.executionMode = $0; app.saveConfig() })
    }
    private var terminalBinding: Binding<String> {
        Binding(get: { app.config.terminalApp },
                set: { app.config.terminalApp = $0; app.saveConfig() })
    }

    // MARK: 3×3 key grid — mirrors the physical keypad

    private var keyGrid: some View {
        let page = app.config.pages.indices.contains(pageIndex) ? app.config.pages[pageIndex] : nil
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(0..<9, id: \.self) { slot in
                let actionID = (page?.keys.indices.contains(slot) == true) ? page!.keys[slot] : ""
                let action = app.catalog.action(actionID)
                KeyButton(action: action, theme: app.config.theme) {
                    if let action { Task { await app.fire(action) } }
                }
                .contextMenu {
                    Menu("Assign key \(slot + 1)") {
                        ForEach(app.catalog.actions) { candidate in
                            Button("\(candidate.title)\(candidate.sub.isEmpty ? "" : " · \(candidate.sub)")") {
                                assign(candidate.id, page: pageIndex, slot: slot)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func assign(_ actionID: String, page: Int, slot: Int) {
        guard app.config.pages.indices.contains(page),
              app.config.pages[page].keys.indices.contains(slot) else { return }
        app.config.pages[page].keys[slot] = actionID
        app.saveConfig()
        app.monitor.log("Key reassigned (page “\(app.config.pages[page].title)”, slot \(slot + 1)) → \(actionID).")
    }

    // MARK: Commit row + log + footer

    private var commitRow: some View {
        HStack(spacing: 8) {
            TextField("Commit message (used by the Commit key)", text: $app.commitMessage)
                .textFieldStyle(.roundedBorder)
                .onSubmit { fireByID("commit") }
            Button("Stage") { fireByID("stage_all") }
            Button("Commit") { fireByID("commit") }
            Button("Push") { fireByID("push") }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func fireByID(_ id: String) {
        guard let action = app.catalog.action(id) else { return }
        Task { await app.fire(action) }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(app.monitor.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: app.monitor.logLines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .frame(minHeight: 120)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Launch at login", isOn: Binding(
                get: { app.launchAtLogin },
                set: { app.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
            Picker("Run", selection: execBinding) {
                Text("Visible").tag("visible")
                Text("In app").tag("headless")
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .help("Visible: Git/Build commands run in your Terminal window for this repo. In app: headless, output in the log.")
            Text("Click a key to test-fire · right-click to reassign")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Reveal Config") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [BridgeServer.tokenFileURL().deletingLastPathComponent()])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One LCD-key mirror: themed background, white SF Symbol + label —
/// the same face the plugin SVG generator puts on the device.
struct KeyButton: View {
    let action: CatalogAction?
    let theme: PadTheme
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Image(systemName: action?.symbol ?? "questionmark")
                    .font(.system(size: 26, weight: .medium))
                Text(action?.title ?? "—")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let sub = action?.sub, !sub.isEmpty {
                    Text(sub).font(.system(size: 10)).opacity(0.75).lineLimit(1)
                }
            }
            .foregroundStyle(theme.keyForeground)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.keyBackground))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}
