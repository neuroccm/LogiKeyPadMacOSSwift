import Foundation
import Network

/// Loopback-only bridge between the Logi Actions SDK plugin (Node) and
/// this app. Newline-delimited JSON. A shared token (file in Application
/// Support, mode 0600) is required on `hello` because key messages can
/// ultimately run shell commands — other local processes must not be
/// able to drive the pad.
@MainActor
final class BridgeServer: ObservableObject {
    @Published private(set) var pluginConnected = false

    static let port: NWEndpoint.Port = 47831

    var onKey: ((String) async -> (ok: Bool, text: String))?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var authenticated = false
    private let token: String

    init() { token = Self.loadOrCreateToken() }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback  // never reachable off-device
        guard let l = try? NWListener(using: params, on: Self.port) else { return }
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        l.stateUpdateHandler = { state in
            if case .failed = state { /* port busy: another copy is running */ }
        }
        l.start(queue: .main)
        listener = l
    }

    // MARK: Sending

    func pushState(summary: String) {
        send(BridgeMessage(type: "state", text: summary))
    }

    private func send(_ msg: BridgeMessage) {
        guard let connection, authenticated,
              var data = try? JSONEncoder().encode(msg) else { return }
        data.append(0x0A)  // newline framing
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: Receiving

    private func accept(_ conn: NWConnection) {
        connection?.cancel()  // single plugin client; newest wins
        connection = conn
        authenticated = false
        buffer.removeAll()
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .cancelled = state { self?.pluginConnected = false; self?.authenticated = false }
                if case .failed = state { self?.pluginConnected = false; self?.authenticated = false }
            }
        }
        conn.start(queue: .main)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.consume(data) }
                if isComplete { self.pluginConnected = false; self.authenticated = false; return }
                self.receive(on: conn)
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        if buffer.count > 256 * 1024 { buffer.removeAll(); return }  // abuse cap
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<nl]
            buffer.removeSubrange(...nl)
            if let msg = try? JSONDecoder().decode(BridgeMessage.self, from: Data(line)) {
                handle(msg)
            }
        }
    }

    private func handle(_ msg: BridgeMessage) {
        switch msg.type {
        case "hello":
            authenticated = (msg.token == token) && msg.v == 1
            pluginConnected = authenticated
            if authenticated { send(BridgeMessage(type: "hello", text: "LogiKeyPad ready")) }
        case "key":
            guard authenticated, let onKey else { return }
            let id = msg.id
            Task { [weak self] in
                let r = await onKey(id)
                self?.send(BridgeMessage(type: "result", id: id, ok: r.ok, text: r.text))
            }
        default:
            break
        }
    }

    // MARK: Token file (shared with the plugin)

    static func tokenFileURL() -> URL {
        AppPaths.supportDir.appendingPathComponent("bridge-token")
    }

    private static func loadOrCreateToken() -> String {
        let url = tokenFileURL()
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 16 { return t }
        }
        let t = UUID().uuidString + UUID().uuidString
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }
}
