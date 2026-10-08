# cmdcmd

A tiny macOS menu-bar companion for your coding agent. Tap one **Command key twice** (or press **left + right Command together**) and a small popup opens at the bottom-center of your screen with a screenshot of what's on it. Send the image straight to your agent, add a prompt, or `@`-mention files for extra context.

Agents are connected over **[ACP](https://agentclientprotocol.com)** (Agent Client Protocol) — the same NDJSON/JSON-RPC protocol Zed uses — so cmdcmd works with any ACP-speaking agent CLI.

```
 ⌘ ⌘        → popup (screenshot + input)
 @file      → autocomplete workspace files, attached as context
 /cmd       → agent slash commands (when the agent advertises them)
 Esc / click away → dismiss
```

## Install

1. Mount `cmdcmd.dmg` and drag **cmdcmd.app** to Applications.
2. Builds are ad-hoc signed, so once: `xattr -dr com.apple.quarantine /Applications/cmdcmd.app`
3. Launch cmdcmd — it lives in the menu bar (⌘ icon). macOS will ask for two permissions:
   - **Accessibility** — required for the global hotkey (Input Monitoring is requested too).
   - **Screen Recording** — required to attach the screenshot chip. You can use cmdcmd without it (text + files only).
4. Log in to your agent's CLI once (e.g. `claude`, `codex login`, `devin auth login`).

## Agents

Pick the active agent from the popup header or the menu. Built-in registry:

| Agent | Command |
| --- | --- |
| Codex | `npx -y @agentclientprotocol/codex-acp` |
| Claude | `npx -y @agentclientprotocol/claude-agent-acp` |
| Devin CLI | `devin acp` |
| Cursor | `cursor-agent acp` |
| Pi | `npx -y pi-acp` |
| Gemini | `gemini --experimental-acp` |
| OpenCode | `npx -y opencode-ai acp` |
| Copilot | `copilot --acp --stdio` |
| Kimi | `kimi acp` |

Agents are spawned through a login shell (`zsh -l`) so PATH-based installs (nvm, homebrew) resolve. Headless hints (`NO_BROWSER=1`) are set.

## Config

`~/.cmdcmd/config.json` — written on first launch, hot-reloadable by reopening the popup:

```jsonc
{
  "selectedAgent": "codex",
  "workspace": "~",                 // cwd for the agent + @file search root
  "attachScreenshot": true,
  "env": {},                        // extra env for the agent process
  "agents": [                       // custom entries merged over the registry
    { "id": "mine", "name": "My Agent",
      "command": "node ~/my-acp-agent.mjs", "hint": "" }
  ]
}
```

Logs: `~/.cmdcmd/agent.log` (agent stderr), `~/.cmdcmd/acp-trace.log` (wire traffic).

## What the client implements

Client→agent: `initialize`, `authenticate`, `session/new`, `session/prompt`, `session/cancel`, `session/set_mode`.
Updates rendered: message/thought chunks, tool calls + updates, plans, permission requests (Allow once / Always allow / Reject), slash commands, modes, usage.
Agent→client implemented: `fs/read_text_file`, `fs/write_text_file`, `terminal/*` (create, output, wait_for_exit, release, kill — output ring-buffered, capped 512 KB), `session/request_permission`.
Content: prompts send `text`, `image` (base64, when the agent supports it — else a `resource_link`), and `resource`/`resource_link` for `@`-mentioned files.

## Dev

```sh
swift build -c release          # or: make bundle / make run / make dmg
scripts/mock-agent.mjs          # fake ACP agent for testing — point a custom agent at it
```

Node is required for npx-based agents and the mock.
