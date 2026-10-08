import Foundation

enum ACPError: Error, LocalizedError {
    case spawnFailed(String)
    case rpc(code: Int, message: String)
    case closed
    case badResponse

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let s): return "Couldn't start the agent: \(s)"
        case .rpc(let code, let msg): return "Agent error \(code): \(msg)"
        case .closed: return "Agent process exited"
        case .badResponse: return "Malformed reply from agent"
        }
    }
}

/// Speaks the Agent Client Protocol over an agent subprocess's stdio:
/// newline-delimited JSON-RPC 2.0 frames in both directions.
///
/// Client-side methods implemented for agents to call:
///   fs/read_text_file, fs/write_text_file, terminal/*  — handled internally.
///   session/request_permission                         — forwarded to the UI
///   via `onPermissionRequest`, which must call `respond(toRequest:result:)`.
actor ACPClient {
    /// Agent → UI events. Called on the actor; hop to MainActor inside.
    var onSessionUpdate: @Sendable (JSONValue) -> Void = { _ in }
    var onNotification: @Sendable (_ method: String, _ params: JSONValue) -> Void = { _, _ in }
    /// Agent asked the user for permission. Reply with `respond(toRequest:result:)`.
    var onPermissionRequest: @Sendable (_ requestId: JSONValue, _ params: JSONValue) -> Void = { _, _ in }
    var onExit: @Sendable (Int32) -> Void = { _ in }

    private(set) var agentCapabilities: JSONValue = .null
    private(set) var authMethods: [JSONValue] = []

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stderrLog: FileHandle?
    private var traceLog: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var terminals: [String: Terminal] = [:]
    private var sessionCwd: String = NSHomeDirectory()

    /// One place for the session layer to attach its UI callbacks.
    func setHandlers(
        onUpdate: @escaping @Sendable (JSONValue) -> Void,
        onPermission: @escaping @Sendable (JSONValue, JSONValue) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.onSessionUpdate = onUpdate
        self.onPermissionRequest = onPermission
        self.onExit = onExit
    }

    func setCapabilities(_ caps: JSONValue, auth: [JSONValue]) {
        self.agentCapabilities = caps
        self.authMethods = auth
    }

    // MARK: - Lifecycle

    func start(command: String, cwd: String, env: [String: String], logPath: String) throws {
        stop()
        sessionCwd = cwd

        let log = URL(fileURLWithPath: logPath)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        stderrLog = try? FileHandle(forWritingTo: log)
        stderrLog?.seekToEndOfFile()

        let trace = log.deletingLastPathComponent().appendingPathComponent("acp-trace.log")
        FileManager.default.createFile(atPath: trace.path, contents: nil)
        traceLog = try? FileHandle(forWritingTo: trace)
        traceLog?.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -l: login shell so PATH picks up homebrew/nvm/etc.
        p.arguments = ["-l", "-c", "exec \(command)"]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var envVars = ProcessInfo.processInfo.environment
        for (k, v) in env { envVars[k] = v }
        // Headless hints for agent CLIs that otherwise try to open browsers.
        envVars["NO_BROWSER"] = envVars["NO_BROWSER"] ?? "1"
        envVars["TERM"] = "dumb"
        p.environment = envVars

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        stdinHandle = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                Task { await self?.stdoutClosed() }
                return
            }
            Task { await self?.ingest(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            Task { await self?.writeStderr(data) }
        }
        p.terminationHandler = { [weak self] p in
            Task { await self?.didExit(p.terminationStatus) }
        }

        do { try p.run() } catch {
            throw ACPError.spawnFailed(error.localizedDescription)
        }
        process = p
    }

    func stop() {
        process?.terminationHandler = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        stdinHandle = nil
        let pend = pending
        pending.removeAll()
        for (_, c) in pend { c.resume(throwing: ACPError.closed) }
        for (id, t) in terminals { t.kill(); terminals.removeValue(forKey: id) }
    }

    private func writeStderr(_ data: Data) {
        try? stderrLog?.write(contentsOf: data)
    }

    // MARK: - RPC

    @discardableResult
    func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        let id = nextId
        nextId += 1
        let msg: JSONValue = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]
        // Register the continuation before writing — a fast agent can answer
        // within a single runloop turn and the reply must find `pending`.
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            do {
                try send(msg)
            } catch {
                pending.removeValue(forKey: id)
                c.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String, params: JSONValue = .object([:])) {
        try? send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    /// Reply to an agent→client request (e.g. session/request_permission).
    func respond(toRequest id: JSONValue, result: JSONValue) {
        try? send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respondError(toRequest id: JSONValue, code: Int, message: String) {
        try? send(["jsonrpc": "2.0", "id": id,
                   "error": ["code": .int(code), "message": .string(message)]])
    }

    private func send(_ msg: JSONValue) throws {
        guard let stdinHandle else { throw ACPError.closed }
        let data = try JSONSerialization.data(withJSONObject: msg.anyObject)
        trace(">", line: data)
        stdinHandle.write(data)
        stdinHandle.write(Data([0x0a]))
    }

    private func trace(_ dir: String, line: Data) {
        guard let traceLog else { return }
        var out = Data(dir.utf8); out.append(0x20); out.append(line); out.append(0x0a)
        try? traceLog.write(contentsOf: out)
    }

    // MARK: - Incoming

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = buffer.subdata(in: 0..<nl)
            buffer.removeSubrange(0...nl)
            guard !line.isEmpty,
                  let any = try? JSONSerialization.jsonObject(with: line)
            else { continue }
            trace("<", line: line)
            dispatch(JSONValue(any))
        }
    }

    private func dispatch(_ msg: JSONValue) {
        let hasId = msg["id"] != nil
        let hasMethod = msg["method"] != nil

        if hasMethod && hasId, let id = msg["id"] {
            handleAgentRequest(id: id, msg: msg)    // agent → client request
        } else if hasMethod {
            let method = msg["method"]?.string ?? ""
            let params = msg["params"] ?? .null
            if method == "session/update" {
                onSessionUpdate(params)
            } else {
                onNotification(method, params)
            }
        } else if hasId, let id = msg["id"]?.int {
            if let c = pending.removeValue(forKey: id) {
                if let err = msg["error"] {
                    c.resume(throwing: ACPError.rpc(
                        code: err["code"]?.int ?? -1,
                        message: err["message"]?.string ?? "unknown error"))
                } else {
                    c.resume(returning: msg["result"] ?? .object([:]))
                }
            }
        }
    }

    private func stdoutClosed() {
        didExit(process?.terminationStatus ?? -1)
    }

    private func didExit(_ status: Int32) {
        let pend = pending
        pending.removeAll()
        for (_, c) in pend { c.resume(throwing: ACPError.closed) }
        onExit(status)
    }

    // MARK: - Agent → client requests

    private func handleAgentRequest(id: JSONValue, msg: JSONValue) {
        let method = msg["method"]?.string ?? ""
        let params = msg["params"] ?? .object([:])

        switch method {
        case "session/request_permission":
            onPermissionRequest(id, params)

        case "fs/read_text_file":
            do { respond(toRequest: id, result: try readTextFile(params)) }
            catch { respondError(toRequest: id, code: -32602, message: "\(error)") }

        case "fs/write_text_file":
            do { respond(toRequest: id, result: try writeTextFile(params)) }
            catch { respondError(toRequest: id, code: -32602, message: "\(error)") }

        case "terminal/create":
            do { respond(toRequest: id, result: try terminalCreate(params)) }
            catch { respondError(toRequest: id, code: -32602, message: "\(error)") }

        case "terminal/output":
            respond(toRequest: id, result: terminalOutput(params))

        case "terminal/release":
            if let tid = params["terminalId"]?.string, let t = terminals.removeValue(forKey: tid) {
                t.kill()
            }
            respond(toRequest: id, result: .object([:]))

        case "terminal/kill":
            if let tid = params["terminalId"]?.string { terminals[tid]?.kill() }
            respond(toRequest: id, result: .object([:]))

        case "terminal/wait_for_exit":
            Task { await terminalWaitForExit(id: id, params: params) }

        default:
            respondError(toRequest: id, code: -32601, message: "cmdcmd doesn't implement \(method)")
        }
    }

    // MARK: - fs/*

    private func readTextFile(_ params: JSONValue) throws -> JSONValue {
        guard let path = params["path"]?.string else {
            throw ACPError.rpc(code: -32602, message: "fs/read_text_file: missing path")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var content = text
        // Optional 1-based `line` + `limit` window.
        if let line = params["line"]?.int, line > 0 {
            let lines = text.components(separatedBy: "\n")
            let start = min(line - 1, lines.count)
            let end = params["limit"]?.int
            let last = min(start + (end ?? lines.count), lines.count)
            content = lines[start..<last].joined(separator: "\n")
        }
        return ["content": .string(content)]
    }

    private func writeTextFile(_ params: JSONValue) throws -> JSONValue {
        guard let path = params["path"]?.string,
              let content = params["content"]?.string else {
            throw ACPError.rpc(code: -32602, message: "fs/write_text_file: missing path/content")
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return .object([:])
    }

    // MARK: - terminal/*

    private func terminalCreate(_ params: JSONValue) throws -> JSONValue {
        guard let command = params["command"]?.string else {
            throw ACPError.rpc(code: -32602, message: "terminal/create: missing command")
        }
        let id = UUID().uuidString
        var env: [String: String] = [:]
        if let arr = params["env"]?.array {
            for e in arr {
                if let n = e["name"]?.string, let v = e["value"]?.string { env[n] = v }
            }
        }
        let t = Terminal(command: command,
                         cwd: params["cwd"]?.string ?? sessionCwd,
                         env: env)
        terminals[id] = t
        return ["terminalId": .string(id)]
    }

    private func terminalOutput(_ params: JSONValue) -> JSONValue {
        guard let tid = params["terminalId"]?.string,
              let t = terminals[tid] else {
            return ["output": "", "truncated": false]
        }
        var out: [String: JSONValue] = ["output": .string(t.output()), "truncated": .bool(t.truncated)]
        if let status = t.exitStatus {
            out["exitStatus"] = ["exitCode": .int(Int(status)), "signal": .null]
        }
        return .object(out)
    }

    private func terminalWaitForExit(id: JSONValue, params: JSONValue) async {
        guard let tid = params["terminalId"]?.string,
              let t = terminals[tid] else {
            respond(toRequest: id, result: ["exitStatus": ["exitCode": .int(-1), "signal": .null]])
            return
        }
        let status = await t.wait()
        respond(toRequest: id,
                result: ["exitStatus": ["exitCode": .int(Int(status)), "signal": .null]])
    }
}

/// One `terminal/create` shell invocation: pipes output into a capped buffer.
private final class Terminal: @unchecked Sendable {
    let process = Process()
    private var buf = Data()
    private var lock = NSLock()
    private(set) var truncated = false
    private(set) var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private let cap = 512 * 1024

    init(command: String, cwd: String, env: [String: String]) {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        e["TERM"] = "dumb"
        process.environment = e

        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            self?.append(fh.availableData)
        }
        process.terminationHandler = { [weak self] p in
            self?.finish(p.terminationStatus)
        }
        try? process.run()
    }

    private func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buf.append(data)
        if buf.count > cap {
            buf = buf.suffix(cap / 2)
            truncated = true
        }
    }

    private func finish(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let ws = waiters
        waiters = []
        lock.unlock()
        for w in ws { w.resume(returning: status) }
    }

    func output() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buf, as: UTF8.self)
    }

    func wait() async -> Int32 {
        if let s = exitStatus { return s }
        return await withCheckedContinuation { c in
            lock.lock()
            if let s = exitStatus { lock.unlock(); c.resume(returning: s); return }
            waiters.append(c)
            lock.unlock()
        }
    }

    func kill() {
        if process.isRunning { process.terminate() }
        if exitStatus == nil { finish(-1) }
    }
}
