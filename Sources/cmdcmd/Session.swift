import AppKit
import Foundation

/// One row in the popup transcript.
struct Entry: Identifiable {
    enum Kind { case user, agentText, thought, tool, plan, permission, note }
    var id = UUID()
    var kind: Kind
    var title = ""            // tool title
    var body = ""             // streamed text, plan checklist
    var status = ""           // tool status: pending/in_progress/completed/failed
    var toolCallId = ""       // correlation key for tool updates
    var imageURL: URL?        // screenshot on a user entry
    var files: [URL] = []     // @-mentioned files on a user entry
    var options: [(id: String, name: String, kind: String)] = [] // permission options
}

struct SlashCommand: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var description: String
}

struct ModeOption: Identifiable, Equatable {
    var id: String
    var name: String
    var description: String
}

/// Transcript state for the popup. Mutated from AgentSession callbacks.
@MainActor
final class ChatModel: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var state: State = .idle
    @Published var agentName = ""
    @Published var statusLine = ""
    @Published var commands: [SlashCommand] = []
    @Published var modes: [ModeOption] = []
    @Published var currentMode: String = ""

    enum State: Equatable {
        case idle, starting, ready, prompting, error(String)
    }

    var busy: Bool { state == .starting || state == .prompting }

    func appendUser(text: String, image: URL?, files: [URL]) {
        entries.append(Entry(kind: .user, body: text, imageURL: image, files: files))
    }

    func note(_ text: String) {
        entries.append(Entry(kind: .note, body: text))
    }

    /// Routed session/update params ({sessionId, update:{...}}).
    func apply(update: JSONValue) {
        guard let u = update["update"], let kind = u["sessionUpdate"]?.string else { return }
        switch kind {
        case "agent_message_chunk":
            appendChunk(u, to: .agentText)
        case "agent_thought_chunk":
            appendChunk(u, to: .thought)
        case "tool_call", "tool_call_update":
            upsertTool(u)
        case "plan":
            applyPlan(u)
        case "available_commands_update":
            commands = (u["availableCommands"]?.array ?? []).map {
                SlashCommand(name: $0["name"]?.string ?? "",
                             description: $0["description"]?.string ?? "")
            }
        case "current_mode_update":
            if let m = u["currentModeId"]?.string { currentMode = m }
        case "usage_update":
            if let used = u["used"]?.int, let size = u["size"]?.int {
                statusLine = "\(used / 1000)k / \(size / 1000)k tokens"
            }
        default:
            break
        }
    }

    private func appendChunk(_ u: JSONValue, to kind: Entry.Kind) {
        let content = u["content"] ?? .null
        var piece = ""
        if let t = content["text"]?.string {
            piece = t
        } else if content["type"]?.string == "resource_link" {
            piece = "\n[\(content["name"]?.string ?? content["uri"]?.string ?? "file")]\n"
        } else if content["type"]?.string == "image" {
            piece = "\n[image]\n"
        }
        guard !piece.isEmpty else { return }
        if let last = entries.last, last.kind == kind {
            entries[entries.count - 1].body += piece
        } else {
            entries.append(Entry(kind: kind, body: piece))
        }
    }

    private func upsertTool(_ u: JSONValue) {
        let id = u["toolCallId"]?.string ?? ""
        let title = u["title"]?.string ?? ""
        let status = u["status"]?.string ?? ""
        let kind = u["kind"]?.string ?? "other"
        if let i = entries.firstIndex(where: { $0.kind == .tool && $0.toolCallId == id }) {
            if !title.isEmpty { entries[i].title = title }
            if !status.isEmpty { entries[i].status = status }
            if entries[i].body.isEmpty { entries[i].body = kind }
        } else {
            entries.append(Entry(kind: .tool, title: title.isEmpty ? kind : title,
                                 body: kind, status: status, toolCallId: id))
        }
    }

    private func applyPlan(_ u: JSONValue) {
        let list = u["entries"]?.array ?? []
        let text = list.map { e -> String in
            let status = e["status"]?.string ?? "pending"
            let mark = status == "completed" ? "☑" : status == "in_progress" ? "◐" : "☐"
            return "\(mark) \(e["content"]?.string ?? "")"
        }.joined(separator: "\n")
        if let i = entries.lastIndex(where: { $0.kind == .plan }) {
            entries[i].body = text
        } else {
            entries.append(Entry(kind: .plan, body: text))
        }
    }

    func reset() {
        entries = []
        statusLine = ""
        commands = []
        modes = []
        currentMode = ""
        state = .idle
    }
}

/// Owns one ACP agent subprocess + session. Feeds ChatModel.
@MainActor
final class AgentSession: ObservableObject {
    let chat = ChatModel()
    private let client = ACPClient()
    private var sessionId: String?
    private var imageOK = false
    private var embedOK = false
    private var pendingPermissionIds: [UUID: JSONValue] = [:]

    private var agent: AgentSpec?

    func ensureConnected() {
        let a = Config.agent
        if sessionId != nil && agent == a { return }
        Task { await connect(to: a) }
    }

    func reconnect() {
        Task { await connect(to: Config.agent) }
    }

    private func connect(to spec: AgentSpec) async {
        await client.stop()
        agent = spec
        sessionId = nil
        pendingPermissionIds.removeAll()
        chat.reset()
        chat.agentName = spec.name
        chat.state = .starting
        chat.statusLine = "starting \(spec.name)…"

        await client.setHandlers(
            onUpdate: { [weak self] p in Task { @MainActor in self?.chat.apply(update: p) } },
            onPermission: { [weak self] rid, p in Task { @MainActor in self?.presentPermission(rid, p) } },
            onExit: { [weak self] code in Task { @MainActor in self?.agentExited(code) } }
        )

        do {
            try await client.start(command: spec.command,
                                   cwd: Config.workspaceURL.path,
                                   env: Config.current.env,
                                   logPath: Config.logURL.path)
            let initRes = try await client.request("initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": true, "writeTextFile": true],
                    "terminal": true,
                ],
                "clientInfo": ["name": "cmdcmd", "title": "cmdcmd", "version": "0.1.0"],
            ])
            let caps = initRes["agentCapabilities"] ?? .null
            imageOK = caps["promptCapabilities"]?["image"]?.bool ?? false
            embedOK = caps["promptCapabilities"]?["embeddedContext"]?.bool ?? false
            await client.setCapabilities(caps, auth: initRes["authMethods"]?.array ?? [])

            try await authenticateIfNeeded()

            let res = try await client.request("session/new", params: [
                "cwd": .string(Config.workspaceURL.path),
                "mcpServers": .array([]),
            ])
            sessionId = res["sessionId"]?.string
            applyModes(res)
            chat.state = .ready
            chat.statusLine = ""
        } catch {
            chat.state = .error(error.localizedDescription)
            chat.note("\(error.localizedDescription)\n\(spec.hint)")
            chat.statusLine = "agent failed — see note"
        }
    }

    private func applyModes(_ res: JSONValue) {
        guard let m = res["modes"] else { return }
        chat.currentMode = m["currentModeId"]?.string ?? ""
        chat.modes = (m["availableModes"]?.array ?? []).map {
            ModeOption(id: $0["id"]?.string ?? "",
                       name: $0["name"]?.string ?? "",
                       description: $0["description"]?.string ?? "")
        }
    }

    private func authenticateIfNeeded() async throws {
        let methods = await client.authMethods
        guard !methods.isEmpty else { return }
        // Prefer a non-terminal method (terminal means "log in yourself").
        guard let m = methods.first(where: {
            ($0["type"]?.string ?? "agent") != "terminal"
        }) ?? methods.first,
              let id = m["id"]?.string else { return }
        _ = try? await client.request("authenticate", params: ["methodId": .string(id)])
    }

    private func presentPermission(_ rid: JSONValue, _ params: JSONValue) {
        let tc = params["toolCall"] ?? .null
        let opts = (params["options"]?.array ?? []).map {
            (id: $0["optionId"]?.string ?? "",
             name: $0["name"]?.string ?? "",
             kind: $0["kind"]?.string ?? "")
        }
        let e = Entry(kind: .permission,
                      title: tc["title"]?.string ?? "Permission requested",
                      toolCallId: tc["toolCallId"]?.string ?? "",
                      options: opts)
        pendingPermissionIds[e.id] = rid
        chat.entries.append(e)
    }

    func answerPermission(_ entry: Entry, optionId: String?) {
        guard let rid = pendingPermissionIds.removeValue(forKey: entry.id) else { return }
        let outcome: JSONValue = optionId == nil
            ? ["outcome": "cancelled"]
            : ["outcome": "selected", "optionId": .string(optionId!)]
        Task { await client.respond(toRequest: rid, result: ["outcome": outcome]) }
        if let i = chat.entries.firstIndex(where: { $0.id == entry.id }) {
            chat.entries[i].status = optionId ?? "rejected"
        }
    }

    private func agentExited(_ code: Int32) {
        sessionId = nil
        if chat.entries.isEmpty {
            chat.state = .error("agent exited (\(code))")
            chat.note("\(agent?.name ?? "agent") exited with status \(code). \(agent?.hint ?? "")")
        } else {
            chat.note("\(agent?.name ?? "agent") exited — session ended. New chat to restart.")
            chat.state = .ready
        }
    }

    func cancel() {
        guard let sid = sessionId else { return }
        Task { await client.notify("session/cancel", params: ["sessionId": .string(sid)]) }
    }

    func setMode(_ id: String) {
        guard let sid = sessionId else { return }
        chat.currentMode = id
        Task {
            try? await client.request("session/set_mode",
                                      params: ["sessionId": .string(sid), "modeId": .string(id)])
        }
    }

    func newChat() {
        Task { await connect(to: Config.agent) }
    }

    /// Builds ACP content blocks and sends session/prompt.
    func send(text: String, image: URL?, files: [URL]) {
        guard let sid = sessionId else {
            if chat.state != .starting { chat.note("agent not connected yet — try again in a sec") }
            return
        }
        var prompt: [JSONValue] = []

        if let image, let data = try? Data(contentsOf: image) {
            if imageOK {
                prompt.append(["type": "image", "data": .string(data.base64EncodedString()),
                               "mimeType": "image/png"])
            } else {
                prompt.append(["type": "resource_link",
                               "uri": .string(image.absoluteString), "name": "screenshot.png"])
            }
        }
        for f in files {
            prompt.append(fileBlock(f))
        }
        if !text.isEmpty {
            prompt.append(["type": "text", "text": .string(text)])
        }
        guard !prompt.isEmpty else { return }

        chat.appendUser(text: text, image: image, files: files)
        chat.state = .prompting
        chat.statusLine = "working…"

        Task {
            do {
                let res = try await client.request("session/prompt", params: [
                    "sessionId": .string(sid), "prompt": .array(prompt),
                ])
                chat.state = .ready
                if let reason = res["stopReason"]?.string, reason != "end_turn" {
                    chat.statusLine = "stopped: \(reason)"
                } else {
                    chat.statusLine = ""
                }
            } catch {
                chat.state = .ready
                chat.statusLine = ""
                chat.note("prompt failed: \(error.localizedDescription)")
            }
        }
    }

    private func fileBlock(_ url: URL) -> JSONValue {
        let uri = url.absoluteString
        if embedOK,
           let data = try? Data(contentsOf: url), data.count < 2_000_000,
           let text = String(data: data, encoding: .utf8) {
            return ["type": "resource",
                    "resource": ["uri": .string(uri), "mimeType": "text/plain",
                                 "text": .string(text)]]
        }
        return ["type": "resource_link", "uri": .string(uri), "name": .string(url.lastPathComponent)]
    }

    func stop() {
        Task { await client.stop() }
    }
}
