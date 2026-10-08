import Foundation

/// An ACP agent cmdcmd can spawn. `command` is run through `/bin/zsh -lc`
/// so the user's login-shell PATH (homebrew, nvm, etc.) applies.
struct AgentSpec: Codable, Identifiable, Equatable {
    var id: String          // stable key, e.g. "codex"
    var name: String        // display name
    var command: String     // shell command that starts an ACP server on stdio
    var hint: String        // login/setup hint shown when the spawn or auth fails

    init(id: String, name: String, command: String, hint: String) {
        self.id = id; self.name = name; self.command = command; self.hint = hint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        command = try c.decode(String.self, forKey: .command)
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
    }
}

struct CmdcmdConfig: Codable {
    var selectedAgent: String = "codex"
    /// Workspace root for session cwd and @-mention file search.
    var workspace: String = "~"
    /// Extra agents defined by the user (merged over the built-ins by id).
    var agents: [AgentSpec] = []
    /// Extra environment passed to the agent process.
    var env: [String: String] = [:]
    /// Attach a screenshot automatically on every popup open.
    var attachScreenshot: Bool = true
    /// Where the agent's stderr goes.
    var logPath: String = "~/.cmdcmd/agent.log"

    init() {}

    /// Tolerant decode: a config.json missing keys keeps the defaults rather
    /// than being replaced wholesale.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedAgent = try c.decodeIfPresent(String.self, forKey: .selectedAgent) ?? "codex"
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? "~"
        agents = try c.decodeIfPresent([AgentSpec].self, forKey: .agents) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        attachScreenshot = try c.decodeIfPresent(Bool.self, forKey: .attachScreenshot) ?? true
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath) ?? "~/.cmdcmd/agent.log"
    }
}

/// App-wide config. All reads/writes happen on the main actor (UI, session).
@MainActor
enum Config {
    nonisolated static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cmdcmd")
    nonisolated static let url = dir.appendingPathComponent("config.json")

    static var current = CmdcmdConfig()

    static func load() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(CmdcmdConfig.self, from: data) {
            current = cfg
        } else {
            current = CmdcmdConfig()
            save()
        }
    }

    static func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(current) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static var workspaceURL: URL {
        URL(fileURLWithPath: (current.workspace as NSString).expandingTildeInPath)
    }

    static var agent: AgentSpec {
        agents.first { $0.id == current.selectedAgent } ?? AgentRegistry.all[0]
    }

    static var agents: [AgentSpec] {
        var out = AgentRegistry.all
        for a in current.agents {
            if let i = out.firstIndex(where: { $0.id == a.id }) { out[i] = a }
            else { out.append(a) }
        }
        return out
    }

    static var logURL: URL {
        URL(fileURLWithPath: (current.logPath as NSString).expandingTildeInPath)
    }
}

enum AgentRegistry {
    /// Commands per the public ACP agent registry (zed / acpx).
    static let all: [AgentSpec] = [
        AgentSpec(id: "codex", name: "Codex",
                  command: "npx -y @agentclientprotocol/codex-acp",
                  hint: "Run `npx -y @agentclientprotocol/codex-acp` once, or `codex login`."),
        AgentSpec(id: "claude", name: "Claude",
                  command: "npx -y @agentclientprotocol/claude-agent-acp",
                  hint: "Log in once with `claude` in Terminal."),
        AgentSpec(id: "devin", name: "Devin CLI",
                  command: "devin acp",
                  hint: "Install Devin CLI and run `devin auth login`."),
        AgentSpec(id: "cursor", name: "Cursor",
                  command: "cursor-agent acp",
                  hint: "Install Cursor CLI and run `cursor-agent login`."),
        AgentSpec(id: "pi", name: "Pi",
                  command: "npx -y pi-acp",
                  hint: "Log in once with `pi` in Terminal."),
        AgentSpec(id: "gemini", name: "Gemini",
                  command: "gemini --experimental-acp",
                  hint: "Log in once with `gemini` in Terminal."),
        AgentSpec(id: "opencode", name: "OpenCode",
                  command: "npx -y opencode-ai acp",
                  hint: "Log in once with `opencode` in Terminal."),
        AgentSpec(id: "copilot", name: "Copilot",
                  command: "copilot --acp --stdio",
                  hint: "Log in once with `copilot` in Terminal."),
        AgentSpec(id: "kimi", name: "Kimi",
                  command: "kimi acp",
                  hint: "Log in once with `kimi` in Terminal."),
    ]
}
