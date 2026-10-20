import XCTest
@testable import LogiKeyPad

final class LogiKeyPadTests: XCTestCase {

    func testCatalogLoadsAndPagesReferenceRealActions() {
        let catalog = Catalog.load()
        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(catalog.actions.count, 36)
        XCTAssertEqual(Set(catalog.actions.map(\.id)).count, 36, "action ids must be unique")
        for page in catalog.pages {
            XCTAssertEqual(page.keys.count, 9, "page \(page.id) must fill the 3x3 keypad")
            for key in page.keys {
                XCTAssertNotNil(catalog.action(key), "page \(page.id) references unknown action \(key)")
            }
        }
    }

    func testPorcelainParsing() {
        let sample = """
        # branch.oid abc123
        # branch.head feature/keys
        # branch.upstream origin/feature/keys
        # branch.ab +2 -1
        1 M. N... 100644 100644 100644 aaa bbb staged.swift
        1 .M N... 100644 100644 100644 aaa bbb dirty.swift
        ? untracked.txt
        """
        let s = RepoState.parse(porcelain: sample, stashCount: 1)
        XCTAssertEqual(s.branch, "feature/keys")
        XCTAssertEqual(s.staged, 1)
        XCTAssertEqual(s.dirty, 2)
        XCTAssertEqual(s.ahead, 2)
        XCTAssertEqual(s.behind, 1)
        XCTAssertTrue(s.hasStash)
        XCTAssertTrue(s.isRepo)
    }

    func testCIClassification() {
        XCTAssertEqual(RepoMonitor.classifyCI(""), .none)
        XCTAssertEqual(RepoMonitor.classifyCI("SUCCESS,SUCCESS"), .pass)
        XCTAssertEqual(RepoMonitor.classifyCI("SUCCESS,FAILURE"), .fail)
        XCTAssertEqual(RepoMonitor.classifyCI("IN_PROGRESS"), .pending)
    }

    func testBridgeMessageRoundTrip() throws {
        let msg = BridgeMessage(type: "key", id: "build", token: "t")
        let data = try JSONEncoder().encode(msg)
        let back = try JSONDecoder().decode(BridgeMessage.self, from: data)
        XCTAssertEqual(back.type, "key")
        XCTAssertEqual(back.id, "build")
        XCTAssertEqual(back.v, 1)
    }

    func testBridgeMessageDecodesPartialPluginJSON() throws {
        // The Node plugin sends sparse messages; missing keys must default.
        let hello = #"{"v":1,"type":"hello","token":"abc"}"#
        let msg = try JSONDecoder().decode(BridgeMessage.self, from: Data(hello.utf8))
        XCTAssertEqual(msg.type, "hello")
        XCTAssertEqual(msg.token, "abc")
        XCTAssertEqual(msg.id, "")
        XCTAssertTrue(msg.ok)
        let key = #"{"v":1,"type":"key","id":"build"}"#
        let k = try JSONDecoder().decode(BridgeMessage.self, from: Data(key.utf8))
        XCTAssertEqual(k.id, "build")
    }

    // MARK: Direct-HID protocol (verified live; scripts/hid-probe.swift)

    func testHIDPPRequestFramingIncludesReportID() {
        let ping = HIDPP.request(feature: 0x00, function: 1, params: [0xAA, 0xBB, 0xCC])
        XCTAssertEqual(ping.count, 20)
        XCTAssertEqual(Array(ping.prefix(7)), [0x11, 0xFF, 0x00, 0x1B, 0xAA, 0xBB, 0xCC])
        let divert = HIDPP.divertPageButton(control: 0x01A1)
        XCTAssertEqual(Array(divert.prefix(7)), [0x11, 0xFF, 0x0B, 0x3B, 0x01, 0xA1, 0x03])
    }

    func testButtonReportParsing() {
        // Captured shape: FF 02 00 <seq> 01 <key ids...> 00
        XCTAssertEqual(HIDPP.parseButtonReport([0xFF, 0x02, 0x00, 0xC9, 0x01, 0x02, 0x05, 0x00]), [2, 5])
        XCTAssertEqual(HIDPP.parseButtonReport([0xFF, 0x02, 0x00, 0xC0, 0x01, 0x00]), [])
        XCTAssertNil(HIDPP.parseButtonReport([0xFF, 0x02, 0x2B, 0xC1, 0x00]))  // image ack, not buttons
        XCTAssertTrue(HIDPP.isImageAck([0xFF, 0x02, 0x2B, 0xC1, 0x00]))
        XCTAssertEqual(HIDPP.parsePageReport([0xFF, 0x0B, 0x00, 0x01, 0xA2, 0x00, 0x00]), [0x01A2])
    }

    func testImagePacketHeaderAndChunking() {
        let jpeg = [UInt8](repeating: 0xAB, count: 9000)
        let packets = ImagePacket.make(jpeg: jpeg, x: 181, y: 164, w: 118, h: 118)
        XCTAssertEqual(packets.count, 3)  // 4075 + 4090 + 835 payload bytes
        let p1 = packets[0]
        XCTAssertEqual(p1.count, 4095)
        XCTAssertEqual(Array(p1.prefix(5)), [0x14, 0xFF, 0x02, 0x2B, 0b10100001])
        XCTAssertEqual(Array(p1[9..<11]), [0x00, 0xB5])        // x=181 BE
        XCTAssertEqual(Array(p1[11..<13]), [0x00, 0xA4])       // y=164 BE
        XCTAssertEqual(Array(p1[18..<20]), [0x23, 0x28])       // total 9000 BE
        XCTAssertEqual(packets[2][4], 0b01100011)              // part 3, last
        // Reassembled payloads reproduce the JPEG exactly.
        var joined = [UInt8](packets[0][20...])
        joined += packets[1][5...]
        joined += packets[2][5...]
        XCTAssertEqual(Array(joined.prefix(9000)), jpeg)
    }

    func testPanelRenderProduces480JPEG() throws {
        let catalog = Catalog.load()
        let actions = catalog.pages[0].keys.map { catalog.action($0) }
        let badges = [0: KeyArt.Badge(text: "main", color: .white)]
        for theme in PadTheme.allCases {
            let jpeg = try XCTUnwrap(KeyArt.panelJPEG(actions: actions, theme: theme, badges: badges))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
            XCTAssertEqual(rep.pixelsWide, 480)
            XCTAssertEqual(rep.pixelsHigh, 480)
            XCTAssertLessThan(jpeg.count, 65_535, "panel JPEG must fit the uint16 length field")
            // Keep one render around for visual inspection during development.
            if theme == .midnight {
                try jpeg.write(to: URL(fileURLWithPath: "/tmp/logikeypad-panel-check.jpg"))
            }
        }
        let tile = try XCTUnwrap(KeyArt.tileJPEG(action: actions[0], theme: .blueprint, badge: nil))
        XCTAssertEqual(NSBitmapImageRep(data: tile)?.pixelsWide, 118)
    }

    // MARK: GitHub sync

    func testRemoteURLSlugNormalization() {
        XCTAssertEqual(GitHubSync.slug(fromRemoteURL: "git@github.com:NeuroCCM/LogiKeyPadMacOSSwift.git"),
                       "neuroccm/logikeypadmacosswift")
        XCTAssertEqual(GitHubSync.slug(fromRemoteURL: "https://github.com/aprilnea/openlogi.git"),
                       "aprilnea/openlogi")
        XCTAssertEqual(GitHubSync.slug(fromRemoteURL: "ssh://git@github.com/julusian/node-logitech-mx-creative-console"),
                       "julusian/node-logitech-mx-creative-console")
        XCTAssertNil(GitHubSync.slug(fromRemoteURL: "git@gitlab.com:someone/repo.git"))
        XCTAssertNil(GitHubSync.slug(fromRemoteURL: "/local/path/repo"))
    }

    func testOriginURLExtractionFromGitConfig() {
        let config = """
        [core]
            bare = false
        [remote "upstream"]
            url = https://github.com/other/repo.git
        [remote "origin"]
            url = git@github.com:neuroccm/LogiKeyPadMacOSSwift.git
            fetch = +refs/heads/*:refs/remotes/origin/*
        """
        XCTAssertEqual(GitHubSync.originURL(gitConfigText: config),
                       "git@github.com:neuroccm/LogiKeyPadMacOSSwift.git")
    }

    func testRepoListParsingSortsByPushedAt() {
        let json = """
        [{"nameWithOwner":"a/old","name":"old","url":"https://github.com/a/old","pushedAt":"2026-01-01T00:00:00Z","isPrivate":false},
         {"nameWithOwner":"a/new","name":"new","url":"https://github.com/a/new","pushedAt":"2026-10-18T00:00:00Z","isPrivate":true}]
        """
        let repos = GitHubSync.parseRepoList(Data(json.utf8))
        XCTAssertEqual(repos?.map(\.name), ["new", "old"])
        XCTAssertEqual(repos?.first?.isPrivate, true)
    }

    func testOldConfigWithoutRecentCountStillDecodes() throws {
        let old = #"{"theme":"blueprint","repoPath":"/tmp/x","pages":[],"editorApp":"Cursor","terminalApp":"Ghostty"}"#
        let cfg = try JSONDecoder().decode(PadConfig.self, from: Data(old.utf8))
        XCTAssertEqual(cfg.recentCount, 5)
        XCTAssertEqual(cfg.theme, .blueprint)
        XCTAssertEqual(cfg.editorApp, "Cursor")
    }

    func testThemesAreBlackOrBlueWithWhiteText() {
        XCTAssertEqual(PadTheme.midnight.svgBackground, "#000000")
        XCTAssertEqual(PadTheme.blueprint.svgBackground, "#052ED9")
        XCTAssertEqual(PadTheme.allCases.count, 2)
    }
}
